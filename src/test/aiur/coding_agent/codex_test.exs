defmodule Aiur.CodingAgent.CodexTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.AppServerPort
  alias Aiur.Codex.Config, as: CodexConfig
  alias Aiur.Codex.NotificationPolicy

  describe "codex_command/2 model and effort splice" do
    test "nil model leaves the configured command unchanged" do
      assert AppServerPort.codex_command_for_test(nil) == CodexConfig.command()
    end

    test "a model variant is appended as a single-quoted --config token" do
      command = AppServerPort.codex_command_for_test("gpt-5.5")
      assert command == CodexConfig.command() <> " --config 'model=\"gpt-5.5\"'"
      assert String.ends_with?(command, "--config 'model=\"gpt-5.5\"'")
    end

    test "an effort override is appended after model so it beats command defaults" do
      command = AppServerPort.codex_command_for_test("gpt-5.5", "high")

      assert command ==
               CodexConfig.command() <>
                 " --config 'model=\"gpt-5.5\"' --config 'model_reasoning_effort=\"high\"'"
    end

    test "config values are shell escaped as single arguments" do
      command = AppServerPort.codex_command_for_test("gpt'5.5", "high")

      assert command ==
               CodexConfig.command() <>
                 " --config 'model=\"gpt'\"'\"'5.5\"' --config 'model_reasoning_effort=\"high\"'"
    end
  end

  describe "unretryable codex error detection" do
    test "willRetry:false inside params trips the unretryable path" do
      payload = %{
        "method" => "error",
        "params" => %{"willRetry" => false, "message" => "usageLimitExceeded"}
      }

      assert NotificationPolicy.unretryable_codex_error?(payload)

      assert NotificationPolicy.codex_error_reason(payload, "error") ==
               "error: usageLimitExceeded"
    end

    test "willRetry:false at the notification root also trips it" do
      assert NotificationPolicy.unretryable_codex_error?(%{"willRetry" => false})
    end

    test "snake_case will_retry:false is honored" do
      assert NotificationPolicy.unretryable_codex_error?(%{"params" => %{"will_retry" => false}})
    end

    test "willRetry:true is retryable (continues, not a hard failure)" do
      refute NotificationPolicy.unretryable_codex_error?(%{"params" => %{"willRetry" => true}})
    end

    test "absent willRetry is retryable" do
      refute NotificationPolicy.unretryable_codex_error?(%{
               "params" => %{"message" => "transient blip"}
             })
    end

    test "reason falls back to the method when no detail field is present" do
      assert NotificationPolicy.codex_error_reason(
               %{"params" => %{"willRetry" => false}},
               "task/error"
             ) == "task/error"
    end

    test "reason reaches a codexErrorInfo detail instead of the bare method" do
      payload = %{"params" => %{"willRetry" => false, "codexErrorInfo" => "usageLimitExceeded"}}

      assert NotificationPolicy.codex_error_reason(payload, "error") ==
               "error: usageLimitExceeded"
    end

    test "reason reaches a nested error.message detail" do
      payload = %{"params" => %{"error" => %{"message" => "overloaded"}}}

      assert NotificationPolicy.codex_error_reason(payload, "task/error") ==
               "task/error: overloaded"
    end
  end

  describe "codex usage-limit (quota exhausted) detection" do
    test "a usageLimitExceeded error is detected as a quota pause" do
      payload = %{
        "method" => "error",
        "params" => %{
          "willRetry" => false,
          "codexErrorInfo" => "usageLimitExceeded",
          "message" => "You've hit your usage limit. Purchase more credits or try again at 11:43 PM."
        }
      }

      assert NotificationPolicy.usage_limit_exceeded?(payload)
    end

    test "an ordinary willRetry:false error is not a quota pause" do
      payload = %{
        "method" => "error",
        "params" => %{"willRetry" => false, "message" => "bwrap: sandbox refused"}
      }

      refute NotificationPolicy.usage_limit_exceeded?(payload)
    end

    test "the reset time is extracted from the human message" do
      payload = %{
        "params" => %{
          "message" => "You've hit your usage limit. Purchase more credits or try again at 11:43 PM."
        }
      }

      assert NotificationPolicy.usage_limit_reset_hint(payload) == "11:43 PM"
    end

    test "the reset hint is nil when no try-again phrase is present" do
      refute NotificationPolicy.usage_limit_reset_hint(%{
               "params" => %{"message" => "usageLimitExceeded"}
             })
    end

    test "a quota error routes to a pause carrying the reset hint, not an unretryable error" do
      payload = %{
        "method" => "error",
        "params" => %{
          "willRetry" => false,
          "codexErrorInfo" => "usageLimitExceeded",
          "message" => "You've hit your usage limit. Purchase more credits or try again at 11:43 PM."
        }
      }

      assert NotificationPolicy.codex_quota_exhausted?("error", payload)
      pause = NotificationPolicy.usage_limit_pause(payload, "error")
      assert pause.kind == :usage_limit_exhausted
      assert pause.reset_hint == "11:43 PM"
      # The pause carries the real backend detail, never the opaque bare "error".
      assert pause.reason =~ "usage limit"
      refute pause.reason == "error"
    end

    test "an ordinary unretryable error still routes to a turn_unretryable error, not a pause" do
      payload = %{
        "method" => "error",
        "params" => %{"willRetry" => false, "message" => "bwrap: sandbox refused"}
      }

      refute NotificationPolicy.codex_quota_exhausted?("error", payload)

      assert NotificationPolicy.codex_error_method?("error") and
               NotificationPolicy.unretryable_codex_error?(payload)

      assert NotificationPolicy.codex_error_reason(payload, "error") ==
               "error: bwrap: sandbox refused"
    end

    test "a retryable error mentioning a usage limit is NOT a quota pause" do
      # willRetry:true means codex will retry; pausing would strand the agent
      # (no auto-resume), so a transient "usage limit" mention must not pause.
      payload = %{
        "method" => "error",
        "params" => %{"willRetry" => true, "message" => "approaching usage limit, retrying"}
      }

      refute NotificationPolicy.codex_quota_exhausted?("error", payload)
    end
  end
end
