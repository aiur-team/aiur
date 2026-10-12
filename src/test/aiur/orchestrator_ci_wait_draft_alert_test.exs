defmodule Aiur.OrchestratorCiWaitDraftAlertTest do
  use ExUnit.Case, async: false

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CiLifecycle, State}

  test "alerts after a draft has remained in ci-wait without requiring a worker rewake" do
    identifier = "ci-wait-draft-#{System.unique_integer([:positive])}"
    topic = "ticket.#{identifier}.pr.draft_ci_wait"
    ref = make_ref()
    issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait"}
    result = %{decision: :pending, pending_reason: :draft_pull_request, pr_number: 943, draft?: true}

    emitter = fn alert_topic, opts ->
      send(self(), {:alert, ref, alert_topic, opts})
      :ok
    end

    first = poll_ci(%State{}, issue, result, emitter, 1_000)
    refute_received {:alert, ^ref, ^topic, _opts}

    _overdue = poll_ci(first, issue, result, emitter, 1_000 + 5 * 60_000)

    assert_received {:alert, ^ref, ^topic, alert_opts}
    assert Keyword.get(alert_opts, :needs_attention) == true
  end

  defp poll_ci(state, issue, result, emitter, now_ms) do
    CiLifecycle.poll_github_ci(state,
      ci_failure_digest: fn _, _ -> {:ok, %Aiur.CI.FailureDigest{}} end,
      parked_ready_alert_loader: fn -> MapSet.new() end,
      draft_stall_alert_loader: fn -> MapSet.new() end,
      ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
      ci_poller: fn [target], _opts -> {:ok, %{results: [Map.put(result, :target, target)], errors: []}} end,
      alert_emitter: emitter,
      ci_wait_draft_now_ms: now_ms
    )
  end
end
