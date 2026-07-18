defmodule Aiur.AppServer.OperatorDeliveryTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.CheckpointDelivery
  alias Aiur.AppServer.OperatorDelivery

  defmodule StubBackend do
    def send_operator_message(session, message) do
      send(session.parent, {:operator_message, message})
      session.send_operator_result
    end

    def metadata_from_message(_port, _payload), do: %{backend: :stub}
  end

  # Serves a single checkpoint item to the real safe-checkpoint handler and
  # forwards the restore/mark-failed settlement calls back to the test process,
  # so the closed-port delivery outcome can be asserted through the actual
  # driver path without standing up the full orchestrator.
  defmodule CheckpointOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts),
      do: {:ok, %{report: Keyword.fetch!(opts, :report), checkpoint: Keyword.fetch!(opts, :checkpoint)}}

    @impl true
    def handle_call({:claim_blocker_critical_events_digest, _id}, _from, state),
      do: {:reply, :empty, state}

    def handle_call({:claim_next_checkpoint_queue_item, _id}, _from, state),
      do: {:reply, state.checkpoint, state}

    def handle_call({:restore_queue_item_pending, item_id}, _from, state) do
      send(state.report, {:restore, item_id})
      {:reply, :ok, state}
    end

    def handle_call({:mark_queue_item_failed, item_id, reason}, _from, state) do
      send(state.report, {:mark_failed, item_id, reason})
      {:reply, :ok, state}
    end
  end

  test "noop checkpoint leaves state unchanged" do
    state = state(%{on_safe_checkpoint: fn _ -> :noop end})
    assert OperatorDelivery.maybe_process_safe_checkpoint(session(), state, %{kind: :notification}) == state
  end

  test "deliver_text sends operator message and registers pending request" do
    state =
      state(%{
        on_safe_checkpoint: fn _ ->
          {:deliver_text, "hello", fn _ -> :ok end, fn _ -> :ok end}
        end
      })

    next_state = OperatorDelivery.maybe_process_safe_checkpoint(session(), state, %{kind: :notification})

    assert_receive {:operator_message, %{kind: :text, body: "hello"}}
    assert Map.has_key?(next_state.pending_operator_requests, 99)
  end

  test "send failure invokes failure callback" do
    parent = self()

    state =
      state(%{
        on_safe_checkpoint: fn _ ->
          {:deliver_text, "hello", fn _ -> :ok end, fn reason -> send(parent, {:failed, reason}) end}
        end
      })

    session = session(%{send_operator_result: {:error, :port_closed}})

    assert OperatorDelivery.maybe_process_safe_checkpoint(session, state, %{kind: :notification}) == state
    assert_receive {:failed, :port_closed}
  end

  # #1238: driving the real checkpoint handler through the delivery driver, a
  # closed Codex app-server port during the mid-turn `turn/start` write must
  # restore the claimed item (so a replacement session redelivers it), not fail
  # it. Marking it failed stranded the instruction because the later target-wide
  # sweep only restores `:delivered` items.
  test "a real closed-port checkpoint write restores the codex item for a replacement" do
    item = %{category: :operator_message, id: 77, body: %{text: "survive closed checkpoint"}}
    {:ok, orch} = CheckpointOrchestrator.start_link(report: self(), checkpoint: {:ok, item})
    issue = %Aiur.Issue{identifier: "OD-#{System.unique_integer([:positive])}", id: "gid-od"}

    state = state(%{on_safe_checkpoint: CheckpointDelivery.safe_checkpoint_handler(issue, orch, "codex")})
    session = session(%{send_operator_result: {:error, :port_closed}})

    assert OperatorDelivery.maybe_process_safe_checkpoint(session, state, %{kind: :notification}) == state
    assert_receive {:operator_message, %{kind: :text, body: "survive closed checkpoint"}}
    assert_receive {:restore, 77}
    refute_receive {:mark_failed, 77, _reason}, 100
  end

  test "a real closed-port checkpoint write still fails a Claude item" do
    item = %{category: :operator_message, id: 78, body: %{text: "do not replay"}}
    {:ok, orch} = CheckpointOrchestrator.start_link(report: self(), checkpoint: {:ok, item})
    issue = %Aiur.Issue{identifier: "OD-#{System.unique_integer([:positive])}", id: "gid-od"}

    state = state(%{on_safe_checkpoint: CheckpointDelivery.safe_checkpoint_handler(issue, orch, "claude")})
    session = session(%{send_operator_result: {:error, :port_closed}})

    assert OperatorDelivery.maybe_process_safe_checkpoint(session, state, %{kind: :notification}) == state
    assert_receive {:mark_failed, 78, :port_closed}
    refute_receive {:restore, 78}, 100
  end

  test "unclaimed response emits other_message" do
    parent = self()
    state = state(%{on_message: fn message -> send(parent, {:message, message}) end})

    assert {:continue, ^state} =
             OperatorDelivery.handle_pending_operator_response(session(), state, %{"id" => 123}, "{}", 123)

    assert_receive {:message, %{event: :other_message, backend: :stub}}
  end

  test "claimed turn-started response invokes success without marking accepted work active" do
    parent = self()

    pending = %{
      99 => %{
        on_success: fn payload -> send(parent, {:success, payload.turn_id}) end,
        on_failure: fn _ -> :ok end
      }
    }

    state =
      state(%{
        pending_operator_requests: pending,
        on_message: fn message -> send(parent, {:message, message}) end
      })

    payload = %{"result" => %{"turn" => %{"id" => "turn-2"}}}

    assert {:continue, next_state} =
             OperatorDelivery.handle_pending_operator_response(session(), state, payload, "{}", 99)

    assert next_state.outstanding_turns == 1
    assert next_state.active_turn_ids == MapSet.new(["turn-1"])
    assert next_state.accepted_turn_ids == MapSet.new(["turn-2"])
    assert next_state.pending_operator_requests == %{}
    assert_receive {:success, "turn-2"}
    assert_receive {:message, %{event: :operator_turn_started}}
  end

  test "claimed Codex responses track unique accepted provider turns" do
    pending = %{
      98 => %{on_success: fn _ -> :ok end, on_failure: fn _ -> :ok end},
      99 => %{on_success: fn _ -> :ok end, on_failure: fn _ -> :ok end}
    }

    state =
      state(%{
        active_turn_ids: MapSet.new(["turn-1"]),
        pending_operator_requests: pending
      })

    payload = %{"result" => %{"turn" => %{"id" => "turn-2", "status" => "inProgress"}}}

    assert {:continue, state} =
             OperatorDelivery.handle_pending_operator_response(session(), state, payload, "{}", 98)

    assert {:continue, state} =
             OperatorDelivery.handle_pending_operator_response(session(), state, payload, "{}", 99)

    assert state.active_turn_ids == MapSet.new(["turn-1"])
    assert state.accepted_turn_ids == MapSet.new(["turn-2"])
    assert state.outstanding_turns == 1
  end

  test "claimed legacy backend response preserves counter-based turn accounting" do
    pending = %{
      99 => %{on_success: fn _ -> :ok end, on_failure: fn _ -> :ok end}
    }

    state =
      state(%{pending_operator_requests: pending})
      |> Map.drop([:active_turn_ids, :accepted_turn_ids, :retired_turn_ids])

    payload = %{"result" => %{"turn" => %{"id" => "turn-2", "status" => "inProgress"}}}

    assert {:continue, state} =
             OperatorDelivery.handle_pending_operator_response(session(), state, payload, "{}", 99)

    assert state.outstanding_turns == 2
  end

  test "claimed terminal Codex response does not create active work" do
    pending = %{
      99 => %{on_success: fn _ -> :ok end, on_failure: fn _ -> :ok end}
    }

    state =
      state(%{
        active_turn_ids: MapSet.new(["turn-1"]),
        pending_operator_requests: pending
      })

    payload = %{"result" => %{"turn" => %{"id" => "turn-2", "status" => "completed"}}}

    assert {:continue, state} =
             OperatorDelivery.handle_pending_operator_response(session(), state, payload, "{}", 99)

    assert state.active_turn_ids == MapSet.new(["turn-1"])
    assert state.accepted_turn_ids == MapSet.new()
    assert state.retired_turn_ids == MapSet.new(["turn-2"])
    assert state.outstanding_turns == 1
  end

  test "claimed terminal Codex response retires matching active work and finishes" do
    pending = %{
      99 => %{on_success: fn _ -> :ok end, on_failure: fn _ -> :ok end}
    }

    state = state(%{pending_operator_requests: pending})
    payload = %{"result" => %{"turn" => %{"id" => "turn-1", "status" => "completed"}}}

    assert {:ok, :turn_completed} =
             OperatorDelivery.handle_pending_operator_response(session(), state, payload, "{}", 99)
  end

  test "claimed response for a retired provider turn invokes failure instead of success" do
    parent = self()

    pending = %{
      99 => %{
        on_success: fn _ -> send(parent, :succeeded) end,
        on_failure: fn reason -> send(parent, {:failed, reason}) end
      }
    }

    state =
      state(%{
        pending_operator_requests: pending,
        retired_turn_ids: MapSet.new(["turn-retired"])
      })

    payload = %{"result" => %{"turn" => %{"id" => "turn-retired", "status" => "inProgress"}}}

    assert {:continue, state} =
             OperatorDelivery.handle_pending_operator_response(session(), state, payload, "{}", 99)

    assert state.pending_operator_requests == %{}
    assert state.active_turn_ids == MapSet.new(["turn-1"])
    assert state.accepted_turn_ids == MapSet.new()
    assert_receive {:failed, {:provider_turn_retired, "turn-retired"}}
    refute_receive :succeeded
  end

  defp session(overrides \\ %{}) do
    Map.merge(%{port: self(), parent: self(), send_operator_result: {:ok, 99}}, overrides)
  end

  defp state(overrides) do
    Map.merge(
      %{
        backend: StubBackend,
        on_message: fn _ -> :ok end,
        on_safe_checkpoint: fn _ -> :noop end,
        pending_operator_requests: %{},
        outstanding_turns: 1,
        active_turn_ids: MapSet.new(["turn-1"]),
        accepted_turn_ids: MapSet.new(),
        retired_turn_ids: MapSet.new()
      },
      overrides
    )
  end
end
