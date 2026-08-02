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
end
