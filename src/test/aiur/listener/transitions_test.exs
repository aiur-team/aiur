defmodule Aiur.Listener.TransitionsTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentPubSub, AgentQueue, AgentQueueStore, Issue}
  alias Aiur.AgentRunner.QueueTurn
  alias Aiur.Listener.ModeStore
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.{ListenerModes, OperatorMessages, State}
  alias Aiur.Orchestrator.OperatorMessages.{HeldReads, Unread}

  setup do
    dir = Aiur.TestSupport.tmp_root!("async-transitions")
    old = Application.fetch_env(:aiur, :listener_send_routing)
    Application.put_env(:aiur, :listener_send_routing, :listener)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:aiur, :listener_send_routing, value)
        :error -> Application.delete_env(:aiur, :listener_send_routing)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    Aiur.TestSupport.put_runtime_state_dir!(dir)
    id = Integer.to_string(System.unique_integer([:positive]))
    issue = %Issue{id: id, identifier: id, selected_backend: "claude-repl"}
    state = %State{queue_store: AgentQueueStore.new(), last_polled_issues: %{id => issue}}
    :ok = AgentPubSub.subscribe_listen_mode(id)
    %{id: id, issue: issue, state: state}
  end

  test "async to sync queues one count notice and leaves three unread bodies pull-only", ctx do
    state = held(ctx, 3)
    assert {:reply, {:ok, _}, state} = switch(state, ctx.id, :sync, 1)
    notice = notice(state, ctx.id)
    assert notice.body.text == "3 earlier messages are waiting; read them with aiur_read_messages"
    assert notice.source == :system
    assert QueueTurn.queue_item_text(notice) == notice.body.text
    assert Unread.queue_summary(state.queue_store, ctx.id).listener.unread_count == 3
    assert_received {:listen_mode_changed, _, %{backlog: %{rule: :notice, count: 3}}}
    assert {:reply, {:ok, claimed}, state} = OperatorMessages.claim_next_operator_queue_item_call(state, ctx.id)
    assert claimed.id == notice.id
    assert {:reply, :empty, _} = OperatorMessages.claim_next_operator_queue_item_call(state, ctx.id)
    assert {:reply, {:ok, %{messages: messages, remaining: 0}}, state} = HeldReads.handle_call(state, ctx.id, 50)
    assert Enum.map(messages, & &1.text) == ["private 1", "private 2", "private 3"]
    assert Unread.queue_summary(state.queue_store, ctx.id).listener.unread_count == 0
  end

  test "leaving async notifies an already-running agent about the newly queued notice", ctx do
    state = held(ctx, 1)
    entry = %{identifier: ctx.id, issue: ctx.issue, session_execution: nil, pid: self(), control: %{status: :working}}
    state = %{state | running: %{ctx.id => entry}}
    assert {:reply, {:ok, _}, state} = switch(state, ctx.id, :sync, 1)
    item_id = notice(state, ctx.id).id
    assert_received {:agent_queue_updated, _, ^item_id, true}
  end

  test "same mode version retried after notice delivery never creates another notice", ctx do
    state = held(ctx, 1)
    opts = [expected_version: 1, idempotency_key: "leave", spec_status: :ok]
    assert {:reply, {:ok, view}, state} = ListenerModes.set_mode(state, ctx.id, :sync, opts)
    item = notice(state, ctx.id)
    {store, delivered} = AgentQueueStore.claim_next_deliverable(state.queue_store, ctx.id)
    assert delivered.id == item.id
    {store, _} = AgentQueueStore.mark_consumed(store, item.id)
    state = %{state | queue_store: store}
    assert {:reply, {:ok, ^view}, replay} = ListenerModes.set_mode(state, ctx.id, :sync, opts)
    assert replay.queue_store == state.queue_store
    assert Enum.count(replay.queue_store.items) == 2
  end

  test "a new ticket run can reuse mode versions without colliding with old notices", ctx do
    state = held(ctx, 1)
    {:reply, {:ok, _}, state} = switch(state, ctx.id, :sync, 1)
    old_notice = notice(state, ctx.id)
    {store, delivered} = AgentQueueStore.claim_next_deliverable(state.queue_store, ctx.id)
    assert delivered.id == old_notice.id
    {store, _} = AgentQueueStore.mark_consumed(store, old_notice.id)
    {:reply, {:ok, %{remaining: 0}}, state} = HeldReads.handle_call(%{state | queue_store: store}, ctx.id, 50)
    :ok = ModeStore.clear(ctx.id)
    state = held(%{ctx | state: state}, 2)
    assert {:reply, {:ok, _}, state} = switch(state, ctx.id, :sync, 1)
    new_notice = notice(state, ctx.id)
    assert new_notice.id != old_notice.id
    assert new_notice.body.text == "2 earlier messages are waiting; read them with aiur_read_messages"
    assert new_notice.status == :pending
  end

  test "re-entering async supersedes only undelivered backlog notices", ctx do
    state = held(ctx, 2)
    {:reply, {:ok, _}, state} = switch(state, ctx.id, :sync, 1)
    item = notice(state, ctx.id)
    {:reply, {:ok, _}, state} = switch(state, ctx.id, :async, 2)
    assert AgentQueueStore.get(state.queue_store, item.id).status == :superseded
    assert Unread.queue_summary(state.queue_store, ctx.id).listener.unread_count == 2
    assert {:reply, :empty, _} = OperatorMessages.claim_next_operator_queue_item_call(state, ctx.id)
    {:reply, {:ok, _}, state} = switch(state, ctx.id, :sync, 3)
    new_notice = notice(state, ctx.id)
    {store, _} = AgentQueueStore.claim_next_deliverable(state.queue_store, ctx.id)
    {:reply, {:ok, _}, state} = switch(%{state | queue_store: store}, ctx.id, :async, 4)
    assert AgentQueueStore.get(state.queue_store, new_notice.id).status == :delivered
  end

  test "stopped agent's queued notice is restamped and delivered under native steer on session start", ctx do
    state = held(ctx, 1)
    {:reply, {:ok, %{effective: nil}}, state} = switch(state, ctx.id, :steer, 1)
    item = notice(state, ctx.id)
    entry = %{identifier: ctx.id, issue: ctx.issue, session_execution: nil, pid: self()}
    state = %{state | running: %{ctx.id => entry}}
    assert {:noreply, state} = State.handle_session_execution_info(state, ctx.id, %{backend: "claude-repl", pull_tool_installed: true})
    assert_received {:agent_queue_updated, _, _, true}
    assert {:reply, {:ok, claimed}, _} = OperatorMessages.claim_next_steer_queue_item_call(state, ctx.id)
    assert claimed.id == item.id
    assert claimed.delivery.steer_requested
    assert Unread.queue_summary(state.queue_store, ctx.id).listener.unread_count == 1
  end

  test "sync notice waits for the current turn and becomes claimable at turn end", ctx do
    state = held(ctx, 1)
    :ok = ActiveTurns.put(ctx.id, "active")
    on_exit(fn -> ActiveTurns.mark_closed(ctx.id, "active", :test_cleanup) end)
    {:reply, {:ok, _}, state} = switch(state, ctx.id, :sync, 1)
    assert {:reply, :empty, ^state} = OperatorMessages.claim_next_operator_queue_item_call(state, ctx.id)
    assert {:reply, :empty, ^state} = OperatorMessages.claim_next_checkpoint_queue_item_call(state, ctx.id)
    ActiveTurns.mark_closed(ctx.id, "active", :completed)
    assert {:reply, {:ok, %{category: :system_notice}}, _} = OperatorMessages.claim_next_operator_queue_item_call(state, ctx.id)
  end

  test "future regression: zero unread and non-async transitions have no backlog extension", ctx do
    {:ok, _} = ModeStore.put(ctx.id, :async, 0, %{actor: :human})
    {:reply, {:ok, _}, state} = switch(ctx.state, ctx.id, :sync, 1)
    assert state.queue_store == ctx.state.queue_store
    assert_received {:listen_mode_changed, _, payload}
    refute Map.has_key?(payload, :backlog)
    {:reply, {:ok, _}, state} = switch(state, ctx.id, :steer, 2)
    assert state.queue_store == ctx.state.queue_store
    assert_received {:listen_mode_changed, _, payload}
    refute Map.has_key?(payload, :backlog)
  end

  test "future regression: stale CAS and failed writes leave the backlog unchanged", ctx do
    state = held(ctx, 1)
    assert {:reply, {:error, {:mode_conflict, _}}, ^state} = switch(state, ctx.id, :sync, 0)
    path = ModeStore.path_for(ctx.id)
    File.chmod!(Path.dirname(path), 0o500)

    try do
      assert {:reply, {:error, {:write_failed, _}}, ^state} = switch(state, ctx.id, :sync, 1)
      assert ModeStore.get(ctx.id).requested == :async
    after
      File.chmod!(Path.dirname(path), 0o700)
    end
  end

  test "future regression: legacy routing leaves backlog rule inactive", ctx do
    state = held(ctx, 1)
    Application.put_env(:aiur, :listener_send_routing, :legacy)
    {:reply, {:ok, _}, state} = switch(state, ctx.id, :sync, 1)
    refute Enum.any?(Map.values(state.queue_store.items), &(&1.category == :system_notice))
    assert_received {:listen_mode_changed, _, payload}
    refute Map.has_key?(payload, :backlog)
  end

  defp held(ctx, n) do
    {:ok, _} = ModeStore.put(ctx.id, :async, 0, %{actor: :human})

    store =
      Enum.reduce(1..n, ctx.state.queue_store, fn i, store ->
        {store, _} = AgentQueueStore.enqueue(store, AgentQueue.operator_message(ctx.id, "private #{i}", listener_mode: :async))
        store
      end)

    %{ctx.state | queue_store: store}
  end

  defp switch(state, id, mode, version), do: ListenerModes.set_mode(state, id, mode, expected_version: version, spec_status: :ok)
  defp notice(state, id), do: Enum.find(AgentQueueStore.list_pending(state.queue_store, id), &(&1.category == :system_notice))
end
