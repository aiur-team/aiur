defmodule Aiur.Orchestrator.ListenerModesTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.{AgentEvents, AgentPubSub, AgentQueueStore, CodingAgent, Issue, TrackerIdentity}
  alias Aiur.Listener.ModeStore
  alias Aiur.Orchestrator.{Dispatcher, ListenerModes, State}
  alias Aiur.Orchestrator.OperatorMessages.{Capabilities, DeliveryPolicy}

  setup do
    dir = Aiur.TestSupport.tmp_root!("listener-transport")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)
    id = Integer.to_string(System.unique_integer([:positive]))
    issue = %Issue{id: "issue-#{id}", identifier: id, state: "in-progress", selected_backend: "claude-repl"}
    control = %{generation: 73, version: 8, status: :paused, can_interrupt: true, safe_checkpoints: [], immediate_delivery: true, application_confirmation: :request_only}
    entry = %{identifier: id, issue: issue, control: control, session_execution: nil}
    state = %State{running: %{issue.id => entry}, queue_store: AgentQueueStore.new()}
    :ok = AgentPubSub.subscribe_listen_mode(id)
    %{state: state, id: id, issue: issue}
  end

  test "session installation proof enables async and missing proof falls back", %{state: state, id: id, issue: issue} do
    assert {:ok, _} = ModeStore.put(id, :async, 0, %{actor: :human})
    assert {:noreply, legacy} = State.handle_session_execution_info(state, issue.id, %{backend: "codex"})
    assert legacy.running[issue.id].listener_effective.effective == :sync
    assert legacy.running[issue.id].listener_effective.effective_reason == :pull_tool_unavailable
    assert {:noreply, installed} = State.handle_session_execution_info(legacy, issue.id, %{backend: "codex", pull_tool_installed: true})
    assert installed.running[issue.id].listener_effective.effective == :async
    assert installed.running[issue.id].session_execution.pull_tool_installed
    assert {:reply, {:ok, %{effective: :async}}, _} = ListenerModes.get_mode(installed, id)
  end

  test "a nil or malformed target replies invalid_target instead of crashing", %{state: state} do
    for target <- [nil, 42, %{}] do
      assert {:reply, {:error, :invalid_target}, ^state} = ListenerModes.get_mode(state, target)
      assert {:reply, {:error, :invalid_target}, ^state} = ListenerModes.set_mode(state, target, :async, expected_version: 0)
    end
  end

  test "fallback recomputes effective reason, broadcasts as system, and preserves requested record", %{state: state, id: id, issue: issue} do
    assert {:ok, record} = ModeStore.put(id, :sync, 0, %{actor: :executor})
    bytes = File.read!(ModeStore.path_for(id))
    assert {:noreply, updated} = State.handle_session_execution_info(state, issue.id, %{backend: "claude"})
    assert_received {:listen_mode_changed, ^id, %{requested: :sync, effective: :sync, effective_reason: nil, version: 1, actor: :system}}
    assert updated.running[issue.id].listener_effective.harness_source == :session
    assert updated.running[issue.id].listener_effective.actor == :system
    assert ModeStore.get(id) == record
    assert File.read!(ModeStore.path_for(id)) == bytes
  end

  test "same backend and resolved model updates do not rebroadcast", %{state: state, id: id, issue: issue} do
    {:noreply, first} = State.handle_session_execution_info(state, issue.id, %{backend: "claude"})
    assert_received {:listen_mode_changed, ^id, _}
    {:noreply, second} = State.handle_session_execution_info(first, issue.id, %{backend: "claude"})
    {:noreply, third} = State.handle_session_resolved_model(second, issue.id, "resolved-model")
    assert third.running[issue.id].session_execution.resolved_model == "resolved-model"
    refute_received {:listen_mode_changed, ^id, _}
  end

  test "unknown backend broadcasts nil harness_unknown and clears stale capabilities", %{state: state, id: id, issue: issue} do
    {:noreply, updated} = State.handle_session_execution_info(state, issue.id, %{backend: "unregistered"})
    assert_received {:listen_mode_changed, ^id, %{effective: nil, effective_reason: :harness_unknown, actor: :system}}
    assert %{effective: nil, effective_reason: :harness_unknown} = updated.running[issue.id].listener_effective
    assert %{can_interrupt: false, immediate_delivery: false, safe_checkpoints: [], application_confirmation: :unsupported} = updated.running[issue.id].control
  end

  test "fallback and promotion refresh all control flags while retaining lifecycle fields", %{state: state, id: id, issue: issue} do
    {:noreply, fallback} = State.handle_session_execution_info(state, issue.id, %{backend: "claude"})
    control = fallback.running[issue.id].control
    assert Map.take(control, [:generation, :version, :status]) == %{generation: 73, version: 8, status: :paused}
    assert control.can_interrupt == CodingAgent.can_interrupt?("claude")
    assert control.safe_checkpoints == CodingAgent.safe_checkpoints("claude")
    assert control.application_confirmation == CodingAgent.control_application_confirmation("claude")
    capabilities = Capabilities.issue_control_capabilities(fallback, id)
    assert capabilities.immediate_delivery == false
    assert capabilities.accepted_delivery_policies == [:checkpoint, :interrupt]
    assert {:ok, [delivery_policy: :checkpoint]} = DeliveryPolicy.normalize_delivery_request(:auto, nil, capabilities)

    {:noreply, promoted} = State.handle_session_execution_info(fallback, issue.id, %{backend: "claude-repl"})
    assert promoted.running[issue.id].control.immediate_delivery == true
    assert promoted.running[issue.id].control.generation == 73
    assert promoted.running[issue.id].control.version == 8
    assert promoted.running[issue.id].control.status == :paused
    assert promoted.running[issue.id].listener_effective.support.sync.status == :experimental

    anonymous = put_in(state.running[issue.id].identifier, nil)
    {:noreply, anonymous} = State.handle_session_execution_info(anonymous, issue.id, %{backend: "claude"})
    refute anonymous.running[issue.id].control.immediate_delivery
    assert anonymous.running[issue.id].control.generation == 73
    refute Map.has_key?(anonymous.running[issue.id], :listener_effective)
  end

  test "set_mode broadcasts the caller actor and updates the cached view", %{state: state, id: id, issue: issue} do
    assert {:reply, {:ok, view}, updated} = ListenerModes.set_mode(state, id, :async, expected_version: 0, actor: :executor)
    assert_received {:listen_mode_changed, ^id, %{requested: :async, effective: :sync, effective_reason: :pull_tool_unavailable, version: 1, actor: :executor}}
    assert updated.running[issue.id].listener_effective == view
    assert updated.queue_store == state.queue_store
    assert {:reply, {:error, {:mode_conflict, _}}, ^updated} = ListenerModes.set_mode(updated, id, :steer, expected_version: 0)
    refute_received {:listen_mode_changed, ^id, _}
  end

  test "dispatch initializes and broadcasts the pending view", %{id: id, issue: issue} do
    state =
      Dispatcher.do_dispatch_issue(%State{}, issue, nil, nil,
        lease_claim_fun: fn _ -> :acquired end,
        start_runner_task_fun: fn _, _, _, _, _ -> {:ok, self()} end
      )

    assert_received {:listen_mode_changed, ^id, %{effective: :sync, effective_reason: :pending_session_start, actor: :system}}
    assert state.running[issue.id].listener_effective.harness_source == :dispatch
  end

  test "listen-mode signals never reach the transcript topic", %{state: state, id: id, issue: issue} do
    parent = self()

    subscriber =
      spawn_link(fn ->
        :ok = AgentPubSub.subscribe_agent(id)
        send(parent, :subscribed)

        receive do
          :barrier ->
            {:messages, messages} = Process.info(self(), :messages)
            send(parent, {:transcript_messages, messages})
        end
      end)

    receive_barrier(:subscribed)
    assert AgentEvents.listen_mode_topic(id) == "listen_mode:" <> id
    State.handle_session_execution_info(state, issue.id, %{backend: "claude"})
    assert_received {:listen_mode_changed, ^id, _}
    send(subscriber, :barrier)
    receive_barrier({:transcript_messages, messages})
    assert messages == []
  end

  test "broadcast without registered PubSub is a no-op", %{id: id} do
    pubsub = Process.whereis(Aiur.PubSub)
    Process.unregister(Aiur.PubSub)

    try do
      assert :ok = AgentPubSub.broadcast_listen_mode(id, %{effective: nil})
      refute_received {:listen_mode_changed, ^id, _}
    after
      Process.register(pubsub, Aiur.PubSub)
    end
  end

  test "identity writes signal and cache the resolved identifier, never a stale display identifier", %{state: state, id: id, issue: issue} do
    identity = %TrackerIdentity{status: :joinable, kind: :github, owner: "org", repository: "repo", provider_id: "I_target", identifier: id, reason: nil}
    stale = Integer.to_string(String.to_integer(id) + 1)
    entry = Map.put(state.running[issue.id], :tracker_identity, identity)
    decoy = %{entry | identifier: stale, tracker_identity: %{identity | provider_id: "I_decoy", identifier: stale}}
    state = %{state | running: %{issue.id => entry, "decoy" => decoy}}
    :ok = AgentPubSub.subscribe_listen_mode(stale)
    assert {:reply, {:ok, view}, updated} = ListenerModes.set_mode(state, %{identity | identifier: stale}, :async, expected_version: 0, actor: :executor)
    assert_received {:listen_mode_changed, ^id, %{requested: :async, actor: :executor}}
    refute_received {:listen_mode_changed, ^stale, _}
    assert updated.running[issue.id].listener_effective == view
    assert updated.running["decoy"] == decoy
    assert ModeStore.get(id).requested == :async
    assert ModeStore.get(stale).version == 0
  end
end
