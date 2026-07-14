defmodule Aiur.Codex.InterruptsTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.Interrupts

  describe "handle_interrupt_error/2" do
    test "preserves a pause when no-active-turn arrives before idle" do
      error = %{"code" => -32_600}

      state = %{
        active_turn_ids: MapSet.new(["turn-1"]),
        outstanding_turns: 1,
        pending_operator_requests: %{},
        pending_interrupt_request_id: 122,
        interrupt_action: :pause,
        pause_request_id: 6,
        current_turn_id: "turn-1"
      }

      assert {:paused,
              %{
                request_id: 6,
                turn_id: "turn-1",
                details: %{"error" => ^error, "status" => "interrupted"}
              }} = Interrupts.handle_interrupt_error(state, error)
    end

    test "preserves a deferred-idle pause when the interrupt finds no active turn" do
      parent = self()
      error = %{"code" => -32_600}

      state = %{
        active_turn_ids: MapSet.new(["turn-1"]),
        outstanding_turns: 1,
        pending_operator_requests: %{
          9 => %{on_failure: fn reason -> send(parent, {:failed, reason}) end}
        },
        pending_interrupt_request_id: 123,
        interrupt_action: :pause,
        interrupt_idle_seen?: true,
        pause_request_id: 7,
        current_turn_id: "turn-1"
      }

      assert {:paused,
              %{
                request_id: 7,
                turn_id: "turn-1",
                details: %{"error" => ^error, "status" => "interrupted"}
              }} = Interrupts.handle_interrupt_error(state, error)

      assert_receive {:failed, {:turn_interrupted, %{"error" => ^error}}}
    end

    test "treats no active turn messages as a terminal operator-message boundary" do
      state = %{
        pending_interrupt_request_id: 456,
        interrupt_action: :operator_message,
        outstanding_turns: 1,
        pending_operator_requests: %{},
        pause_request_id: nil
      }

      assert {:ok, :turn_interrupted_for_operator_message} =
               Interrupts.handle_interrupt_error(state, %{"message" => "there is no active turn to interrupt"})
    end

    test "hard-fails any other interrupt error" do
      error = %{"code" => -32_000, "message" => "transport failed"}

      assert {:error, {:turn_interrupt_failed, ^error}} =
               Interrupts.handle_interrupt_error(%{pending_interrupt_request_id: 789}, error)
    end
  end
end
