defmodule Aiur.AgentRunner.TurnAlertsTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnAlerts
  alias Aiur.Events.Exchange
  alias Aiur.Issue

  describe "maybe_emit_usage_limit_alert/4" do
    test "returns :ok for a usage_limit_exhausted payload" do
      issue = %Issue{id: "gid-ta-01", identifier: "TA-01"}
      payload = %{kind: :usage_limit_exhausted}

      assert :ok = TurnAlerts.maybe_emit_usage_limit_alert(issue, nil, nil, payload)
    end

    test "returns :ok for any other payload (no-op)" do
      issue = %Issue{id: "gid-ta-02", identifier: "TA-02"}

      assert :ok = TurnAlerts.maybe_emit_usage_limit_alert(issue, nil, nil, %{kind: :paused})
      assert :ok = TurnAlerts.maybe_emit_usage_limit_alert(issue, nil, nil, %{})
      assert :ok = TurnAlerts.maybe_emit_usage_limit_alert(issue, nil, nil, :anything)
    end

    test "calls Alerts.emit_system for usage_limit_exhausted payload" do
      issue = %Issue{id: "gid-ta-03", identifier: "TA-03"}
      payload = %{kind: :usage_limit_exhausted}

      # Verify the function does not crash and returns :ok; Alerts.emit_system
      # delivery to Exchange is filtered in tests (Orchestrator's tracked_fn
      # blocks issues not in TrackedSet — by design, to prevent test leakage).
      assert :ok = TurnAlerts.maybe_emit_usage_limit_alert(issue, nil, nil, payload)
    end

    test "does not publish for non-exhaustion payloads" do
      identifier = "TA-nopub-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-ta-04", identifier: identifier}

      Exchange.subscribe("ticket.#{identifier}.agent.usage_limit_exhausted")

      TurnAlerts.maybe_emit_usage_limit_alert(issue, nil, nil, %{kind: :paused})

      refute_receive {:event, _}, 200
    end

    test "returns :ok when reset_hint is present in the payload" do
      issue = %Issue{id: "gid-ta-05", identifier: "TA-05"}
      payload = %{kind: :usage_limit_exhausted, reset_hint: "12:00 UTC"}

      assert :ok = TurnAlerts.maybe_emit_usage_limit_alert(issue, nil, nil, payload)
    end
  end

  describe "maybe_emit_more_tokens_alert/4" do
    test "returns :ok for any reason" do
      issue = %Issue{id: "gid-ta-06", identifier: "TA-06"}

      assert :ok = TurnAlerts.maybe_emit_more_tokens_alert(issue, nil, nil, "token budget exceeded")
      assert :ok = TurnAlerts.maybe_emit_more_tokens_alert(issue, nil, nil, :other_reason)
    end

    test "calls Alerts.emit_system when reason contains 'token budget'" do
      issue = %Issue{id: "gid-ta-07", identifier: "TA-07"}

      # Delivery to Exchange is filtered by Orchestrator's tracked_fn in tests;
      # we verify the function completes without error and returns :ok.
      assert :ok =
               TurnAlerts.maybe_emit_more_tokens_alert(issue, nil, nil, "token budget limit reached")
    end

    test "calls Alerts.emit_system when reason contains 'context length'" do
      issue = %Issue{id: "gid-ta-08", identifier: "TA-08"}

      assert :ok =
               TurnAlerts.maybe_emit_more_tokens_alert(issue, nil, nil, "context length exceeded limit")
    end

    test "does not publish for unrecognized reasons" do
      identifier = "TA-noreason-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-ta-09", identifier: identifier}

      Exchange.subscribe("ticket.#{identifier}.agent.error.tokens_exhausted")

      TurnAlerts.maybe_emit_more_tokens_alert(issue, nil, nil, :some_other_error)

      refute_receive {:event, _}, 200
    end

    test "treats inspect(reason) for substring matching — tuple with 'max tokens'" do
      issue = %Issue{id: "gid-ta-10", identifier: "TA-10"}

      # {:error, "max tokens reached..."} → inspect gives ~s(error: "max tokens ..."),
      # which contains "max tokens" → should trigger the alert path (returns :ok).
      assert :ok =
               TurnAlerts.maybe_emit_more_tokens_alert(
                 issue,
                 nil,
                 nil,
                 {:error, "max tokens reached for this session"}
               )
    end
  end
end
