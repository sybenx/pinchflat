defmodule Pinchflat.Downloading.MediaDownloadWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :media_fetching,
    priority: 5,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "media_fetching", "show_in_dashboard"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Tasks
  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.FileSyncing
  alias Pinchflat.Downloading.DownloadPause
  alias Pinchflat.Downloading.MediaDownloader
  alias Pinchflat.Downloading.DownloadBackoff
  alias Pinchflat.Downloading.DownloadErrorClassifier

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  @doc """
  Starts the media_item media download worker and creates a task for the media_item.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(media_item, job_args \\ %{}, job_opts \\ []) do
    %{id: media_item.id}
    |> Map.merge(job_args)
    |> MediaDownloadWorker.new(job_opts)
    |> Tasks.create_job_with_task(media_item)
  end

  @doc """
  For a given media item, download the media alongside any options.
  Does not download media if its source is set to not download media
  (unless forced).

  Options:
    - `force`: force download even if the source is set to not download media. Fully
      re-downloads media, including the video
    - `quality_upgrade?`: re-downloads media, including the video. Does not force download
      if the source is set to not download media

  Returns :ok | {:error, any, ...any}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => media_item_id} = args} = job) do
    case DownloadPause.paused_until() do
      %DateTime{} = paused_until ->
        Logger.info("Downloads paused until #{paused_until} UTC (rate limit). Snoozing media item ##{media_item_id}")

        {:snooze, DownloadPause.seconds_until_resume(paused_until)}

      nil ->
        do_perform(job, media_item_id, args)
    end
  end

  defp do_perform(job, media_item_id, args) do
    should_force = Map.get(args, "force", false)
    is_quality_upgrade = Map.get(args, "quality_upgrade?", false)

    media_item = fetch_and_run_prevent_download_user_script(media_item_id)

    if should_download_media?(media_item, should_force, is_quality_upgrade) do
      download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force, job)
    else
      :ok
    end
  rescue
    Ecto.NoResultsError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} not found")
    Ecto.StaleEntryError -> Logger.info("#{__MODULE__} discarded: media item #{media_item_id} stale")
  end

  # If this is a quality upgrade, only check if the source is set to download media
  # or that the media item's download hasn't been prevented
  defp should_download_media?(media_item, should_force, true = _is_quality_upgrade) do
    (media_item.source.download_media && !media_item.prevent_download) || should_force
  end

  # If it's not a quality upgrade, additionally check if the media item is pending download
  defp should_download_media?(media_item, should_force, _is_quality_upgrade) do
    source = media_item.source
    is_pending = Media.pending_download?(media_item)

    (is_pending && source.download_media && !media_item.prevent_download) || should_force
  end

  # If a user script exists and, when run, returns a non-zero exit code, prevent this and all future downloads
  # of the media item.
  defp fetch_and_run_prevent_download_user_script(media_item_id) do
    media_item = Media.get_media_item!(media_item_id)

    {:ok, media_item} =
      case run_user_script(:media_pre_download, media_item) do
        {:ok, _, exit_code} when exit_code != 0 -> Media.update_media_item(media_item, %{prevent_download: true})
        _ -> {:ok, media_item}
      end

    Repo.preload(media_item, :source)
  end

  defp download_media_and_schedule_jobs(media_item, is_quality_upgrade, should_force, job) do
    overwrite_behaviour = if should_force || is_quality_upgrade, do: :force_overwrites, else: :no_force_overwrites
    override_opts = [overwrite_behaviour: overwrite_behaviour]

    case MediaDownloader.download_for_media_item(media_item, override_opts) do
      {:ok, downloaded_media_item} ->
        {:ok, updated_media_item} =
          Media.update_media_item(downloaded_media_item, %{
            media_size_bytes: compute_media_filesize(downloaded_media_item),
            media_redownloaded_at: get_redownloaded_at(is_quality_upgrade)
          })

        :ok = FileSyncing.delete_outdated_files(media_item, updated_media_item)
        run_user_script(:media_downloaded, updated_media_item)

        :ok

      {:recovered, _media_item, _message} ->
        {:error, :retry}

      {:error, :unsuitable_for_download, _message} ->
        {:ok, :non_retry}

      {:error, _error_atom, message} ->
        action_on_error(media_item, message, job)
    end
  end

  defp compute_media_filesize(media_item) do
    case File.stat(media_item.media_filepath) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp get_redownloaded_at(true), do: DateTime.utc_now()
  defp get_redownloaded_at(_), do: nil

  # Permanent errors are never retried and the item is marked `prevent_download`.
  # Rate limits pause all downloads and snooze this job until the pause ends,
  # without counting against the item. Anything else is retried by Oban (up to
  # `max_attempts`), and only when the last attempt also fails does it count as
  # one failure for the item's backoff (see DownloadBackoff).
  #
  # Items that are already downloaded (quality upgrades, forced re-downloads)
  # never get `prevent_download` or a backoff from here, so an upgrade failing
  # cannot change how an existing download is treated.
  defp action_on_error(media_item, message, job) do
    is_downloaded = media_item.media_filepath != nil

    case DownloadErrorClassifier.classify(message) do
      :rate_limited ->
        {:ok, paused_until} = DownloadPause.pause!(message)

        {:snooze, DownloadPause.seconds_until_resume(paused_until)}

      :permanent ->
        Logger.error("yt-dlp download will not be retried (permanent error): #{inspect(message)}")

        if !is_downloaded do
          Logger.warning("Preventing future downloads of media item ##{media_item.id}")
          {:ok, _} = Media.update_media_item(media_item, %{prevent_download: true})
        end

        {:ok, :non_retry}

      :retryable ->
        if final_attempt?(job) && !is_downloaded do
          {:ok, _} = DownloadBackoff.record_failure(media_item)
        end

        {:error, :download_failed}
    end
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts) do
    attempt >= max_attempts
  end

  defp final_attempt?(_job), do: true

  # NOTE: I like this pattern of using the default value so that I don't have to
  # define it in config.exs (and friends). Consider using this elsewhere.
  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end
end
