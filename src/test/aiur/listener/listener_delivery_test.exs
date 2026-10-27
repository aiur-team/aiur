defmodule Aiur.Listener.ListenerDeliveryTest do
  use ExUnit.Case, async: false
  alias Aiur.{AgentQueue, AgentQueueStore, Issue, Orchestrator, TrackerIdentity}
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.{ControlLifecycle, ListenerModes, OperatorMessages, State}
  alias Aiur.Orchestrator.OperatorMessages.{Capabilities, DeliveryPolicy, Enqueue, HeldReads}

  setup_all do
    # The optional build artifact is the external boundary; exercise the real scheduler.
    spec = Module.concat([Aiur, Listener, Spec])

    unless Code.ensure_loaded?(spec) do
      Code.compile_quoted(
        quote do
          defmodule unquote(spec) do
            @spec status() :: :ok
            def status, do: :ok
          end
        end
      )

      on_exit(fn ->
        :code.purge(spec)
        :code.delete(spec)
      end)
    end

    :ok
  end

  setup do
    dir = Aiur.TestSupport.tmp_root!("listener-delivery")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)
    previous = Application.fetch_env(:aiur, :listener_send_routing)
    Application.put_env(:aiur, :listener_send_routing, :listener)

    on_exit(fn ->
      case previous do
        {:ok, flag} -> Application.put_env(:aiur, :listener_send_routing, flag)
        :error -> Application.delete_env(:aiur, :listener_send_routing)
      end
    end)

    id = "listener-#{System.unique_integer([:positive])}"
    entry = %{identifier: id, issue: %Issue{id: id, identifier: id}, pid: self(), session_execution: %{backend: "codex"}, control: %{status: :working, can_interrupt: true}}
    %{id: id, entry: entry, state: %State{running: %{id => entry}, queue_store: AgentQueueStore.new()}}
  end

  test "sync enqueue never interrupts or claims at a tool checkpoint, then drains at turn boundary", %{id: id, state: state} do
    :ok = ActiveTurns.put(id, "active")
    on_exit(fn -> ActiveTurns.mark_closed(id, "active", :test_cleanup) end)
    assert {:reply, {:ok, request}, queued} = OperatorMessages.send_operator_message_call(state, id, %{kind: :text, body: "next turn", delivery_policy: :listener, origin: :agent_chat})
    assert_received {:agent_queue_updated, ^id, ^request, false}
    item = AgentQueueStore.get(queued.queue_store, request)
    assert item.delivery.listener_mode_at_claim == :sync
    refute item.delivery.interrupt_requested
    assert {:reply, :empty, ^queued} = OperatorMessages.claim_next_checkpoint_queue_item_call(queued, id)
    ActiveTurns.mark_closed(id, "active", :completed)
    assert {:reply, {:ok, claimed}, _} = OperatorMessages.claim_next_operator_queue_item_call(queued, id)
    assert claimed.id == request
  end

  test "listener input to a deactivated entry obeys the reactivation capacity gate", %{id: id, entry: entry, state: state} do
    parked = entry |> put_in([:control, :status], :deactivated) |> Map.put(:pid, nil)
    occupied = %{entry | identifier: "occupied", issue: %Issue{id: "occupied", identifier: "occupied"}}
    state = %{state | running: %{id => parked, "occupied" => occupied}, max_concurrent_agents: 1}

    assert {:reply, {:error, :max_concurrent_agents_reached}, ^state} =
             OperatorMessages.send_operator_message_call(state, id, %{kind: :text, body: "restart", delivery_policy: :listener, origin: :http})

    assert AgentQueueStore.list_pending(state.queue_store, id) == []
    refute_received {:agent_queue_updated, _, _, _}
  end

  test "unavailable effective mode refuses enqueue without changing the queue", %{id: id, state: state} do
    state = put_in(state.running[id].session_execution.backend, "unknown-harness")
    assert {:reply, {:error, :listener_mode_unavailable}, ^state} = OperatorMessages.send_operator_message_call(state, id, %{kind: :text, body: "hello", delivery_policy: :listener, origin: :http})
  end

  test "async never wakes any runner state, including cooperative self-pause", %{id: id, entry: entry, state: state} do
    item = AgentQueue.operator_message(id, "held", listener_mode: :async)

    for {status, reason} <- [{:working, nil}, {:sleeping, nil}, {:paused, :agent_pause_request}, {:paused, :operator}, {:working, :agent_pause_request}] do
      entry = entry |> put_in([:control, :status], status) |> Map.put(:paused_reason, reason)
      assert :ok = DeliveryPolicy.notify_running_queue_update(state, entry, Map.put(item, :id, 55))
      assert_received {:agent_queue_updated, ^id, 55, false}
    end
  end

  test "operator pause never wakes; sync and steer can wake cooperative self-pause", %{id: id, entry: entry, state: state} do
    for {mode, expected} <- [{:sync, false}, {:steer, true}, {:async, false}], reason <- [:operator, :agent_pause_request] do
      entry = entry |> put_in([:control, :status], :paused) |> Map.put(:paused_reason, reason)
      item = AgentQueue.operator_message(id, "hello", listener_mode: mode, steer_carrier: :emulated_interrupt) |> Map.put(:id, 56)
      DeliveryPolicy.notify_running_queue_update(state, entry, item)
      wake = reason == :agent_pause_request and expected
      assert_received {:agent_queue_updated, ^id, 56, ^wake}
    end
  end

  test "mode-view changes restamp pending items once, preserving claimed and legacy rows", %{id: id, state: state} do
    {store, claimed} = AgentQueueStore.enqueue(state.queue_store, AgentQueue.operator_message(id, "claimed", listener_mode: :sync))
    {store, _} = AgentQueueStore.claim_next_deliverable(store, id)
    {store, pending} = AgentQueueStore.enqueue(store, AgentQueue.operator_message(id, "pending", listener_mode: :sync))
    {store, legacy} = AgentQueueStore.enqueue(store, AgentQueue.operator_message(id, "legacy"))
    state = %{state | queue_store: store}
    view = %{effective: :steer, support: %{steer: %{carrier: :emulated_interrupt}}}
    next = ListenerModes.mode_view_changed(state, id, view)
    pending_id = pending.id
    assert_received {:agent_queue_updated, ^id, ^pending_id, true}
    assert AgentQueueStore.get(next.queue_store, pending.id).delivery.listener_mode_at_claim == :steer
    assert AgentQueueStore.get(next.queue_store, pending.id).delivery.interrupt_requested
    assert AgentQueueStore.get(next.queue_store, claimed.id).delivery == claimed.delivery
    assert AgentQueueStore.get(next.queue_store, legacy.id).delivery == legacy.delivery
    assert ListenerModes.mode_view_changed(next, id, view) == next
    refute_received {:agent_queue_updated, _, _, _}
  end

  test "session execution refresh restamps pending delivery and notifies only once", %{id: id, state: state} do
    previous = %{state.running[id] | session_execution: %{backend: "unknown-harness"}}
    {store, item} = AgentQueueStore.enqueue(state.queue_store, AgentQueue.operator_message(id, "held", listener_mode: :async))
    state = %{state | queue_store: store}
    next = ListenerModes.on_session_execution(state, id, previous)
    assert next.running[id].listener_effective.effective == :sync
    assert AgentQueueStore.get(next.queue_store, item.id).delivery.listener_mode_at_claim == :sync
    assert AgentQueueStore.get(next.queue_store, item.id).delivery.consume_at == :safe_checkpoint
    item_id = item.id
    assert_received {:agent_queue_updated, ^id, ^item_id, true}
    assert ListenerModes.on_session_execution(next, id, next.running[id]) == next
    refute_received {:agent_queue_updated, _, _, _}
  end

  test "set_mode restamps a pending row using its actual effective view", %{id: id, state: state} do
    {store, item} = AgentQueueStore.enqueue(state.queue_store, AgentQueue.operator_message(id, "held", listener_mode: :async))
    state = %{state | queue_store: store}
    assert {:reply, {:ok, %{effective: :sync}}, next} = ListenerModes.set_mode(state, id, :sync, expected_version: 0)
    assert AgentQueueStore.get(next.queue_store, item.id).delivery.consume_at == :safe_checkpoint
    assert AgentQueueStore.get(next.queue_store, item.id).delivery.listener_mode_at_claim == :sync
    item_id = item.id
    assert_received {:agent_queue_updated, ^id, ^item_id, true}
  end

  test "listener enqueue preserves an operator pause instead of auto-resuming", %{id: id, state: state} do
    state = state |> put_in([Access.key(:running), id, :control, :status], :paused) |> put_in([Access.key(:running), id, :paused_reason], :operator)
    assert {:reply, {:ok, request}, next} = OperatorMessages.send_operator_message_call(state, id, %{kind: :text, body: "wait", delivery_policy: :listener, origin: :http})
    assert next.running[id].control.status == :paused
    assert_received {:agent_queue_updated, ^id, ^request, false}
  end

  test "keyed retry returns the first item after pending mode restamp", %{id: id, state: state} do
    payload = %{kind: :text, body: "once", delivery_policy: :listener, origin: :http, message_id: "retry"}
    assert {:reply, {:ok, request}, queued} = OperatorMessages.send_operator_message_call(state, id, payload)
    queued = ListenerModes.mode_view_changed(queued, id, %{effective: :async})
    assert {:reply, {:ok, ^request}, ^queued} = OperatorMessages.send_operator_message_call(queued, id, payload)
    assert [%{id: ^request, delivery: %{listener_mode_at_claim: :async}}] = AgentQueueStore.list_pending(queued.queue_store, id)
  end

  test "regression guard: Command answers retain explicit interrupt under listener routing", %{id: id, state: state} do
    payload = %{
      kind: :text,
      body: "Proceed",
      delivery_policy: :interrupt,
      fallback: :queue_next,
      action_id: "act-answer",
      correlation: %{decision_id: "dec-answer", action_id: "act-answer", attempt_id: "try-answer"}
    }

    assert {:reply, {:ok, %{item: item}}, _next} = OperatorMessages.send_correlated_operator_message_call(state, id, payload)
    assert item.delivery.interrupt_requested
    refute Map.has_key?(item.delivery, :listener_mode_at_claim)
  end

  test "legacy regression guard: unstamped checkpoint rows still claim mid-turn", %{id: id, state: state} do
    {store, item} = AgentQueueStore.enqueue(state.queue_store, AgentQueue.operator_message(id, "legacy"))
    assert {:reply, {:ok, claimed}, _} = OperatorMessages.claim_next_checkpoint_queue_item_call(%{state | queue_store: store}, id)
    assert claimed.id == item.id
  end

  test "async listener input cannot lift a cooperative self-pause", %{id: id, state: state} do
    state = state |> put_in([Access.key(:running), id, :control, :status], :paused) |> put_in([Access.key(:running), id, :paused_reason], :agent_pause_request)
    entry = state.running[id]
    # Until the pull tool is installed, Effective cannot emit async; constrain
    # the pause decision used by enqueue before that later rollout enables it.
    refute Enqueue.listener_resumes_pause?(state, entry, %{effective: :async})
    assert Enqueue.listener_resumes_pause?(state, entry, %{effective: :sync})
  end

  test "sync listener input lifts a cooperative self-pause through the enqueue path", %{id: id, state: state} do
    state = state |> put_in([Access.key(:running), id, :control, :status], :paused) |> put_in([Access.key(:running), id, :paused_reason], :agent_pause_request)
    assert {:reply, {:ok, request}, next} = OperatorMessages.send_operator_message_call(state, id, %{kind: :text, body: "continue", delivery_policy: :listener, origin: :http})
    assert next.running[id].control.status == :working
    assert Map.get(next.running[id], :paused_reason) == nil
    assert next.running[id].resume_input_id == request
  end

  test "listener input leaves a pending operator Decision pause intact", %{id: id, state: state} do
    identity = %TrackerIdentity{status: :joinable, kind: :github, owner: "org", repository: "repo", provider_id: id, identifier: "42", reason: nil}
    attrs = %{request_id: "pause-decision", issue_id: id, tracker_identity: identity, action: :pause, generation: "listener", expected_status: :working, expected_version: 0, requester: :automatic}
    {:ok, _, lifecycle} = ControlLifecycle.request(state.control_lifecycle, attrs)
    entry = state.running[id]
    entry = %{entry | issue: %{entry.issue | tracker_identity: identity}, control: Map.merge(entry.control, %{generation: "listener", version: 0, application_confirmation: :request_only})}
    entry = Map.put(entry, :pending_pause_reason, %{request_id: "pause-decision", reason: :input_required})
    state = %{state | control_lifecycle: lifecycle, running: %{id => entry}}
    assert {:reply, {:ok, request}, next} = OperatorMessages.send_operator_message_call(state, id, %{kind: :text, body: "chat", delivery_policy: :listener, origin: :http})
    assert next.control_lifecycle == lifecycle
    refute Map.has_key?(next.running[id], :resume_input_id)
    refute_received {:resume_agent, _}
    refute_received {:resume_agent, _, _}
    assert next.running[id].pending_pause_reason.reason == :input_required
    assert_received {:agent_queue_updated, ^id, ^request, false}
  end

  test "mode-change signals for a removed issue leave the state intact" do
    state = %State{queue_store: AgentQueueStore.new()}
    assert {:noreply, ^state} = Orchestrator.handle_info({:listen_mode_changed, "removed-issue", %{}}, state)
  end

  test "mode-change signals re-read the current view instead of applying a stale payload", %{id: id, state: state} do
    {store, item} = AgentQueueStore.enqueue(state.queue_store, AgentQueue.operator_message(id, "held", listener_mode: :async))
    state = %{state | queue_store: store}
    assert {:noreply, next} = Orchestrator.handle_info({:listen_mode_changed, id, %{effective: :async}}, state)
    assert AgentQueueStore.get(next.queue_store, item.id).delivery.listener_mode_at_claim == :sync
    item_id = item.id
    assert_received {:agent_queue_updated, ^id, ^item_id, true}
  end

  test "held enqueue, retry, partial read and restamp emit current unread counts", %{id: id, state: state} do
    :ok = Aiur.AgentPubSub.subscribe_agent(id)
    state = put_in(state.running[id].session_execution, %{backend: "codex", pull_tool_installed: true})
    assert {:reply, {:ok, _}, state} = ListenerModes.set_mode(state, id, :async, expected_version: 0)
    request = %{kind: :text, body: "first", delivery_policy: :listener, origin: :http, message_id: "unread-first"}
    assert {:reply, {:ok, first}, state} = OperatorMessages.send_operator_message_call(state, id, request)
    assert_received {:transcript_event, %{role: :system, payload: %{listener: %{unread_count: 1, oldest_unread_at: oldest}}}}
    assert oldest == AgentQueueStore.get(state.queue_store, first).inserted_at
    assert {:reply, {:ok, ^first}, ^state} = OperatorMessages.send_operator_message_call(state, id, request)
    refute_received {:transcript_event, %{payload: %{listener: _}}}
    assert {:reply, {:ok, second}, state} = OperatorMessages.send_operator_message_call(state, id, %{request | body: "second", message_id: "unread-second"})
    assert_received {:transcript_event, %{payload: %{listener: %{unread_count: 2}}}}
    assert {:reply, {:ok, %{remaining: 1}}, state} = HeldReads.handle_call(state, id, 1)
    assert_received {:transcript_event, %{role: :system, payload: %{listener: %{unread_count: 1, oldest_unread_at: remaining_at}}}}
    assert remaining_at == AgentQueueStore.get(state.queue_store, second).inserted_at
    state = ListenerModes.mode_view_changed(state, id, %{effective: :sync})
    assert_received {:transcript_event, %{payload: %{listener: %{unread_count: 0, oldest_unread_at: nil}}}}
    assert ListenerModes.mode_view_changed(state, id, %{effective: :sync}) == state
    refute_received {:transcript_event, %{payload: %{listener: _}}}
  end

  test "correlated holds emit count once and failure clears it", %{id: id, state: state} do
    :ok = Aiur.AgentPubSub.subscribe_agent(id)
    state = put_in(state.running[id].session_execution, %{backend: "codex", pull_tool_installed: true})
    assert {:reply, {:ok, _}, state} = ListenerModes.set_mode(state, id, :async, expected_version: 0)
    payload = %{delivery_policy: :listener, origin: :http, action_id: "held-correlated", correlation: %{action_id: "held-correlated"}}
    assert {{:ok, %{item: item}}, state} = Enqueue.enqueue_operator_message(state, id, "held", payload, :correlated)
    assert_received {:transcript_event, %{payload: %{listener: %{unread_count: 1}}}}
    assert {{:ok, %{status: :duplicate}}, ^state} = Enqueue.enqueue_operator_message(state, id, "held", payload, :correlated)
    refute_received {:transcript_event, %{payload: %{listener: _}}}
    assert {:reply, :ok, state} = OperatorMessages.mark_queue_item_failed_call(state, item.id, :failed)
    assert_received {:transcript_event, %{payload: %{listener: %{unread_count: 0, oldest_unread_at: nil}}}}
    assert Capabilities.issue_control_capabilities(state, id).listener.unread_count == 0
  end
end
