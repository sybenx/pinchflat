defmodule Pinchflat.Downloading.DownloadBackoff do
  @moduledoc """
  Per media item backoff for downloads that keep failing.

  Each download job that ends in a retryable failure counts once (see
  `MediaDownloadWorker`). The item is then skipped by the pending query until
  `download_retry_after`: 1, 3, 7 and then 30 days after failures 1 to 4. On the
  5th failure Pinchflat gives up and sets `prevent_download`, keeping `last_error`
  so the reason stays visible. "Force download" in the UI still works.
  """

  require Logger

  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem

  @retry_delays_days [1, 3, 7, 30]
  @max_failures length(@retry_delays_days) + 1

  @doc """
  The number of failures after which downloads of an item are given up.
  """
  def max_failures, do: @max_failures

  @doc """
  The delay in days before retrying after the given failure count, or nil
  once the item has been given up on.
  """
  def retry_delay_days(failure_count) when failure_count >= 1 do
    Enum.at(@retry_delays_days, failure_count - 1)
  end

  @doc """
  Records one failed download run for a media item.

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def record_failure(%MediaItem{} = media_item, now \\ DateTime.utc_now()) do
    # Reload so the count is right even if the struct we were handed is stale
    media_item = Media.get_media_item!(media_item.id)
    failure_count = (media_item.download_failure_count || 0) + 1

    attrs =
      case retry_delay_days(failure_count) do
        nil ->
          Logger.warning(
            "Media item ##{media_item.id} failed to download #{failure_count} times. " <>
              "Giving up and preventing further downloads"
          )

          %{download_failure_count: failure_count, download_retry_after: nil, prevent_download: true}

        days ->
          retry_after = now |> DateTime.add(days, :day) |> DateTime.truncate(:second)

          Logger.info("Media item ##{media_item.id} download failure #{failure_count}. Next try after #{retry_after}")

          %{download_failure_count: failure_count, download_retry_after: retry_after}
      end

    Media.update_media_item(media_item, attrs)
  end

  @doc """
  Attributes that clear the backoff, used after a successful download.
  """
  def reset_attrs do
    %{download_failure_count: 0, download_retry_after: nil}
  end
end
