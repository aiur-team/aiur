defmodule Aiur.Codex.InterruptsTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.Interrupts

  describe "handle_interrupt_error/2" do
    test "treats -32600 as a successful interrupt" do
      parent = self()

      state = %{
        active_turn_ids: MapSet.new(["turn-1"]),
        outstanding_turns: 1,
        pending_operator_requests: %{
          9 => %{on_failure: fn reason -> send(parent, {:failed, reason}) end}
        },
        pending_interrupt_request_id: 123,
        interrupt_action: :pause,
        interrupt_idle_seen?: true
      }

      assert {:ok, :turn_completed} = Interrupts.handle_interrupt_error(state, %{"code" => -32_600})
      assert_receive {:failed, :parent_turn_completed}
    end

    test "treats no active turn messages as successful interrupts" do
      state = %{pending_interrupt_request_id: 456, interrupt_action: :operator_message}

      assert {:continue, %{pending_interrupt_request_id: nil, interrupt_action: nil}} =
               Interrupts.handle_interrupt_error(state, %{"message" => "there is no active turn to interrupt"})
    end

    test "hard-fails any other interrupt error" do
      error = %{"code" => -32_000, "message" => "transport failed"}

      assert {:error, {:turn_interrupt_failed, ^error}} =
               Interrupts.handle_interrupt_error(%{pending_interrupt_request_id: 789}, error)
    end
  end
end
