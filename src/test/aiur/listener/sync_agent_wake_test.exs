defmodule Aiur.Listener.SyncAgentWakeTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentQueueStore, Issue}
  alias Aiur.Orchestrator.{ListenerModes, OperatorMessages, State}

  setup do
    dir = Aiur.TestSupport.tmp_root!("sync-agent-wake")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)
    id = "sync-wake-#{System.unique_integer([:positive])}"
    issue = %Issue{id: id, identifier: id}
    entry = %{identifier: id, issue: issue, pid: self(), session_execution: %{backend: "codex"}, control: %{status: :sleeping}}
    state = %State{running: %{id => entry}, queue_store: AgentQueueStore.new(), last_polled_issues: %{id => issue}}
    assert {:reply, {:ok, %{effective: :sync}}, state} = ListenerModes.set_mode(state, id, :sync, expected_version: 0, spec_status: :ok)
    %{id: id, state: state}
  end

  for status <- [:sleeping, :working], name <- ["custom.note", "unblocked"] do
    test "unaddressed agent broadcast never wakes an idle sync agent (#{status}, #{name})", %{id: id, state: state} do
      state = put_in(state.running[id].control.status, unquote(status))
      event = %{id: System.unique_integer([:positive]), topic: "ticket.sender.agent.#{unquote(name)}", payload: %{message: "ordinary broadcast"}}
      next = OperatorMessages.enqueue_event_digest_item(state, id, [event], event)
      assert [item] = AgentQueueStore.list_pending(next.queue_store, id)
      assert item.body.events == [event]
      assert item.body.urgent == false
      item_id = item.id
      assert_received {:agent_queue_updated, ^id, ^item_id, false}
      refute_received {:agent_queue_updated, ^id, _, true}
    end
  end

  # These positive cases deliberately guard existing addressed/mixed delivery
  # against future over-broad broadcast suppression.
  test "future regression guard: addressed declared-blocker agent signal wakes idle sync agent", %{id: id, state: state} do
    event = %{id: System.unique_integer([:positive]), topic: "ticket.sender.agent.unblocked", payload: %{message: "dependency ready"}}
    subscriptions = [%{topic: "ticket.sender.agent.unblocked", reason: "blocker:auto"}]
    next = OperatorMessages.enqueue_event_digest_item(state, id, [event], event, subscribed_to: subscriptions)
    assert [item] = AgentQueueStore.list_pending(next.queue_store, id)
    assert item.body.events == [event]
    assert item.body.urgent == true
    item_id = item.id
    assert_received {:agent_queue_updated, ^id, ^item_id, true}
  end

  test "future regression guard: mixed digest preserves an addressed operator event wake", %{id: id, state: state} do
    events = [%{topic: "ticket.sender.agent.custom.note"}, %{topic: "ticket.#{id}.issue.commented", author_trusted?: true}]
    next = OperatorMessages.enqueue_event_digest_item(state, id, events, %{})
    assert [item] = AgentQueueStore.list_pending(next.queue_store, id)
    item_id = item.id
    assert_received {:agent_queue_updated, ^id, ^item_id, true}
  end

  test "agent provenance suppresses a broadcast outside the legacy agent namespace", %{id: id, state: state} do
    event = %{topic: "ticket.sender.optimistic.integrated", source: %{kind: :agent_event}}
    next = OperatorMessages.enqueue_event_digest_item(state, id, [event], event)
    assert [item] = AgentQueueStore.list_pending(next.queue_store, id)
    item_id = item.id
    assert_received {:agent_queue_updated, ^id, ^item_id, false}
  end

  test "future regression guard: orchestrator provenance on an agent topic preserves its wake", %{id: id, state: state} do
    event = %{topic: "ticket.#{id}.agent.decision.resolved", digest_source: :orchestrator}
    next = OperatorMessages.enqueue_event_digest_item(state, id, [event], event)
    assert [item] = AgentQueueStore.list_pending(next.queue_store, id)
    item_id = item.id
    assert_received {:agent_queue_updated, ^id, ^item_id, true}
  end
end
