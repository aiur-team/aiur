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

  test "continue_after_turn_interrupted routes pause and operator-message actions" do
    payload = %{"method" => "turn/completed"}
    control = %{request_id: 7, generation: 3}

    assert {:paused, %{control: ^control, turn_id: "turn-1", details: ^payload}} =
             TurnState.continue_after_turn_interrupted(state(%{pause_request_id: control}), payload)

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
