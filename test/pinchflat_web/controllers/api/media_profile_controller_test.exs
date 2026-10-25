defmodule PinchflatWeb.Api.MediaProfileControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Profiles.MediaProfile

  setup %{conn: conn} do
    authed = put_req_header(conn, "authorization", "Bearer #{Settings.get!(:route_token)}")

    {:ok, %{authed: authed}}
  end

  test "needs the token", %{conn: conn} do
    assert get(conn, ~p"/api/media_profiles").status == 401
  end

  test "lists profiles that are not being deleted", %{authed: conn} do
    profile = media_profile_fixture()
    _deleting = media_profile_fixture(marked_for_deletion_at: DateTime.utc_now())

    assert %{"data" => [listed]} = json_response(get(conn, ~p"/api/media_profiles"), 200)
    assert listed["id"] == profile.id
    assert listed["name"] == profile.name
    assert Map.has_key?(listed, "preferred_resolution")
    refute Map.has_key?(listed, "sources")
  end

  test "shows one profile with all its settings", %{authed: conn} do
    profile = media_profile_fixture(preferred_resolution: :"720p", shorts_behaviour: :exclude)

    assert %{"data" => %{"preferred_resolution" => "720p", "shorts_behaviour" => "exclude"}} =
             json_response(get(conn, ~p"/api/media_profiles/#{profile.id}"), 200)
  end

  test "creates a profile", %{authed: conn} do
    conn =
      post(conn, ~p"/api/media_profiles", %{
        name: "Tube",
        output_path_template: "/{{ source_custom_name }}/{{ title }} [{{ id }}].{{ ext }}",
        preferred_resolution: "1080p",
        media_container: "mp4",
        shorts_behaviour: "exclude",
        download_subs: true,
        download_auto_subs: true
      })

    assert %{"data" => %{"id" => id, "name" => "Tube", "media_container" => "mp4"}} = json_response(conn, 201)
    assert %MediaProfile{shorts_behaviour: :exclude, download_auto_subs: true} = Repo.get!(MediaProfile, id)
  end

  test "rejects an invalid profile", %{authed: conn} do
    conn = post(conn, ~p"/api/media_profiles", %{name: "Bad", output_path_template: "/no-extension"})
    assert %{"error" => "invalid", "errors" => %{"output_path_template" => _}} = json_response(conn, 422)
  end

  test "updates a profile", %{authed: conn} do
    profile = media_profile_fixture()

    conn = patch(conn, ~p"/api/media_profiles/#{profile.id}", %{preferred_resolution: "720p", id: 999})

    assert %{"data" => %{"id" => id, "preferred_resolution" => "720p"}} = json_response(conn, 200)
    assert id == profile.id
  end

  test "returns 404 for an unknown profile", %{authed: conn} do
    assert json_response(patch(conn, ~p"/api/media_profiles/0", %{name: "x"}), 404)
  end
end
