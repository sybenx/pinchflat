defmodule PinchflatWeb.Api.MediaItemControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings

  setup %{conn: conn} do
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)
    {:ok, %{authed: put_req_header(conn, "authorization", "Bearer #{Settings.get!(:route_token)}")}}
  end

  test "needs the token", %{conn: conn} do
    assert post(conn, ~p"/api/media/delete_files", %{media_ids: []}).status == 401
  end

  test "deletes files of the given media and prevents re-download", %{authed: conn} do
    media_item = media_item_with_attachments()
    other = media_item_with_attachments()

    conn = post(conn, ~p"/api/media/delete_files", %{media_ids: [media_item.media_id, "missing"]})

    assert %{"deleted" => [id], "not_found" => ["missing"]} = json_response(conn, 200)
    assert id == media_item.media_id
    refute File.exists?(media_item.media_filepath)
    assert %{media_filepath: nil, prevent_download: true} = Repo.reload!(media_item)
    assert File.exists?(other.media_filepath)
  end

  test "can be limited to one source", %{authed: conn} do
    media_item = media_item_with_attachments()
    source = source_fixture()

    conn = post(conn, ~p"/api/media/delete_files", %{media_ids: [media_item.media_id], source_id: source.id})

    assert %{"deleted" => [], "not_found" => [_]} = json_response(conn, 200)
    assert File.exists?(media_item.media_filepath)
  end

  test "rejects a bad list", %{authed: conn} do
    assert json_response(post(conn, ~p"/api/media/delete_files", %{media_ids: "x"}), 422)
  end
end
