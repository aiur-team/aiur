defmodule Aiur.Codex.InterruptsTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.{ProviderTurnLedger, TurnState}
  alias Aiur.Codex.Interrupts

  describe "handle_interrupt_error/2" do
    test "preserves a pause when no-active-turn arrives before idle" do
      error = %{"code" => -32_600, "message" => "no active turn to interrupt"}

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
      error = %{"code" => -32_600, "data" => %{"message" => "no active turn"}}

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

    test "no active turn preserves a previously armed anonymous completion guard" do
      {:ok, store} = ProviderTurnLedger.start_store()
      on_exit(fn -> ProviderTurnLedger.stop_store(store) end)

      ProviderTurnLedger.complete_all(%{
        active_turn_ids: MapSet.new(["turn-old"]),
        accepted_turn_ids: MapSet.new(),
        retired_turn_ids: MapSet.new(),
        anonymous_completion_consumed?: false,
        pending_anonymous_completion?: false,
        current_turn_id: "turn-old",
        outstanding_turns: 1,
        provider_turn_store: store
      })

      state =
        %{
          active_turn_ids: MapSet.new(["turn-1"]),
          accepted_turn_ids: MapSet.new(),
          pending_anonymous_completion?: false,
          current_turn_id: "turn-1",
          outstanding_turns: 1,
          pending_operator_requests: %{},
          pending_interrupt_request_id: 456,
          interrupt_action: :operator_message,
          pause_request_id: nil,
          provider_turn_store: store
        }
        |> Map.merge(ProviderTurnLedger.guards(store))

      assert {:ok, :turn_interrupted_for_operator_message} =
               Interrupts.handle_interrupt_error(state, %{"message" => "there is no active turn to interrupt"})

      next_state =
        %{state | active_turn_ids: MapSet.new(["turn-2"]), current_turn_id: "turn-2", outstanding_turns: 1}
        |> Map.merge(ProviderTurnLedger.guards(store))

      assert {:continue, next_state} = TurnState.continue_after_turn_completion(next_state, %{})
      assert next_state.active_turn_ids == MapSet.new(["turn-2"])
      refute next_state.anonymous_completion_consumed?
    end

    test "hard-fails any other interrupt error" do
      error = %{"code" => -32_000, "message" => "transport failed"}

      assert {:error, {:turn_interrupt_failed, ^error}} =
               Interrupts.handle_interrupt_error(%{pending_interrupt_request_id: 789}, error)
    end

    test "hard-fails an unrelated -32600 response" do
      error = %{"code" => -32_600, "message" => "invalid request payload"}

      assert {:error, {:turn_interrupt_failed, ^error}} =
               Interrupts.handle_interrupt_error(%{pending_interrupt_request_id: 790}, error)
    end
  end
end
