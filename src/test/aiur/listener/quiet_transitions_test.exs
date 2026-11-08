defmodule Aiur.Listener.QuietTransitionsTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentQueueStore, Issue}
  alias Aiur.Listener.ModeStore
  alias Aiur.Orchestrator.{ListenerModes, OperatorMessages, State}
  alias Aiur.Orchestrator.OperatorMessages.Unread

  setup do
    dir = Aiur.TestSupport.tmp_root!("quiet-transitions")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)

    id = "quiet-#{System.unique_integer([:positive])}"
    entry = %{identifier: id, issue: %Issue{id: id, identifier: id}, pid: self(), session_execution: %{backend: "codex", pull_tool_installed: true}, control: %{status: :working, can_interrupt: true}}
    %{id: id, state: %State{running: %{id => entry}, queue_store: AgentQueueStore.new()}}
  end

  for previous <- [:mute, :async], current <- [:sync, :steer] do
    test "#{previous} to #{current} queues one backlog notice without reading the held body", %{id: id, state: state} do
      previous = unquote(previous)
      current = unquote(current)
      assert {:reply, {:ok, %{effective: ^previous}}, state} = switch(state, id, previous, 0)
      assert {:reply, {:ok, request}, state} = OperatorMessages.send_operator_message_call(state, id, %{kind: :text, body: "private held body", delivery_policy: :listener, origin: :http})
      cursor = ModeStore.get(id)[:last_read_sequence]
      pings = Enum.filter(AgentQueueStore.list_pending(state.queue_store, id), &(&1.event_type == :listener_ping))

      assert length(pings) == unquote(if previous == :async, do: 1, else: 0)

      assert {:reply, {:ok, %{effective: ^current}}, next} = switch(state, id, current, 1)
      pending = AgentQueueStore.list_pending(next.queue_store, id)
      assert [notice] = Enum.reject(pending, &(&1.id == request))
      assert notice.event_type == :async_backlog_notice
      assert notice.body.text == "1 earlier message is waiting; read it with aiur_read_messages"
      assert Enum.all?(pings, &(AgentQueueStore.get(next.queue_store, &1.id).status == :superseded))
      assert_unread_body(next, id, request, cursor)

      assert {:reply, {:ok, claimed}, next} = OperatorMessages.claim_next_queue_item_call(next, id)
      assert claimed.id == notice.id
      assert {:reply, :empty, ^next} = OperatorMessages.claim_next_queue_item_call(next, id)
      assert_unread_body(next, id, request, cursor)
    end
  end

  defp switch(state, id, mode, version), do: ListenerModes.set_mode(state, id, mode, expected_version: version, spec_status: :ok)

  defp assert_unread_body(state, id, request, cursor) do
    held = AgentQueueStore.get(state.queue_store, request)
    assert held.status == :pending
    assert held.delivery.consume_at == :pull
    assert held.body.text == "private held body"
    assert Unread.queue_summary(state.queue_store, id).listener.unread_count == 1
    assert ModeStore.get(id)[:last_read_sequence] == cursor
  end
end
