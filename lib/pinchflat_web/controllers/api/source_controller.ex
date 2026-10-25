defmodule PinchflatWeb.Api.SourceController do
  @moduledoc """
  A small JSON API for managing sources from other apps. Every route needs
  `Authorization: Bearer <route_token>` (the same token as the OPML feed).
  All changes go through `Pinchflat.Sources`, so indexing and downloading
  are set up exactly as they are for sources made in the UI.
  """

  use PinchflatWeb, :controller
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.DownloadingHelpers

  @create_fields ~w(original_url media_profile_id custom_name download_cutoff_date index_frequency_minutes enabled)
  @update_fields ~w(custom_name download_cutoff_date index_frequency_minutes enabled)

  def index(conn, _params) do
    sources =
      from(s in Source, where: is_nil(s.marked_for_deletion_at), order_by: [asc: s.custom_name])
      |> Repo.all()

    json(conn, %{data: Enum.map(sources, &source_json/1)})
  end

  def show(conn, %{"id" => id}) do
    with_source(conn, id, &json(conn, %{data: source_json(&1)}))
  end

  def create(conn, params) do
    case Sources.create_source(Map.take(params, @create_fields)) do
      {:ok, source} ->
        conn
        |> put_status(:created)
        |> json(%{data: source_json(source)})

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with_source(conn, id, fn source ->
      case Sources.update_source(source, Map.take(params, @update_fields)) do
        {:ok, updated} ->
          # A moved cutoff date can make more media pending. Already-queued media isn't queued twice.
          if Map.has_key?(params, "download_cutoff_date") && updated.enabled do
            DownloadingHelpers.enqueue_pending_download_tasks(updated)
          end

          json(conn, %{data: source_json(updated)})

        {:error, %Ecto.Changeset{} = changeset} ->
          changeset_error(conn, changeset)
      end
    end)
  end

  @doc """
  Moves the source's cutoff date back far enough for `count` more indexed media items
  (ones that would download under the source's other rules) and queues their downloads.
  """
  def extend(conn, %{"source_id" => id} = params) do
    with_source(conn, id, fn source ->
      count = parse_count(params["count"])

      case {source.download_cutoff_date, older_media_dates(source, count)} do
        {nil, _} ->
          json(conn, %{data: source_json(source), added: 0})

        {_, []} ->
          json(conn, %{data: source_json(source), added: 0})

        {_, dates} ->
          {:ok, updated} = Sources.update_source(source, %{download_cutoff_date: List.last(dates)})
          if updated.enabled, do: DownloadingHelpers.enqueue_pending_download_tasks(updated)

          json(conn, %{data: source_json(updated), added: length(dates)})
      end
    end)
  end

  def delete(conn, %{"id" => id} = params) do
    with_source(conn, id, fn source ->
      delete_files = to_string(params["delete_files"]) == "true"
      {:ok, _} = Sources.update_source(source, %{marked_for_deletion_at: DateTime.utc_now()})
      SourceDeletionWorker.kickoff(source, %{delete_files: delete_files})

      conn
      |> put_status(:accepted)
      |> json(%{data: %{id: source.id, deleting: true, delete_files: delete_files}})
    end)
  end

  defp older_media_dates(source, count) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(
      ^dynamic(
        [mi, s],
        ^MediaQuery.for_source(source) and
          not (^MediaQuery.downloaded()) and
          not (^MediaQuery.download_prevented()) and
          fragment("date(?) < ?", mi.uploaded_at, s.download_cutoff_date) and
          ^MediaQuery.format_matching_profile_preference() and
          ^MediaQuery.matches_source_title_regex() and
          ^MediaQuery.meets_min_and_max_duration()
      )
    )
    |> order_by([mi], desc: mi.uploaded_at)
    |> limit(^count)
    |> select([mi], fragment("date(?)", mi.uploaded_at))
    |> Repo.all()
    |> Enum.map(&Date.from_iso8601!/1)
  end

  defp parse_count(value) do
    case Integer.parse(to_string(value || "10")) do
      {n, _} when n > 0 -> min(n, 100)
      _ -> 10
    end
  end

  defp with_source(conn, id, fun) do
    case Repo.get(Source, id) do
      %Source{marked_for_deletion_at: nil} = source -> fun.(source)
      _ -> conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  defp changeset_error(conn, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid", errors: errors})
  end

  defp source_json(source) do
    Map.take(source, ~w(id uuid custom_name collection_name collection_id collection_type original_url
      media_profile_id enabled download_media download_cutoff_date index_frequency_minutes last_indexed_at)a)
    |> Map.put(:downloaded_count, count_media(source, true))
    |> Map.put(:pending_count, count_media(source, false))
  end

  defp count_media(source, downloaded) do
    query =
      if downloaded,
        do: dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()),
        else: dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending())

    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^query)
    |> Repo.aggregate(:count)
  end
end
