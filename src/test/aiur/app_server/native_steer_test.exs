defmodule Aiur.AppServer.NativeSteerTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.{AgentQueue, AgentQueueStore, Issue}
  alias Aiur.AgentRunner.{CheckpointDelivery, QueueDrain, TurnCallbacks}
  alias Aiur.AppServer.{Adapter, OperatorDelivery, TurnState}
  alias Aiur.Codex.{CodingAgent, Frames}
  alias Aiur.Orchestrator.{OperatorMessages, State}
  alias Aiur.Listener.Receipt

  defmodule QueueServer do
    use GenServer
    alias Aiur.Orchestrator.Calls
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call(message, from, state), do: Calls.handle_call(message, from, state)
  end

  defmodule LoopBackend do
    def backend_label, do: "test app-server"
    def metadata_from_message(_port, _payload), do: %{}
    def loop_state_extras(_session), do: %{}
    defdelegate steer(session, payload, turn_id), to: CodingAgent
    defdelegate send_frame(port, frame), to: CodingAgent

    def start_turn(_session, _prompt, issue) do
      send(self(), {:agent_queue_updated, issue.identifier, 1, :steer})
      {:ok, "turn-1"}
    end

    def handle_method(session, _state, payload, _raw, _method) do
      send(session.report, {:wire_frame, payload})
      {:ok, :turn_completed}
    end
  end

  setup do
    issue = %Issue{id: "native-steer", identifier: "native-steer"}
    {store, sync} = AgentQueueStore.enqueue(AgentQueueStore.new(), AgentQueue.operator_message(issue.identifier, "boundary", listener_mode: :sync))
    {store, first} = AgentQueueStore.enqueue(store, native_item(issue, "first"))
    {store, second} = AgentQueueStore.enqueue(store, native_item(issue, "second"))
    {:ok, queue} = QueueServer.start_link(%State{queue_store: store})
    port = Port.open({:spawn_executable, System.find_executable("cat") |> String.to_charlist()}, [:binary, :exit_status, {:line, 64_000}])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    parent = self()

    state = %{
      backend: CodingAgent,
      issue: issue,
      current_turn_id: "turn-1",
      outstanding_turns: 1,
      active_turn_ids: MapSet.new(["turn-1"]),
      accepted_turn_ids: MapSet.new(),
      retired_turn_ids: MapSet.new(),
      pending_operator_requests: %{},
      on_message: fn message -> send(parent, {:message, message}) end,
      on_steer_claim: TurnCallbacks.build(%{backend: "codex"}, issue, orchestrator: queue, recipient: nil, live_conversation: :disabled).on_steer_claim
    }

    %{state: state, session: %{port: port, thread_id: "thread-1"}, queue: queue, first: first, second: second, sync: sync}
  end

  test "a stale steer wake cannot claim or resume a paused runner", ctx do
    issue = %Issue{id: "native-steer", identifier: "native-steer"}
    send(self(), {:agent_queue_updated, issue.identifier, ctx.first.id, :steer})
    send(self(), :noop_park_timeout)
    assert :ok = QueueDrain.wait_for_operator_message(%{backend: "codex"}, issue, fn _ -> :ok end, ctx.queue, nil)
    assert status(ctx.queue, ctx.first.id) == :pending
  end

  test "unavailable orchestrator leaves steer input unclaimed" do
    issue = %Issue{id: "unavailable", identifier: "unavailable"}
    claim = CheckpointDelivery.steer_claim_handler(issue, :unavailable_steer_queue)
    assert claim.() == :noop
  end

  test "frame contains only steer parameters and adapter rejects a missing turn" do
    assert Frames.turn_steer_frame(%{thread_id: "t"}, 42, "hello", "active") == %{
             "id" => 42,
             "method" => "turn/steer",
             "params" => %{"threadId" => "t", "expectedTurnId" => "active", "input" => [%{"type" => "text", "text" => "hello"}]}
           }

    assert CodingAgent.steer(%{}, %{kind: :text, body: "hello"}, nil) == {:error, :no_active_turn}
  end

  test "live-turn steer bypasses writer lock, claims only native items and serializes writes", ctx do
    next = OperatorDelivery.steer_pending(ctx.session, ctx.state)
    frame = read_frame(ctx.session.port)
    assert frame["method"] == "turn/steer"
    assert frame == Frames.turn_steer_frame(ctx.session, frame["id"], "first", "turn-1")
    assert status(ctx.queue, ctx.first.id) == :delivered
    assert status(ctx.queue, ctx.sync.id) == :pending
    assert status(ctx.queue, ctx.second.id) == :pending
    assert next.outstanding_turns == 1
    assert OperatorDelivery.steer_pending(ctx.session, next) == next
    refute_received {_, {:data, _}}
  end

  test "turnId acknowledgement settles delivery without registering a turn and advances waiting steer", ctx do
    next = OperatorDelivery.steer_pending(ctx.session, ctx.state)
    frame = read_frame(ctx.session.port)
    payload = %{"result" => %{"turnId" => "turn-1"}}
    assert {:continue, accepted} = OperatorDelivery.handle_pending_operator_response(ctx.session, next, payload, "{}", frame["id"])
    delivered = AgentQueueStore.get(queue_state(ctx.queue).queue_store, ctx.first.id)
    assert %DateTime{} = delivered.provider_delivered_at
    assert delivered.provider_turn_id == "turn-1"
    assert Receipt.from_snapshot(delivered).receipt == :harness_queued
    assert accepted.outstanding_turns == 1
    assert accepted.active_turn_ids == ctx.state.active_turn_ids
    assert accepted.accepted_turn_ids == MapSet.new()
    assert_received {:message, %{event: :operator_steered, turn_id: "turn-1"}}
    second_frame = read_frame(ctx.session.port)
    assert second_frame["params"]["input"] == [%{"type" => "text", "text" => "second"}]
    assert status(ctx.queue, ctx.second.id) == :delivered
  end

  test "pause or interrupt pending prevents new steer claims including after acknowledgement", ctx do
    for key <- [:pause_request_id, :pending_interrupt_request_id] do
      stopping = Map.put(ctx.state, key, 123)
      assert OperatorDelivery.steer_pending(ctx.session, stopping) == stopping
    end

    next = OperatorDelivery.steer_pending(ctx.session, ctx.state)
    frame = read_frame(ctx.session.port)
    stopping = Map.put(next, :pending_interrupt_request_id, 123)
    assert {:continue, settled} = OperatorDelivery.handle_pending_operator_response(ctx.session, stopping, %{"result" => %{"turnId" => "turn-1"}}, "{}", frame["id"])
    assert settled.pending_operator_requests == %{}
    assert status(ctx.queue, ctx.second.id) == :pending
    refute_received {_, {:data, _}}
  end

  test "rejected or malformed responses restore the claimed item for boundary delivery", ctx do
    for response <- [%{"error" => %{"code" => -32_600, "message" => "turn mismatch"}}, %{"result" => %{}}] do
      next = OperatorDelivery.steer_pending(ctx.session, ctx.state)
      frame = read_frame(ctx.session.port)
      assert {:continue, restored} = OperatorDelivery.handle_pending_operator_response(ctx.session, next, response, "{}", frame["id"])
      assert restored.pending_operator_requests == %{}
      assert OperatorDelivery.steer_pending(ctx.session, restored) == restored
      assert status(ctx.queue, ctx.first.id) == :pending
      assert {:reply, {:ok, claimed}, boundary} = OperatorMessages.claim_next_operator_queue_item_call(queue_state(ctx.queue), "native-steer")
      assert claimed.id == ctx.sync.id
      assert {:reply, {:ok, native}, _} = OperatorMessages.claim_next_operator_queue_item_call(boundary, "native-steer")
      assert native.id == ctx.first.id
    end
  end

  test "transport failure and parent completion restore in-flight steer without interrupt", ctx do
    Port.close(ctx.session.port)
    assert OperatorDelivery.steer_pending(ctx.session, ctx.state).steer_fallback?
    assert status(ctx.queue, ctx.first.id) == :pending

    port = Port.open({:spawn_executable, System.find_executable("cat") |> String.to_charlist()}, [:binary, :exit_status, {:line, 64_000}])
    session = %{ctx.session | port: port}
    next = OperatorDelivery.steer_pending(session, ctx.state)
    assert read_frame(port)["method"] == "turn/steer"
    assert {:ok, :turn_completed} = TurnState.continue_after_turn_completion(next)
    assert status(ctx.queue, ctx.first.id) == :pending
    Port.close(port)
  end

  test "adapter wires queue wake and claim callback without interrupting", ctx do
    session = Map.merge(ctx.session, %{metadata: %{}, report: self()})
    issue = %Issue{id: "native-steer", identifier: "native-steer"}
    callbacks = TurnCallbacks.build(%{backend: "codex"}, issue, orchestrator: ctx.queue, recipient: nil, live_conversation: :disabled)
    assert {:ok, _} = Adapter.run_turn(LoopBackend, session, "work", issue, on_steer_claim: callbacks.on_steer_claim)
    assert_received {:wire_frame, frame}
    assert frame["method"] == "turn/steer"
    assert frame == Frames.turn_steer_frame(session, frame["id"], "first", "turn-1")
  end

  defp native_item(issue, text), do: AgentQueue.operator_message(issue.identifier, text, listener_mode: :steer, steer_carrier: :native)
  defp queue_state(queue), do: :sys.get_state(queue)
  defp status(queue, id), do: AgentQueueStore.get(queue_state(queue).queue_store, id).status

  defp read_frame(port) do
    receive_barrier({^port, {:data, {:eol, line}}})
    Jason.decode!(line)
  end
end
