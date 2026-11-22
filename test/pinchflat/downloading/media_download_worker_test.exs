defmodule Pinchflat.Downloading.MediaDownloadWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Settings
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.MediaDownloadWorker

  setup do
    stub(YtDlpRunnerMock, :run, fn
      _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
      _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
    end)

    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)
    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)

    media_item =
      %{media_filepath: nil}
      |> media_item_fixture()
      |> Repo.preload([:metadata, source: :media_profile])

    {:ok, %{media_item: media_item}}
  end

  describe "kickoff_with_task/2" do
    test "starts the worker", %{media_item: media_item} do
      assert [] = all_enqueued(worker: MediaDownloadWorker)
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item)
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "attaches a task", %{media_item: media_item} do
      assert {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)
      assert task.media_item_id == media_item.id
    end

    test "can be called with additional job arguments", %{media_item: media_item} do
      job_args = %{"force" => true}

      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item, job_args)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id, "force" => true})
    end

    test "has a priority of 5 by default", %{media_item: media_item} do
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item)

      [job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      assert job.priority == 5
    end

    test "priority can be set", %{media_item: media_item} do
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item, %{}, priority: 0)

      [job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      assert job.priority == 0
    end
  end

  describe "perform/1" do
    setup do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      :ok
    end

    test "saves attributes to the media_item", %{media_item: media_item} do
      assert media_item.media_filepath == nil
      perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload(media_item)

      assert media_item.media_filepath != nil
    end

    test "saves the metadata to the media_item", %{media_item: media_item} do
      assert media_item.metadata == nil
      perform_job(MediaDownloadWorker, %{id: media_item.id})
      assert Repo.reload(media_item).metadata != nil
    end

    test "won't double-schedule downloading jobs", %{media_item: media_item} do
      Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))
      Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "sets the job to retryable if the download fails", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "error"}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

        assert job.state == "retryable"
      end)
    end

    test "sets the job to retryable if the download failed and was retried", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Unable to communicate with SponsorBlock", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

        assert job.state == "retryable"
      end)
    end

    test "does not set the job to retryable if retrying wouldn't fix the issue", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Something something Video unavailable something something", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id, quality_upgrade?: true}))

        assert job.state == "completed"
      end)
    end

    test "snoozes the job instead of retrying if youtube thinks you're a bot", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Sign in to confirm you're not a bot", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id, quality_upgrade?: true}))

        assert job.state == "scheduled"
      end)
    end

    test "does not set the job to retryable you aren't a member", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          {:error, "This video is available to this channel's members on level: foo", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id, quality_upgrade?: true}))

        assert job.state == "completed"
      end)
    end

    test "ensures error are returned in a 2-item tuple", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "error", 1}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download if the source is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Sources.update_source(media_item.source, %{download_media: false})

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download if the media item is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "saves the file's size to the database", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          metadata = render_parsed_metadata(:media_metadata)
          FilesystemUtils.write_p!(metadata["filepath"], "test")

          {:ok, Phoenix.json_library().encode!(metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload(media_item)

      assert media_item.media_size_bytes > 0
    end

    test "does not set redownloaded_at by default", %{media_item: media_item} do
      perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload(media_item)

      assert media_item.media_redownloaded_at == nil
    end

    test "does not blow up if the record doesn't exist" do
      assert :ok = perform_job(MediaDownloadWorker, %{id: 0})
    end

    test "sets the no_force_overwrites runner option", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :no_force_overwrites in opts
          refute :force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download if the media item isn't pending download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end
  end

  describe "perform/1 when testing non-downloadable media" do
    test "does not retry the job if the media is currently not downloadable", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn _url, :get_downloadable_status, _opts, _ot, _addl ->
        {:ok, Phoenix.json_library().encode!(%{"live_status" => "is_live"})}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

        assert job.state == "completed"
      end)
    end
  end

  describe "perform/1 when testing forced downloads" do
    test "ignores 'prevent_download' if forced", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      Sources.update_source(media_item.source, %{download_media: false})
      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end

    test "ignores whether the media item is pending when forced", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end

    test "sets force_overwrites runner option", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :force_overwrites in opts
          refute :no_force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end
  end

  describe "perform/1 when testing re-downloads" do
    test "sets redownloaded_at on the media_item", %{media_item: media_item} do
      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
      media_item = Repo.reload(media_item)

      assert media_item.media_redownloaded_at != nil
    end

    test "ignores whether the media item is pending when re-downloaded", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    test "doesn't redownload if the source is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Sources.update_source(media_item.source, %{download_media: false})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    test "doesn't redownload if the media item is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    test "sets force_overwrites runner option", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :force_overwrites in opts
          refute :no_force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end

    test "deletes old files if the media item has been updated" do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          tmp_media_item = media_item_with_attachments()
          metadata = render_parsed_metadata(:media_metadata)
          metadata = Map.put(metadata, "filepath", tmp_media_item.media_filepath)

          {:ok, Phoenix.json_library().encode!(metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      old_media_item = media_item_with_attachments()
      perform_job(MediaDownloadWorker, %{id: old_media_item.id, force: true})
      updated_media_item = Repo.reload(old_media_item)

      assert updated_media_item.media_filepath != old_media_item.media_filepath
      refute File.exists?(old_media_item.media_filepath)
      assert File.exists?(updated_media_item.media_filepath)
    end
  end

  describe "perform/1 when testing user script callbacks" do
    test "calls the media_pre_download user script runner", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, data ->
        assert data.id == media_item.id

        {:ok, "", 0}
      end)

      expect(UserScriptRunnerMock, :run, fn :media_downloaded, _ -> {:ok, "", 0} end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download the media if the pre-download script returns an error", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 1} end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload!(media_item)

      refute media_item.media_filepath
      assert media_item.prevent_download
    end

    test "downloads media if the pre-download script is not present", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, :no_executable} end)
      expect(UserScriptRunnerMock, :run, fn :media_downloaded, _ -> {:ok, :no_executable} end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload!(media_item)

      assert media_item.media_filepath
      refute media_item.prevent_download
    end

    test "calls the media_downloaded user script runner", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 0} end)

      expect(UserScriptRunnerMock, :run, fn :media_downloaded, data ->
        assert data.id == media_item.id

        {:ok, "", 0}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end
  end

  describe "perform/1 error handling and backoff" do
    test "permanent errors prevent future downloads", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          {:error, "ERROR: [youtube] abc: Private video. Sign in if you've been granted access", 1}
      end)

      assert {:ok, :non_retry} = perform_job(MediaDownloadWorker, %{id: media_item.id})

      media_item = Repo.reload(media_item)
      assert media_item.prevent_download
      assert media_item.last_error =~ "Private video"
      assert media_item.download_failure_count == 0
    end

    test "permanent errors do not prevent downloads of already downloaded media", %{media_item: media_item} do
      {:ok, media_item} = Media.update_media_item(media_item, %{media_filepath: "/video/existing.mp4"})

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Private video", 1}
      end)

      assert {:ok, :non_retry} = perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})

      refute Repo.reload(media_item).prevent_download
    end

    test "a retryable failure that is not the last attempt does not count", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "ERROR: Postprocessing: Conversion failed!", 1}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id}, attempt: 1)
      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id}, attempt: 2)

      media_item = Repo.reload(media_item)
      assert media_item.download_failure_count == 0
      assert media_item.download_retry_after == nil
    end

    test "a retryable failure on the last attempt counts once and backs off", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "ERROR: Postprocessing: Conversion failed!", 1}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id}, attempt: 3)

      media_item = Repo.reload(media_item)
      assert media_item.download_failure_count == 1
      assert DateTime.diff(media_item.download_retry_after, DateTime.utc_now(), :hour) in 23..24
      refute media_item.prevent_download
      refute Media.pending_download?(media_item)
    end

    test "the worker uses 3 max attempts" do
      assert MediaDownloadWorker.new(%{id: 1}).changes.max_attempts == 3
    end

    test "gives up on the 5th failed run", %{media_item: media_item} do
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          download_failure_count: 4,
          download_retry_after: DateTime.add(DateTime.utc_now(), -1, :minute)
        })

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "ERROR: Postprocessing: Conversion failed!", 1}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id}, attempt: 3)

      media_item = Repo.reload(media_item)
      assert media_item.download_failure_count == 5
      assert media_item.prevent_download
      assert media_item.last_error =~ "Conversion failed"
    end

    test "a successful download resets the backoff", %{media_item: media_item} do
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          download_failure_count: 3,
          download_retry_after: DateTime.add(DateTime.utc_now(), -1, :minute),
          last_error: "old error"
        })

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})

      media_item = Repo.reload(media_item)
      assert media_item.download_failure_count == 0
      assert media_item.download_retry_after == nil
      assert media_item.last_error == nil
    end

    test "does not download an item that is still backing off", %{media_item: media_item} do
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          download_failure_count: 1,
          download_retry_after: DateTime.add(DateTime.utc_now(), 1, :day)
        })

      stub(YtDlpRunnerMock, :run, fn _url, _action, _opts, _ot, _addl -> flunk("yt-dlp should not be called") end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
    end
  end

  describe "perform/1 when rate limited" do
    test "a rate limit pauses downloads and snoozes without counting", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "ERROR: HTTP Error 429: Too Many Requests", 1}
      end)

      assert {:snooze, seconds} = perform_job(MediaDownloadWorker, %{id: media_item.id}, attempt: 3)
      assert seconds in (24 * 3600 - 5)..(24 * 3600 + 1)

      assert %DateTime{} = paused_until = Settings.get!(:downloads_paused_until)
      assert DateTime.diff(paused_until, DateTime.utc_now(), :hour) in 23..24

      media_item = Repo.reload(media_item)
      assert media_item.download_failure_count == 0
      assert media_item.download_retry_after == nil
      refute media_item.prevent_download
    end

    test "YouTube's 'try again later' unavailable wording is a rate limit", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          {:error, "ERROR: [youtube] abc: Video unavailable. This content isn't available, try again later.", 1}
      end)

      assert {:snooze, _} = perform_job(MediaDownloadWorker, %{id: media_item.id})

      refute Repo.reload(media_item).prevent_download
      assert Settings.get!(:downloads_paused_until)
    end

    test "while paused, snoozes until the pause ends without calling yt-dlp", %{media_item: media_item} do
      paused_until = DateTime.utc_now() |> DateTime.add(2, :hour) |> DateTime.truncate(:second)
      Settings.set(downloads_paused_until: paused_until)

      stub(YtDlpRunnerMock, :run, fn _url, _action, _opts, _ot, _addl -> flunk("yt-dlp should not be called") end)
      stub(UserScriptRunnerMock, :run, fn _event, _data -> flunk("user scripts should not run while paused") end)

      assert {:snooze, seconds} = perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
      assert seconds in (2 * 3600 - 5)..(2 * 3600 + 1)

      assert Repo.reload(media_item).media_filepath == nil
    end

    test "downloads again once the pause is over", %{media_item: media_item} do
      Settings.set(downloads_paused_until: DateTime.add(DateTime.utc_now(), -1, :minute))

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      assert Repo.reload(media_item).media_filepath != nil
    end
  end

  describe "perform/1 when subtitles fail" do
    @subtitle_429 "ERROR: Unable to download video subtitles for 'en': HTTP Error 429: Too Many Requests"
    @sub_keys [:write_subs, :write_auto_subs, :embed_subs, :sub_langs, :convert_subs]

    setup %{media_item: media_item} do
      {:ok, _} =
        Pinchflat.Profiles.update_media_profile(media_item.source.media_profile, %{
          download_subs: true,
          download_auto_subs: true,
          embed_subs: true,
          sub_langs: "en"
        })

      :ok
    end

    defp has_sub_opts?(opts) do
      Enum.any?(opts, fn
        {key, _} -> key in @sub_keys
        key -> key in @sub_keys
      end)
    end

    test "retries once without subtitles and succeeds", %{media_item: media_item} do
      test_pid = self()

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}

        _url, :download, opts, _ot, _addl ->
          send(test_pid, {:download_opts, opts})

          if has_sub_opts?(opts),
            do: {:error, @subtitle_429, 1},
            else: {:ok, render_metadata(:media_metadata)}
      end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})

      assert_received {:download_opts, first_opts}
      assert_received {:download_opts, second_opts}
      refute_received {:download_opts, _}

      assert has_sub_opts?(first_opts)
      refute has_sub_opts?(second_opts)

      media_item = Repo.reload(media_item)
      assert media_item.media_filepath != nil
      assert media_item.last_error == nil
      assert media_item.download_failure_count == 0
      refute Settings.get!(:downloads_paused_until)
    end

    test "a success after the fallback resets the backoff", %{media_item: media_item} do
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          download_failure_count: 2,
          download_retry_after: DateTime.add(DateTime.utc_now(), -1, :minute)
        })

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}

        _url, :download, opts, _ot, _addl ->
          if has_sub_opts?(opts), do: {:error, @subtitle_429, 1}, else: {:ok, render_metadata(:media_metadata)}
      end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})

      media_item = Repo.reload(media_item)
      assert media_item.download_failure_count == 0
      assert media_item.download_retry_after == nil
    end

    test "a permanent error on the fallback prevents the download", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          if has_sub_opts?(opts),
            do: {:error, @subtitle_429, 1},
            else: {:error, "ERROR: [youtube] abc: Private video. Sign in if you've been granted access", 1}
      end)

      assert {:ok, :non_retry} = perform_job(MediaDownloadWorker, %{id: media_item.id})

      media_item = Repo.reload(media_item)
      assert media_item.prevent_download
      assert media_item.last_error =~ "Private video"
      refute Settings.get!(:downloads_paused_until)
    end

    test "a retryable error on the fallback counts against the item", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          if has_sub_opts?(opts),
            do: {:error, @subtitle_429, 1},
            else: {:error, "ERROR: Postprocessing: Conversion failed!", 1}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id}, attempt: 3)

      media_item = Repo.reload(media_item)
      assert media_item.download_failure_count == 1
      refute Settings.get!(:downloads_paused_until)
    end

    test "a subtitle error never pauses downloads, even if the fallback hits it too", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, @subtitle_429, 1}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id}, attempt: 3)

      refute Settings.get!(:downloads_paused_until)
      media_item = Repo.reload(media_item)
      assert media_item.download_failure_count == 1
      refute media_item.prevent_download
    end
  end
end
