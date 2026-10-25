defmodule PinchflatWeb.Api.SourceControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.MediaDownloadWorker

  setup %{conn: conn} do
    token = Settings.get!(:route_token)
    authed = put_req_header(conn, "authorization", "Bearer #{token}")

    {:ok, %{authed: authed, media_profile: media_profile_fixture()}}
  end

  describe "authentication" do
    test "rejects a missing token", %{conn: conn} do
      assert get(conn, ~p"/api/sources").status == 401
    end

    test "rejects a wrong token", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer wrong") |> get(~p"/api/sources")
      assert conn.status == 401
    end

    test "rejects the token as a query parameter", %{conn: conn} do
      route_token = Settings.get!(:route_token)
      assert get(conn, ~p"/api/sources?#{[route_token: route_token]}").status == 401
    end
  end

  describe "index" do
    test "lists sources that are not being deleted", %{authed: conn} do
      source = source_fixture()
      _deleting = source_fixture(marked_for_deletion_at: DateTime.utc_now())

      assert %{"data" => [listed]} = json_response(get(conn, ~p"/api/sources"), 200)
      assert listed["id"] == source.id
      assert listed["original_url"] == source.original_url
      assert listed["index_frequency_minutes"] == 60
    end

    test "counts downloaded and pending media", %{authed: conn} do
      source = source_fixture()
      media_item_fixture(source_id: source.id)
      media_item_fixture(source_id: source.id, media_filepath: nil)

      assert %{"data" => %{"downloaded_count" => 1, "pending_count" => 1}} =
               json_response(get(conn, ~p"/api/sources/#{source.id}"), 200)
    end
  end

  describe "create" do
    test "creates a source with a cutoff date", %{authed: conn, media_profile: mp} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      conn =
        post(conn, ~p"/api/sources", %{
          original_url: "https://www.youtube.com/source/abc123",
          media_profile_id: mp.id,
          download_cutoff_date: "2025-01-01",
          index_frequency_minutes: 1440
        })

      assert %{"data" => %{"id" => id, "download_cutoff_date" => "2025-01-01"}} = json_response(conn, 201)
      assert Repo.get!(Pinchflat.Sources.Source, id).index_frequency_minutes == 1440
    end

    test "returns errors for invalid data", %{authed: conn} do
      conn = post(conn, ~p"/api/sources", %{original_url: nil})
      assert %{"error" => "invalid", "errors" => %{"original_url" => _}} = json_response(conn, 422)
    end
  end

  describe "update" do
    test "changes the cutoff date and queues newly pending media", %{authed: conn} do
      source = source_fixture(download_cutoff_date: ~D[2025-01-01])
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil, uploaded_at: ~U[2024-06-01 00:00:00Z])

      conn = patch(conn, ~p"/api/sources/#{source.id}", %{download_cutoff_date: "2024-01-01"})

      assert %{"data" => %{"download_cutoff_date" => "2024-01-01"}} = json_response(conn, 200)
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "refuses a later cutoff that would delete downloaded files", %{authed: conn} do
      source = source_fixture(download_cutoff_date: ~D[2024-01-01])
      media_item_fixture(source_id: source.id, uploaded_at: ~U[2024-06-01 00:00:00Z])

      conn1 = patch(conn, ~p"/api/sources/#{source.id}", %{download_cutoff_date: "2025-01-01"})
      assert %{"error" => "would_delete", "count" => 1} = json_response(conn1, 422)
      assert Repo.reload!(source).download_cutoff_date == ~D[2024-01-01]

      conn2 =
        patch(conn, ~p"/api/sources/#{source.id}", %{download_cutoff_date: "2025-01-01", allow_deleting_older: true})

      assert %{"data" => %{"download_cutoff_date" => "2025-01-01"}} = json_response(conn2, 200)
    end

    test "allows a later cutoff when nothing would be deleted", %{authed: conn} do
      source = source_fixture(download_cutoff_date: nil)
      media_item_fixture(source_id: source.id, uploaded_at: ~U[2025-06-01 00:00:00Z])

      assert json_response(patch(conn, ~p"/api/sources/#{source.id}", %{download_cutoff_date: "2025-01-01"}), 200)
    end

    test "ignores fields outside the allowed list", %{authed: conn} do
      source = source_fixture()
      patch(conn, ~p"/api/sources/#{source.id}", %{original_url: "https://www.youtube.com/@other"})
      assert Repo.reload!(source).original_url == source.original_url
    end

    test "returns 404 for an unknown source", %{authed: conn} do
      assert json_response(patch(conn, ~p"/api/sources/0", %{enabled: false}), 404)
    end
  end

  describe "extend" do
    test "moves the cutoff back by count media items and queues them", %{authed: conn} do
      source = source_fixture(download_cutoff_date: ~D[2025-01-01])

      older =
        for day <- 1..5 do
          media_item_fixture(
            source_id: source.id,
            media_filepath: nil,
            uploaded_at: DateTime.new!(Date.new!(2024, 12, day), ~T[12:00:00])
          )
        end

      # already downloaded media doesn't count
      media_item_fixture(source_id: source.id, uploaded_at: ~U[2024-12-30 12:00:00Z])

      conn = post(conn, ~p"/api/sources/#{source.id}/extend", %{count: 3})

      assert %{"added" => 3, "data" => %{"download_cutoff_date" => "2024-12-03"}} = json_response(conn, 200)

      for mi <- Enum.drop(older, 2), do: assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => mi.id})
      for mi <- Enum.take(older, 2), do: refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => mi.id})
    end

    test "does nothing without a cutoff date", %{authed: conn} do
      source = source_fixture(download_cutoff_date: nil)
      assert %{"added" => 0} = json_response(post(conn, ~p"/api/sources/#{source.id}/extend", %{count: 10}), 200)
    end

    test "does nothing when no older media is indexed", %{authed: conn} do
      source = source_fixture(download_cutoff_date: ~D[2025-01-01])

      assert %{"added" => 0, "data" => %{"download_cutoff_date" => "2025-01-01"}} =
               json_response(post(conn, ~p"/api/sources/#{source.id}/extend", %{}), 200)
    end
  end

  describe "delete" do
    test "marks the source and keeps files by default", %{authed: conn} do
      source = source_fixture()

      assert %{"data" => %{"delete_files" => false}} = json_response(delete(conn, ~p"/api/sources/#{source.id}"), 202)
      assert Repo.reload!(source).marked_for_deletion_at
      assert [%{args: %{"delete_files" => false}}] = all_enqueued(worker: SourceDeletionWorker)
    end

    test "deletes files when asked", %{authed: conn} do
      source = source_fixture()
      delete(conn, ~p"/api/sources/#{source.id}?delete_files=true")
      assert [%{args: %{"delete_files" => true}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  defp runner_function_mock(_url, :get_source_details, _opts, _ot, _addl) do
    {:ok,
     Phoenix.json_library().encode!(%{
       channel: "some channel name",
       channel_id: "some_channel_id_#{:rand.uniform(1_000_000)}",
       playlist_id: "some_playlist_id_#{:rand.uniform(1_000_000)}",
       playlist_title: "some playlist name"
     })}
  end

  defp runner_function_mock(_url, _command, _opts, _ot, _addl), do: {:ok, "{}"}
end
