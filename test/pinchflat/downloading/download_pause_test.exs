defmodule Pinchflat.Downloading.DownloadPauseTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.Downloading.DownloadPause

  test "is not paused by default" do
    refute DownloadPause.paused?()
    assert DownloadPause.paused_until() == nil
  end

  test "pause!/2 pauses downloads for 24 hours" do
    now = ~U[2026-11-20 12:00:00Z]

    assert {:ok, until} = DownloadPause.pause!("HTTP Error 429", now)

    assert until == ~U[2026-11-21 12:00:00Z]
    assert Settings.get!(:downloads_paused_until) == until
    assert DownloadPause.paused?(now)
    assert DownloadPause.paused_until(now) == until
  end

  test "a pause in the past does not count" do
    Settings.set(downloads_paused_until: ~U[2020-01-01 00:00:00Z])

    refute DownloadPause.paused?()
  end

  test "seconds_until_resume/2 is at least 1" do
    now = ~U[2026-11-20 12:00:00Z]

    assert DownloadPause.seconds_until_resume(~U[2026-11-20 13:00:00Z], now) == 3601
    assert DownloadPause.seconds_until_resume(~U[2026-11-20 11:00:00Z], now) == 1
  end
end
