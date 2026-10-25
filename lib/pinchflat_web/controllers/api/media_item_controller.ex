defmodule PinchflatWeb.Api.MediaItemController do
  @moduledoc """
  JSON API for media items (see `PinchflatWeb.Api.SourceController` for auth).
  """

  use PinchflatWeb, :controller

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem

  @max_ids 200

  @doc """
  Deletes the downloaded files of the media items with these `media_ids` (the YouTube ids), optionally only
  within `source_id`, and marks them `prevent_download` so they aren't downloaded again. The records stay.
  """
  def delete_files(conn, %{"media_ids" => ids} = params) when is_list(ids) and length(ids) <= @max_ids do
    ids = Enum.filter(ids, &is_binary/1)

    query =
      case params["source_id"] do
        nil -> from(mi in MediaItem, where: mi.media_id in ^ids)
        source_id -> from(mi in MediaItem, where: mi.media_id in ^ids and mi.source_id == ^source_id)
      end

    items = Repo.all(query)

    deleted =
      items
      |> Enum.filter(& &1.media_filepath)
      |> Enum.map(fn media_item ->
        {:ok, _} = Media.delete_media_files(media_item, %{prevent_download: true, culled_at: DateTime.utc_now()})
        media_item.media_id
      end)

    found = MapSet.new(items, & &1.media_id)

    json(conn, %{deleted: Enum.uniq(deleted), not_found: Enum.reject(ids, &MapSet.member?(found, &1))})
  end

  def delete_files(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid", errors: %{media_ids: ["must be a list of at most #{@max_ids} ids"]}})
  end
end
