defmodule Aiur.Orchestrator.NonblockingQuestionTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionStore, Issue}
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator.{PushRouting, State, StatusReport}

  setup do
    dir = Aiur.TestSupport.tmp_root!("nonblocking-question")
    Aiur.TestSupport.put_runtime_state_dir!(Path.join(dir, "runtime"))
    :ok = Aiur.TestSupport.ensure_subscription_store_supervisor_running()
    identifier = "question-#{System.unique_integer([:positive])}"
    :ok = SubscriptionStore.attach(identifier)
    on_exit(fn -> SubscriptionStore.stop(identifier) end)

    issue = %Issue{id: identifier, identifier: identifier, state: "in-progress"}
    entry = %{identifier: identifier, issue: issue, pid: self(), started_at: DateTime.utc_now(), control: %{status: :working, can_interrupt: true}}
    %{issue: issue, state: %State{running: %{identifier => entry}}}
  end

  test "a non-blocking Command records the question without pausing the worker", %{issue: issue, state: state} do
    decision = request!(issue, false)
    :ok = SubscriptionStore.add_attention(issue.identifier, "optional-question")

    for event <- [%{}, %{payload: %{reason: "optional_question", question: decision.question}}] do
      result = PushRouting.maybe_pause_on_request(state, issue.identifier, event)
      assert result == state
      assert result.running[issue.id].control.status == :working
      refute_receive {:pause_agent, _}, 50
    end

    assert {:ok, retained} = DecisionStore.get(decision.decision_id)
    assert retained.question == "Should the Executor own the follow-up census?"
    assert retained.decision_status == :open
    assert SubscriptionStore.open_attention_count(issue.identifier) == 1
    [status] = StatusReport.agent_statuses(state)
    assert status.open_decision_count == 0
    assert status.waiting_reason == :active
  end

  test "only an open blocking Command holds waiting_for_human, even with a stale attention", %{issue: issue, state: state} do
    decision = request!(issue, true)
    :ok = SubscriptionStore.add_attention(issue.identifier, "old-question")
    [waiting] = StatusReport.agent_statuses(state)
    assert waiting.open_decision_count == 1
    assert waiting.waiting_reason == :waiting_for_human

    paused = PushRouting.maybe_pause_on_request(state, issue.identifier)
    assert paused.running[issue.id].control.status == :paused
    assert paused.running[issue.id].paused_reason == :agent_pause_request

    assert {:ok, %{decision: expired}} = DecisionStore.expire(decision.decision_id, "agent_not_running")
    assert expired.decision_status == :expired
    assert SubscriptionStore.open_attention_count(issue.identifier) == 1

    [active] = StatusReport.agent_statuses(state)
    assert active.open_decision_count == 0
    assert active.waiting_reason == :active
    [previously_paused] = StatusReport.agent_statuses(paused)
    assert previously_paused.waiting_reason == :paused
    assert {:ok, ids} = DecisionStore.blocked_ticket_ids()
    refute MapSet.member?(ids, issue.identifier)
  end

  test "bare coordination and upstream-merge pauses work without a Command", %{issue: issue, state: state} do
    for event <- [%{}, %{payload: %{reason: "upstream_merge"}}] do
      paused = PushRouting.maybe_pause_on_request(state, issue.identifier, event)
      assert paused.running[issue.id].control.status == :paused
      assert paused.running[issue.id].paused_reason == :agent_pause_request
    end
  end

  test "legacy operator-decision attention still pauses without a blocking Command", %{issue: issue, state: state} do
    question = "Which acceptance boundary must the worker use?"

    assert {:ok, %{decision: legacy}} =
             DecisionStore.project_attention(
               %{"question" => question, "blocking" => false, "kind" => "legacy_attention", "source_id" => "legacy:#{issue.id}"},
               ticket: %{identifier: issue.identifier},
               source: %{agent_id: "worker", session_id: "session", event_id: nil},
               legacy_attention: %{slug: "operator-decision", topic: "ticket.#{issue.id}.agent.attention.operator-decision"}
             )

    assert legacy.blocking == false
    bare = PushRouting.maybe_pause_on_request(state, issue.identifier)
    assert bare.running[issue.id].control.status == :paused
    request!(issue, false)
    assert {:ok, []} = DecisionStore.open_blocking_decision_ids([issue.identifier])
    paused = PushRouting.maybe_pause_on_request(state, issue.identifier, %{payload: %{reason: "operator_decision", question: question}})
    assert paused.running[issue.id].control.status == :paused
  end

  test "a blocking Command takes precedence over an optional question", %{issue: issue, state: state} do
    # Future regression guard: the blocking Command already took precedence before this correction.
    request!(issue, false)
    request!(issue, true)
    paused = PushRouting.maybe_pause_on_request(state, issue.identifier)
    assert paused.running[issue.id].control.status == :paused
  end

  test "an expired optional question does not suppress a coordination pause", %{issue: issue, state: state} do
    decision = request!(issue, false)
    assert {:ok, _} = DecisionStore.expire(decision.decision_id, "agent_not_running")
    paused = PushRouting.maybe_pause_on_request(state, issue.identifier)
    assert paused.running[issue.id].control.status == :paused
  end

  test "an explicit upstream-merge pause survives an unrelated optional question", %{issue: issue, state: state} do
    request!(issue, false)
    paused = PushRouting.maybe_pause_on_request(state, issue.identifier, %{payload: %{reason: "upstream_merge"}})
    assert paused.running[issue.id].control.status == :paused
  end

  defp request!(issue, blocking) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{"question" => "Should the Executor own the follow-up census?", "blocking" => blocking},
               ticket: %{identifier: issue.identifier},
               source: %{agent_id: "worker", session_id: "session", event_id: nil}
             )

    decision
  end
end
