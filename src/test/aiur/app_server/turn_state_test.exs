defmodule Aiur.AppServer.TurnStateTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.TurnState

  test "continue_after_turn_completion decrements outstanding turns with zero floor" do
    assert {:continue, %{outstanding_turns: 1}} =
             TurnState.continue_after_turn_completion(state(%{outstanding_turns: 2}))

    assert {:ok, :turn_completed} =
             TurnState.continue_after_turn_completion(state(%{outstanding_turns: 0}))
  end

  test "completion succeeds only at zero outstanding turns and fails pending requests" do
    parent = self()

    pending = %{
      10 => %{on_failure: fn reason -> send(parent, {:failed, reason}) end}
    }

    state = state(%{outstanding_turns: 1, pending_operator_requests: pending})

    assert {:ok, :turn_completed} = TurnState.continue_after_turn_completion(state)

    assert_receive {:failed, :parent_turn_completed}
  end

  test "provider turn tracking is unique, status-aware, and seeded with the parent" do
    state =
      state(%{active_turn_ids: MapSet.new()})
      |> TurnState.initialize_turn_tracking()

    assert state.active_turn_ids == MapSet.new(["turn-1"])
    assert state.outstanding_turns == 1

    state = TurnState.register_provider_turn(state, %{"id" => "turn-2", "status" => "inProgress"})
    state = TurnState.register_provider_turn(state, %{"id" => "turn-2", "status" => "inProgress"})
    state = TurnState.register_provider_turn(state, %{"id" => "turn-3", "status" => "completed"})

    assert state.active_turn_ids == MapSet.new(["turn-1", "turn-2"])
    assert state.outstanding_turns == 2
  end

  test "provider completions retire only the matching active turn" do
    state =
      state(%{active_turn_ids: MapSet.new(["turn-1", "turn-2"]), outstanding_turns: 2})

    parent_completed = %{"params" => %{"turn" => %{"id" => "turn-1"}}}

    assert {:continue, next_state} =
             TurnState.continue_after_turn_completion(state, parent_completed)

    assert next_state.active_turn_ids == MapSet.new(["turn-2"])
    assert next_state.outstanding_turns == 1

    assert {:continue, duplicate_state} =
             TurnState.continue_after_turn_completion(next_state, parent_completed)

    assert duplicate_state.active_turn_ids == MapSet.new(["turn-2"])
    assert duplicate_state.outstanding_turns == 1

    child_completed = %{"params" => %{"turn" => %{"id" => "turn-2"}}}
    assert {:ok, :turn_completed} = TurnState.continue_after_turn_completion(duplicate_state, child_completed)
  end

  test "provider idle completes all active turns and fails pending requests" do
    parent = self()

    pending = %{
      10 => %{on_failure: fn reason -> send(parent, {:failed, reason}) end}
    }

    state =
      state(%{
        active_turn_ids: MapSet.new(["turn-1", "turn-2"]),
        outstanding_turns: 2,
        pending_operator_requests: pending
      })

    assert {:ok, :turn_completed} = TurnState.complete_all_provider_turns(state)
    assert_receive {:failed, :parent_turn_completed}
  end

  test "continue_after_turn_interrupted routes pause and operator-message actions" do
    payload = %{"method" => "turn/completed"}

    assert {:paused, %{request_id: 7, turn_id: "turn-1", details: ^payload}} =
             TurnState.continue_after_turn_interrupted(state(%{pause_request_id: 7}), payload)

    assert {:ok, :turn_interrupted_for_operator_message} =
             TurnState.continue_after_turn_interrupted(
               state(%{interrupt_action: :operator_message}),
               payload
             )

    assert {:error, {:turn_interrupted, ^payload}} =
             TurnState.continue_after_turn_interrupted(state(), payload)
  end

  test "turn_completion_status defaults to completed" do
    assert TurnState.turn_completion_status(%{}) == "completed"
    assert TurnState.turn_completion_status(%{"turn" => %{"status" => "interrupted"}}) == "interrupted"
  end

  test "safe callbacks swallow raised exceptions" do
    assert TurnState.safe_invoke_success_callback(fn _ -> raise "boom" end, :payload) == :ok
    assert TurnState.safe_invoke_failure_callback(fn _ -> raise "boom" end, :reason) == :ok
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        outstanding_turns: 1,
        pending_operator_requests: %{},
        pause_request_id: nil,
        current_turn_id: "turn-1",
        pending_interrupt_request_id: nil,
        interrupt_action: nil
      },
      overrides
    )
  end
end
