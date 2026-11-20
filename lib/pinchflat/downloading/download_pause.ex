defmodule Pinchflat.Downloading.DownloadPause do
  @moduledoc """
  A global pause on media downloads, set when YouTube rate-limits us.

  While paused, `MediaDownloadWorker` snoozes jobs until the pause ends instead
  of calling yt-dlp, and indexing does not enqueue new download jobs. Indexing
  itself carries on.
  """

  require Logger

  alias Pinchflat.Settings

  @pause_hours 24

  @doc """
  The pause length in hours.
  """
  def pause_hours, do: @pause_hours

  @doc """
  Returns the time downloads are paused until, or nil if they are not paused.

  Returns %DateTime{} | nil
  """
  def paused_until(now \\ DateTime.utc_now()) do
    case Settings.get!(:downloads_paused_until) do
      %DateTime{} = until -> if DateTime.compare(until, now) == :gt, do: until, else: nil
      _ -> nil
    end
  end

  @doc """
  Returns true if downloads are currently paused.
  """
  def paused?(now \\ DateTime.utc_now()), do: paused_until(now) != nil

  @doc """
  Pauses all downloads for #{@pause_hours} hours from now.

  Returns {:ok, %DateTime{}} | {:error, any()}
  """
  def pause!(reason, now \\ DateTime.utc_now()) do
    until = now |> DateTime.add(@pause_hours, :hour) |> DateTime.truncate(:second)

    Logger.warning(
      "YouTube rate limit hit. Pausing all downloads until #{until} UTC. " <>
        "Indexing continues. Error was: #{inspect(reason)}"
    )

    Settings.set(downloads_paused_until: until)
  end

  @doc """
  Seconds from now until the pause ends (at least 1), for snoozing a job.
  """
  def seconds_until_resume(%DateTime{} = until, now \\ DateTime.utc_now()) do
    max(DateTime.diff(until, now, :second), 0) + 1
  end
end
