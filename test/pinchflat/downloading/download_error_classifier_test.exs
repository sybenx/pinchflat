defmodule Pinchflat.Downloading.DownloadErrorClassifierTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Downloading.DownloadErrorClassifier

  describe "classify/1 with subtitle failures" do
    for message <- [
          "ERROR: Unable to download video subtitles for 'en': HTTP Error 429: Too Many Requests",
          "ERROR: Unable to download video subtitles for 'en': HTTP Error 404: Not Found",
          "WARNING: Unable to download video subtitles for 'de': timed out"
        ] do
      test "treats #{inspect(message)} as a subtitle failure, not a rate limit" do
        assert DownloadErrorClassifier.classify(unquote(message)) == :subtitles_failed
      end
    end
  end

  describe "classify/1 with permanent errors" do
    for message <- [
          "ERROR: [youtube] abc: This video is available to this channel's members on level: Tier 1",
          "ERROR: [youtube] abc: Join this channel to get access to members-only content like this video",
          "ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader",
          "ERROR: [youtube] abc: This video is unavailable",
          "ERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video",
          "ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.",
          "ERROR: [youtube] abc: This video is no longer available because the YouTube account associated with this video has been terminated.",
          "ERROR: [youtube] abc: Video unavailable. This video contains content from SomeLabel, who has blocked it in your country on copyright grounds",
          "ERROR: [youtube] abc: The uploader has not made this video available in your country",
          "ERROR: [youtube] abc: This video is age-restricted"
        ] do
      test "treats #{inspect(message)} as permanent" do
        assert DownloadErrorClassifier.classify(unquote(message)) == :permanent
      end
    end
  end

  describe "classify/1 with rate limits" do
    for message <- [
          "ERROR: [youtube] abc: Sign in to confirm you're not a bot. Use --cookies-from-browser",
          "ERROR: [youtube] abc: Video unavailable. This content isn't available, try again later.",
          "ERROR: [youtube] abc: HTTP Error 429: Too Many Requests",
          "HTTP Error 429",
          "Too Many Requests",
          "You have been rate-limited by YouTube",
          "rate limit exceeded"
        ] do
      test "treats #{inspect(message)} as a rate limit" do
        assert DownloadErrorClassifier.classify(unquote(message)) == :rate_limited
      end
    end
  end

  describe "classify/1 with other retryable errors" do
    for message <- [
          "ERROR: Postprocessing: Conversion failed!",
          "ERROR: [youtube] abc: Read timed out.",
          "ERROR: Unable to download webpage: <urlopen error [Errno -3] Temporary failure in name resolution>",
          "HTTP Error 503: Service Unavailable",
          "Connection reset by peer",
          "Something nobody has seen before",
          "",
          nil
        ] do
      test "treats #{inspect(message)} as retryable" do
        assert DownloadErrorClassifier.classify(unquote(message)) == :retryable
      end
    end

    test "checks temporary patterns before permanent ones" do
      # Contains both "Video unavailable" (permanent) and "connection" (temporary)
      assert DownloadErrorClassifier.classify("Video unavailable: connection reset") == :retryable
    end
  end
end
