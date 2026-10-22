defmodule Aiur.OrchestratorCiWaitDraftAlertTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CiLifecycle, State}

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github")
    :ok
  end

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

  test "resolves when the draft clears and starts a fresh alert delay on re-entry" do
    identifier = "ci-wait-draft-reentry-#{System.unique_integer([:positive])}"
    alert_topic = "ticket.#{identifier}.pr.draft_ci_wait"
    resolved_topic = alert_topic <> ".resolved"
    ref = make_ref()
    issue = %Issue{id: identifier, identifier: identifier, state: "ci-wait"}
    draft = %{decision: :pending, pending_reason: :draft_pull_request, pr_number: 944, draft?: true}
    ready = %{decision: :pending, pending_reason: :required_checks_pending, pr_number: 944, draft?: false}

    emitter = fn topic, opts ->
      send(self(), {:alert, ref, topic, opts})
      :ok
    end

    state = poll_ci(%State{}, issue, draft, emitter, 1_000)
    state = poll_ci(state, issue, draft, emitter, 301_000)
    assert_received {:alert, ^ref, ^alert_topic, _opts}

    state = poll_ci(state, issue, ready, emitter, 302_000)
    assert_received {:alert, ^ref, ^resolved_topic, resolved_opts}
    assert Keyword.get(resolved_opts, :needs_attention) == false

    state = poll_ci(state, issue, draft, emitter, 400_000)
    refute_received {:alert, ^ref, ^alert_topic, _opts}

    state = poll_ci(state, issue, draft, emitter, 700_000)
    assert_received {:alert, ^ref, ^alert_topic, alert_opts}
    assert Keyword.get(alert_opts, :needs_attention) == true

    outside_ci_wait = %{issue | state: "in-progress"}
    _state = poll_ci(state, outside_ci_wait, draft, emitter, 701_000)
    assert_received {:alert, ^ref, ^resolved_topic, resolved_opts}
    assert Keyword.get(resolved_opts, :needs_attention) == false
  end

  defp poll_ci(state, issue, result, emitter, now_ms) do
    # Each call is a separate tick; a published :ci cadence must not skip it (#4360).
    CiLifecycle.poll_github_ci(%{state | last_ci_poll_started_at_ms: nil},
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
