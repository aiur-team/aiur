defmodule Aiur.Claude.NotificationPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.NotificationPolicy

  test "recognizes Claude rate-limit errors" do
    payload = %{"error" => %{"type" => "rate_limit_error", "message" => "rate limit exceeded"}}

    assert NotificationPolicy.usage_limit_exhausted?(payload)

    assert %{kind: :usage_limit_exhausted, reason: reason} =
             NotificationPolicy.usage_limit_pause(payload)

    assert reason =~ "rate_limit_error"
  end

  test "recognizes Claude HTTP 429 responses" do
    assert NotificationPolicy.usage_limit_exhausted?(%{
             "status" => 429,
             "message" => "too many requests"
           })
  end

  test "recognizes Claude StopFailure rate-limit categories" do
    assert NotificationPolicy.usage_limit_exhausted?(%{
             "hook_event_name" => "StopFailure",
             "error" => "rate_limit",
             "error_details" => "429 Too Many Requests"
           })
  end

  test "retains text fallback for structured turn failures" do
    assert NotificationPolicy.usage_limit_exhausted?(%{
             "error" => %{"message" => "You've hit your weekly usage limit"}
           })
  end

  test "does not classify unrelated turn failures as usage limits" do
    refute NotificationPolicy.usage_limit_exhausted?(%{
             "type" => "invalid_request_error",
             "message" => "bad input"
           })
  end

  describe "classify_stream_failure/1" do
    test "recognizes the session-limit refusal printed before the CLI exits" do
      diagnostics = """
      Loading credentials
      You've hit your session limit · resets 11:40pm (America/Los_Angeles)
      """

      assert {:paused, pause} = NotificationPolicy.classify_stream_failure(diagnostics)
      assert pause.kind == :usage_limit_exhausted
      assert pause.reason =~ "session limit"
      refute pause.reason =~ "Loading credentials"
      assert pause.reset_hint == "11:40pm (America/Los_Angeles)"
    end

    test "recognizes a free-text HTTP 429" do
      assert {:paused, %{kind: :usage_limit_exhausted}} =
               NotificationPolicy.classify_stream_failure("API Error: HTTP 429 from api.anthropic.com")

      assert {:paused, %{kind: :usage_limit_exhausted}} =
               NotificationPolicy.classify_stream_failure("request failed status=429")
    end

    test "leaves an ordinary crash unclassified" do
      diagnostics = """
      TypeError: cannot read properties of undefined
          at run (/opt/claude/cli.js:429:17)
      """

      assert NotificationPolicy.classify_stream_failure(diagnostics) == :unclassified
    end

    test "leaves empty output and non-text unclassified" do
      assert NotificationPolicy.classify_stream_failure("") == :unclassified
      assert NotificationPolicy.classify_stream_failure(nil) == :unclassified
    end
  end

  describe "reset_hint/1" do
    test "lifts a prose reset time" do
      assert NotificationPolicy.reset_hint("resets at 6:40am") == "6:40am"
      assert NotificationPolicy.reset_hint("· resets 11:40pm | plan info") == "11:40pm"
    end

    test "returns nil when the text states no reset" do
      assert NotificationPolicy.reset_hint("rate limit exceeded") == nil
    end
  end

  test "usage_limit_pause falls back to a prose reset time" do
    pause = NotificationPolicy.usage_limit_pause(%{"message" => "usage limit reached, resets at 3:00pm"})

    assert pause.reset_hint == "3:00pm"
  end

  test "usage_limit_pause prefers a structured reset field" do
    pause =
      NotificationPolicy.usage_limit_pause(%{
        "message" => "usage limit reached, resets at 3:00pm",
        "reset_at" => "2026-09-10T22:00:00Z"
      })

    assert pause.reset_hint == "2026-09-10T22:00:00Z"
  end
end
