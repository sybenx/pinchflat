defmodule Pinchflat.Downloading.DownloadErrorClassifier do
  @moduledoc """
  Sorts a yt-dlp download error message into one of three kinds:

    - `:rate_limited`: YouTube is throttling us (HTTP 429, "Too Many Requests",
      "try again later", the "not a bot" check). Not the media item's fault, so it
      pauses all downloads instead of counting against the item.
    - `:permanent`: retrying will never help (members-only, private, removed,
      terminated account, age-restricted, copyright, region-blocked). The item is
      marked `prevent_download`.
    - `:retryable`: anything else, including network trouble, subtitle failures
      and failed conversions. Counts against the item's download backoff.

  The patterns match `tube-api/user-scripts/lifecycle` exactly. The temporary
  patterns are checked first so a mixed message is never treated as permanent.
  Note that "Video unavailable. This content isn't available, try again later" is
  YouTube's rate-limit wording, which the temporary check catches first.
  """

  # The lifecycle script's "temporary" list, split in two: the rate-limit part
  # pauses all downloads, the rest is an ordinary retryable failure.
  @rate_limit_pattern ~r/try again later|429|too many requests|not a bot|rate.?limit/i
  @other_temporary_pattern ~r/timed out|connection|network|temporar|HTTP Error 5[0-9][0-9]|subtitles|conversion failed|postprocessing/i

  @permanent_pattern ~r/members-only|channel's members|join this channel|private video|removed by the uploader|video unavailable|this video is unavailable|has been terminated|no longer available|confirm your age|inappropriate for some users|age.?restricted|copyright|not available in your country|uploader has not made this video available|blocked it in your country|geo.?restrict/i

  @doc """
  Classifies a download error message.

  Returns :rate_limited | :permanent | :retryable
  """
  def classify(message) do
    message = to_string(message)

    cond do
      Regex.match?(@rate_limit_pattern, message) -> :rate_limited
      Regex.match?(@other_temporary_pattern, message) -> :retryable
      Regex.match?(@permanent_pattern, message) -> :permanent
      true -> :retryable
    end
  end
end
