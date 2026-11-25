defmodule Aiur.Listener.MessageDeliveryModeTest do
  # A host app's chat sends one message at a time and wants each delivered mid-turn
  # when the worker can take it. Every ticket defaults to `sync`, so without a
  # per-message mode a creator's verdict waited for the turn to end (#8065).
  use ExUnit.Case, async: false

  alias Aiur.{AgentQueueStore, Issue}
  alias Aiur.Listener.Effective
  alias Aiur.Orchestrator.{OperatorMessages, State}

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
    dir = Aiur.TestSupport.tmp_root!("message-delivery-mode")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)
    %{id: "mode-#{System.unique_integer([:positive])}"}
  end

  test "a message asking for steer is steered on a worker that can steer, while the ticket stays sync", %{id: id} do
    state = running(id, "codex")

    assert {:reply, {:ok, steered}, state} = OperatorMessages.send_operator_message_call(state, id, payload("now please", :steer))
    assert {:reply, {:ok, plain}, state} = OperatorMessages.send_operator_message_call(state, id, payload("whenever", nil))

    assert %{listener_mode_at_claim: :steer, steer_requested: true} = AgentQueueStore.get(state.queue_store, steered).delivery
    assert AgentQueueStore.get(state.queue_store, plain).delivery.listener_mode_at_claim == :sync
  end

  test "steer falls back to the next turn on a worker that cannot steer", %{id: id} do
    state = running(id, "claude")

    assert {:reply, {:ok, item}, state} = OperatorMessages.send_operator_message_call(state, id, payload("now please", :steer))
    delivery = AgentQueueStore.get(state.queue_store, item).delivery
    assert delivery.listener_mode_at_claim == :sync
    refute Map.get(delivery, :steer_requested, false)
  end

  describe "for_message/2" do
    test "steer applies only where the harness can steer; a muted ticket stays muted" do
      steer = %{status: :experimental, carrier: :native, reason: nil}
      none = %{status: :unsupported, carrier: nil, reason: :no_interrupt}
      sync = %{status: :proven, carrier: nil, reason: nil}
      view = fn effective, steer_support -> %{effective: effective, support: %{steer: steer_support, sync: sync, async: none}} end

      assert Effective.for_message(view.(:sync, steer), :steer).effective == :steer
      assert Effective.for_message(view.(:sync, none), :steer).effective == :sync
      assert Effective.for_message(view.(:steer, steer), :sync).effective == :sync
      assert Effective.for_message(view.(:mute, steer), :steer).effective == :mute
      assert Effective.for_message(view.(:sync, steer), nil).effective == :sync
    end
  end

  defp running(id, backend) do
    entry = %{identifier: id, issue: %Issue{id: id, identifier: id}, pid: self(), session_execution: %{backend: backend}, control: %{status: :working, can_interrupt: true}}
    %State{running: %{id => entry}, queue_store: AgentQueueStore.new()}
  end

  defp payload(text, delivery) do
    base = %{kind: :text, body: text, delivery_policy: :listener, origin: :http}
    if delivery, do: Map.put(base, :delivery_mode, delivery), else: base
  end
end
