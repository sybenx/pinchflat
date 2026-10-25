defmodule PinchflatWeb.Api.MediaProfileController do
  @moduledoc """
  JSON API for media profiles (see `PinchflatWeb.Api.SourceController` for auth).
  Changes go through `Pinchflat.Profiles`, so the same validation applies as in the UI.
  """

  use PinchflatWeb, :controller

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Profiles
  alias Pinchflat.Profiles.MediaProfile

  def index(conn, _params) do
    profiles =
      from(mp in MediaProfile, where: is_nil(mp.marked_for_deletion_at), order_by: [asc: mp.name])
      |> Repo.all()

    json(conn, %{data: Enum.map(profiles, &profile_json/1)})
  end

  def show(conn, %{"id" => id}) do
    with_profile(conn, id, &json(conn, %{data: profile_json(&1)}))
  end

  def create(conn, params) do
    case Profiles.create_media_profile(params) do
      {:ok, profile} ->
        conn
        |> put_status(:created)
        |> json(%{data: profile_json(profile)})

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error(conn, changeset)
    end
  end

  # Changing a profile doesn't re-download anything already downloaded; it applies to future downloads.
  def update(conn, %{"id" => id} = params) do
    with_profile(conn, id, fn profile ->
      case Profiles.update_media_profile(profile, Map.delete(params, "id")) do
        {:ok, updated} -> json(conn, %{data: profile_json(updated)})
        {:error, %Ecto.Changeset{} = changeset} -> changeset_error(conn, changeset)
      end
    end)
  end

  defp with_profile(conn, id, fun) do
    case Repo.get(MediaProfile, id) do
      %MediaProfile{marked_for_deletion_at: nil} = profile -> fun.(profile)
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

  defp profile_json(profile) do
    profile
    |> Map.from_struct()
    |> Map.drop([:__meta__, :sources, :marked_for_deletion_at])
  end
end
