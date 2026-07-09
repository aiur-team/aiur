defmodule Aiur.Codex.NotificationPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.NotificationPolicy

  describe "codex_error_method?/1" do
    test "matches the bare 'error' method" do
      assert NotificationPolicy.codex_error_method?("error")
    end

    test "matches methods ending with /error" do
      assert NotificationPolicy.codex_error_method?("task/error")
      assert NotificationPolicy.codex_error_method?("turn/error")
    end

    test "does not match unrelated methods" do
      refute NotificationPolicy.codex_error_method?("turn/completed")
      refute NotificationPolicy.codex_error_method?("notification")
    end
  end

  describe "needs_input?/2" do
    test "returns true for known input-required methods" do
      assert NotificationPolicy.needs_input?("turn/input_required", %{})
      assert NotificationPolicy.needs_input?("turn/needs_input", %{})
      assert NotificationPolicy.needs_input?("turn/approval_required", %{})
    end

    test "returns true when payload has requiresInput flag" do
      assert NotificationPolicy.needs_input?("turn/custom", %{"requiresInput" => true})
    end

    test "returns true when payload has needsInput flag" do
      assert NotificationPolicy.needs_input?("turn/custom", %{"needsInput" => true})
    end

    test "returns true when params has requiresInput flag" do
      assert NotificationPolicy.needs_input?("turn/custom", %{"params" => %{"requiresInput" => true}})
    end

    test "returns false for non-turn methods" do
      refute NotificationPolicy.needs_input?("notification", %{"requiresInput" => true})
    end

    test "returns false for unrelated turn methods with no flags" do
      refute NotificationPolicy.needs_input?("turn/completed", %{})
    end
  end

  describe "turn_started_method?/1" do
    test "matches turn/started" do
      assert NotificationPolicy.turn_started_method?("turn/started")
    end

    test "does not match other methods" do
      refute NotificationPolicy.turn_started_method?("turn/completed")
      refute NotificationPolicy.turn_started_method?("notification")
    end
  end

  describe "thread_idle_status?/2" do
    test "matches thread/status/changed with nested params idle status" do
      assert NotificationPolicy.thread_idle_status?(
               "thread/status/changed",
               %{"params" => %{"status" => %{"type" => "idle"}}}
             )
    end

    test "matches thread/status/changed with root idle status" do
      assert NotificationPolicy.thread_idle_status?(
               "thread/status/changed",
               %{"status" => %{"type" => "idle"}}
             )
    end

    test "does not match non-idle status" do
      refute NotificationPolicy.thread_idle_status?(
               "thread/status/changed",
               %{"params" => %{"status" => %{"type" => "running"}}}
             )
    end

    test "does not match different methods" do
      refute NotificationPolicy.thread_idle_status?("notification", %{"status" => %{"type" => "idle"}})
    end
  end

  describe "checkpoint_for_method/1" do
    test "tool call gets tool_result kind" do
      assert %{kind: :tool_result, method: "item/tool/call"} =
               NotificationPolicy.checkpoint_for_method("item/tool/call")
    end

    test "other methods get notification kind" do
      assert %{kind: :notification, method: "turn/started"} =
               NotificationPolicy.checkpoint_for_method("turn/started")
    end
  end

  describe "protocol_message_candidate?/1" do
    test "JSON objects are candidates" do
      assert NotificationPolicy.protocol_message_candidate?(~s({"method": "foo"}))
    end

    test "JSON arrays are candidates" do
      assert NotificationPolicy.protocol_message_candidate?("[1, 2]")
    end

    test "leading whitespace is stripped before checking" do
      assert NotificationPolicy.protocol_message_candidate?("  {\"a\": 1}")
    end

    test "plain text is not a candidate" do
      refute NotificationPolicy.protocol_message_candidate?("Codex output line")
    end
  end

  describe "no_active_turn_error?/1" do
    test "matches -32600 error code" do
      assert NotificationPolicy.no_active_turn_error?(%{"code" => -32_600})
    end

    test "matches message containing 'no active turn'" do
      assert NotificationPolicy.no_active_turn_error?(%{"message" => "no active turn to interrupt"})
    end

    test "returns false for other errors" do
      refute NotificationPolicy.no_active_turn_error?(%{"code" => -32_700})
      refute NotificationPolicy.no_active_turn_error?(%{"message" => "some other error"})
      refute NotificationPolicy.no_active_turn_error?(:timeout)
    end
  end

  describe "unretryable_codex_error?/1" do
    test "willRetry:false at root trips unretryable" do
      assert NotificationPolicy.unretryable_codex_error?(%{"willRetry" => false})
    end

    test "willRetry:false inside params trips unretryable" do
      assert NotificationPolicy.unretryable_codex_error?(%{"params" => %{"willRetry" => false}})
    end

    test "snake_case will_retry:false is honored" do
      assert NotificationPolicy.unretryable_codex_error?(%{"params" => %{"will_retry" => false}})
    end

    test "willRetry:true is retryable" do
      refute NotificationPolicy.unretryable_codex_error?(%{"params" => %{"willRetry" => true}})
    end

    test "absent willRetry is retryable" do
      refute NotificationPolicy.unretryable_codex_error?(%{"params" => %{"message" => "blip"}})
    end
  end

  describe "codex_quota_exhausted?/2" do
    test "error method + willRetry:false + usage limit text = quota exhausted" do
      payload = %{"params" => %{"willRetry" => false, "codexErrorInfo" => "usageLimitExceeded"}}
      assert NotificationPolicy.codex_quota_exhausted?("error", payload)
    end

    test "non-error method is not quota exhausted" do
      payload = %{"params" => %{"willRetry" => false, "codexErrorInfo" => "usageLimitExceeded"}}
      refute NotificationPolicy.codex_quota_exhausted?("turn/completed", payload)
    end

    test "retryable error with usage limit is not quota exhausted" do
      payload = %{"params" => %{"willRetry" => true, "message" => "approaching usage limit, retrying"}}
      refute NotificationPolicy.codex_quota_exhausted?("error", payload)
    end

    test "unretryable error without usage limit is not quota exhausted" do
      payload = %{"params" => %{"willRetry" => false, "message" => "bwrap: sandbox refused"}}
      refute NotificationPolicy.codex_quota_exhausted?("error", payload)
    end
  end

  describe "usage_limit_exceeded?/1" do
    test "detects usageLimitExceeded (camelCase)" do
      assert NotificationPolicy.usage_limit_exceeded?(%{"params" => %{"codexErrorInfo" => "usageLimitExceeded"}})
    end

    test "detects 'usage limit' phrase" do
      assert NotificationPolicy.usage_limit_exceeded?(%{"params" => %{"message" => "You've hit your usage limit"}})
    end

    test "returns false for unrelated errors" do
      refute NotificationPolicy.usage_limit_exceeded?(%{"params" => %{"message" => "bwrap: sandbox refused"}})
    end
  end

  describe "usage_limit_pause/2" do
    test "builds pause payload with kind, reason, and reset_hint" do
      payload = %{
        "params" => %{
          "willRetry" => false,
          "message" => "You've hit your usage limit. Try again at 11:43 PM."
        }
      }

      pause = NotificationPolicy.usage_limit_pause(payload, "error")
      assert pause.kind == :usage_limit_exhausted
      assert pause.reset_hint == "11:43 PM"
      assert is_binary(pause.reason)
    end

    test "reset_hint is nil when no try-again phrase" do
      payload = %{"params" => %{"willRetry" => false, "codexErrorInfo" => "usageLimitExceeded"}}
      pause = NotificationPolicy.usage_limit_pause(payload, "error")
      assert pause.kind == :usage_limit_exhausted
      assert pause.reset_hint == nil
    end
  end

  describe "codex_error_reason/2" do
    test "includes method and message detail" do
      payload = %{"params" => %{"willRetry" => false, "message" => "usageLimitExceeded"}}
      assert NotificationPolicy.codex_error_reason(payload, "error") == "error: usageLimitExceeded"
    end

    test "falls back to method when no detail present" do
      assert NotificationPolicy.codex_error_reason(%{"params" => %{}}, "task/error") == "task/error"
    end

    test "prefers codexErrorInfo detail" do
      payload = %{"params" => %{"codexErrorInfo" => "quota_exceeded"}}
      assert NotificationPolicy.codex_error_reason(payload, "error") == "error: quota_exceeded"
    end
  end

  describe "usage_limit_reset_hint/1" do
    test "extracts reset time from human-readable message" do
      payload = %{
        "params" => %{"message" => "You've hit your usage limit. Purchase more credits or try again at 11:43 PM."}
      }

      assert NotificationPolicy.usage_limit_reset_hint(payload) == "11:43 PM"
    end

    test "returns nil when no try-again phrase present" do
      refute NotificationPolicy.usage_limit_reset_hint(%{"params" => %{"message" => "usageLimitExceeded"}})
    end
  end
end
