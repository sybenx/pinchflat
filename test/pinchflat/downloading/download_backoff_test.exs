defmodule Pinchflat.Downloading.DownloadBackoffTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Media
  alias Pinchflat.Downloading.DownloadBackoff

  @now ~U[2026-11-20 12:00:00Z]

  describe "retry_delay_days/1" do
    test "backs off 1, 3, 7 then 30 days, then gives up" do
      assert DownloadBackoff.retry_delay_days(1) == 1
      assert DownloadBackoff.retry_delay_days(2) == 3
      assert DownloadBackoff.retry_delay_days(3) == 7
      assert DownloadBackoff.retry_delay_days(4) == 30
      assert DownloadBackoff.retry_delay_days(5) == nil
      assert DownloadBackoff.max_failures() == 5
    end
  end

  describe "record_failure/2" do
    test "follows the backoff schedule for failures 1 to 4" do
      media_item = media_item_fixture(%{media_filepath: nil})

      for {count, days} <- [{1, 1}, {2, 3}, {3, 7}, {4, 30}] do
        assert {:ok, updated} = DownloadBackoff.record_failure(media_item, @now)

        assert updated.download_failure_count == count
        assert updated.download_retry_after == DateTime.add(@now, days, :day)
        refute updated.prevent_download
      end
    end

    test "gives up on the 5th failure, keeping last_error" do
      media_item =
        media_item_fixture(%{media_filepath: nil, download_failure_count: 4, last_error: "ERROR: Conversion failed!"})

      assert {:ok, updated} = DownloadBackoff.record_failure(media_item, @now)

      assert updated.download_failure_count == 5
      assert updated.download_retry_after == nil
      assert updated.prevent_download
      assert updated.last_error == "ERROR: Conversion failed!"
      refute Media.pending_download?(updated)
    end

    test "reads the current count from the database, not the passed struct" do
      media_item = media_item_fixture(%{media_filepath: nil, download_failure_count: 2})
      stale = %{media_item | download_failure_count: 0}

      assert {:ok, updated} = DownloadBackoff.record_failure(stale, @now)
      assert updated.download_failure_count == 3
    end
  end
end
