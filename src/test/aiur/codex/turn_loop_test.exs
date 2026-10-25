defmodule Aiur.Codex.TurnLoopTest do
  use ExUnit.Case, async: true

  import Aiur.Codex.TurnLoopTestSupport

  alias Aiur.AppServer.{ProviderTurnLedger, TurnState}
  alias Aiur.Codex.TurnLoop

  describe "handle_method/5 terminal turn events" do
    test "turn/completed emits before completing the turn" do
      port = open_cat_port()

      payload = %{
        "method" => "turn/completed",
        "params" => %{"turn" => %{"status" => "completed"}}
      }

      assert {:ok, :turn_completed} =
               TurnLoop.handle_method(
                 %{port: port},
                 base_state(),
                 payload,
                 Jason.encode!(payload),
                 "turn/completed"
               )

      assert_received {:event, :turn_completed}
      close_port(port)
    end

    test "turn/completed retires exact provider IDs idempotently" do
      port = open_cat_port()
      state = %{base_state() | active_turn_ids: MapSet.new(["turn-1", "turn-2"]), outstanding_turns: 2}
      parent_completed = turn_completed_payload("turn-1")

      assert {:continue, state} =
               TurnLoop.handle_method(
                 %{port: port},
                 state,
                 parent_completed,
                 Jason.encode!(parent_completed),
                 "turn/completed"
               )

      assert state.active_turn_ids == MapSet.new(["turn-2"])
      assert state.outstanding_turns == 1

      assert {:continue, duplicate_state} =
               TurnLoop.handle_method(
                 %{port: port},
                 state,
                 parent_completed,
                 Jason.encode!(parent_completed),
                 "turn/completed"
               )

      assert duplicate_state.active_turn_ids == MapSet.new(["turn-2"])
      assert duplicate_state.outstanding_turns == 1

      child_completed = turn_completed_payload("turn-2")

      assert {:ok, :turn_completed} =
               TurnLoop.handle_method(
                 %{port: port},
                 duplicate_state,
                 child_completed,
                 Jason.encode!(child_completed),
                 "turn/completed"
               )

      close_port(port)
    end

    test "turn/completed with interrupted status uses interrupted routing" do
      port = open_cat_port()

      payload = %{
        "method" => "turn/completed",
        "params" => %{"turn" => %{"status" => "interrupted"}}
      }

      state = %{base_state() | interrupt_action: :operator_message}

      assert {:ok, :turn_interrupted_for_operator_message} =
               TurnLoop.handle_method(
                 %{port: port},
                 state,
                 payload,
                 Jason.encode!(payload),
                 "turn/completed"
               )

      assert_received {:event, :turn_completed}
      close_port(port)
    end

    test "turn/failed fails pending operator requests and returns the payload reason" do
      port = open_cat_port()
      test_pid = self()
      params = %{"reason" => "boom"}
      payload = %{"method" => "turn/failed", "params" => params}

      state = %{
        base_state()
        | pending_operator_requests: %{
            10 => %{
              on_success: fn _ -> :ok end,
              on_failure: fn reason -> send(test_pid, {:failed, reason}) end
            }
          }
      }

      assert {:error, {:turn_failed, ^params}} =
               TurnLoop.handle_method(
                 %{port: port},
                 state,
                 payload,
                 Jason.encode!(payload),
                 "turn/failed"
               )

      assert_received {:failed, {:turn_failed, ^params}}
      assert_received {:event, :turn_failed}
      close_port(port)
    end

    test "turn/cancelled pauses when a pause request is pending" do
      port = open_cat_port()
      params = %{"reason" => "operator pause"}
      payload = %{"method" => "turn/cancelled", "params" => params}
      control = %{request_id: 55, generation: 9}
      state = %{base_state() | pause_request_id: control, current_turn_id: "turn-1"}

      assert {:paused, %{control: ^control, turn_id: "turn-1", details: ^params}} =
               TurnLoop.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "turn/cancelled")

      assert_received {:event, :turn_cancelled}
      close_port(port)
    end

    test "turn/cancelled errors when no pause request is pending" do
      port = open_cat_port()
      params = %{"reason" => "cancelled"}
      payload = %{"method" => "turn/cancelled", "params" => params}

      assert {:error, {:turn_cancelled, ^params}} =
               TurnLoop.handle_method(
                 %{port: port},
                 base_state(),
                 payload,
                 Jason.encode!(payload),
                 "turn/cancelled"
               )

      assert_received {:event, :turn_cancelled}
      close_port(port)
    end

    test "turn/cancelled retires active and accepted IDs before the resumed turn" do
      {:ok, store} = ProviderTurnLedger.start_store()
      on_exit(fn -> ProviderTurnLedger.stop_store(store) end)
      port = open_cat_port()

      control = %{request_id: 56, generation: 9}

      state =
        store
        |> stored_turn_state("turn-old")
        |> TurnState.record_accepted_provider_turn(%{"id" => "turn-accepted", "status" => "inProgress"})
        |> Map.put(:pause_request_id, control)

      payload = %{"method" => "turn/cancelled", "params" => %{"reason" => "operator pause"}}

      assert {:paused, %{control: ^control}} =
               TurnLoop.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "turn/cancelled")

      resumed = stored_turn_state(store, "turn-new")
      resumed = TurnState.register_provider_turn(resumed, %{"id" => "turn-old", "status" => "inProgress"})
      resumed = TurnState.register_provider_turn(resumed, %{"id" => "turn-accepted", "status" => "inProgress"})

      assert resumed.active_turn_ids == MapSet.new(["turn-new"])
      assert {:ok, :turn_completed} = TurnState.continue_after_turn_completion(resumed, turn_completed_payload("turn-new"))
      close_port(port)
    end
  end

  describe "notification outcome routing" do
    test "quota exhaustion pauses before generic unretryable handling" do
      port = open_cat_port()

      payload = %{
        "method" => "error",
        "params" => %{
          "willRetry" => false,
          "codexErrorInfo" => "usageLimitExceeded",
          "message" => "You've hit your usage limit. Purchase more credits or try again at 11:43 PM."
        }
      }

      assert {:paused, %{kind: :usage_limit_exhausted, reset_hint: "11:43 PM"}} =
               TurnLoop.handle_method(
                 %{port: port},
                 base_state(),
                 payload,
                 Jason.encode!(payload),
                 "error"
               )

      close_port(port)
    end

    test "quota exhaustion retires the failed provider turn before resume" do
      {:ok, store} = ProviderTurnLedger.start_store()
      on_exit(fn -> ProviderTurnLedger.stop_store(store) end)
      port = open_cat_port()

      payload = %{
        "method" => "error",
        "params" => %{
          "willRetry" => false,
          "codexErrorInfo" => "usageLimitExceeded",
          "message" => "You've hit your usage limit."
        }
      }

      assert {:paused, %{kind: :usage_limit_exhausted}} =
               TurnLoop.handle_method(%{port: port}, stored_turn_state(store, "turn-old"), payload, Jason.encode!(payload), "error")

      resumed = stored_turn_state(store, "turn-new")
      resumed = TurnState.register_provider_turn(resumed, %{"id" => "turn-old", "status" => "inProgress"})

      assert resumed.active_turn_ids == MapSet.new(["turn-new"])
      assert {:ok, :turn_completed} = TurnState.continue_after_turn_completion(resumed, turn_completed_payload("turn-new"))
      close_port(port)
    end

    test "ordinary unretryable errors end the turn hard" do
      port = open_cat_port()

      payload = %{
        "method" => "error",
        "params" => %{"willRetry" => false, "message" => "bwrap refused"}
      }

      assert {:error, {:turn_unretryable, "error: bwrap refused"}} =
               TurnLoop.handle_method(
                 %{port: port},
                 base_state(),
                 payload,
                 Jason.encode!(payload),
                 "error"
               )

      close_port(port)
    end

    test "turn started marks the state and defers the notification checkpoint while a turn is live" do
      port = open_cat_port()

      payload = %{
        "method" => "turn/started",
        "params" => %{"turn" => %{"id" => "turn-2", "status" => "inProgress"}}
      }

      state =
        base_state(fn checkpoint ->
          send(self(), {:checkpoint, checkpoint})
          :noop
        end)

      assert {:continue, %{turn_started?: true} = next_state} =
               TurnLoop.handle_method(
                 %{port: port},
                 state,
                 payload,
                 Jason.encode!(payload),
                 "turn/started"
               )

      assert next_state.active_turn_ids == MapSet.new(["turn-1", "turn-2"])
      assert next_state.outstanding_turns == 2
      # Single-writer guard: with a turn already live, the turn/started checkpoint
      # is deferred (not delivered mid-turn), so no second turn/start can spawn.
      assert_received {:event, :notification}
      refute_received {:checkpoint, _}
      close_port(port)
    end

    test "idle status completes only after turn_started is true" do
      port = open_cat_port()

      payload = %{
        "method" => "thread/status/changed",
        "params" => %{"status" => %{"type" => "idle"}}
      }

      assert {:continue, _state} =
               TurnLoop.handle_method(
                 %{port: port},
                 base_state(),
                 payload,
                 Jason.encode!(payload),
                 payload["method"]
               )

      assert {:ok, :turn_completed} =
               TurnLoop.handle_method(
                 %{port: port},
                 %{
                   base_state()
                   | turn_started?: true,
                     active_turn_ids: MapSet.new(["turn-1", "turn-2"]),
                     outstanding_turns: 2
                 },
                 payload,
                 Jason.encode!(payload),
                 payload["method"]
               )

      close_port(port)
    end

    test "idle waits for paired interrupted completion while pause is pending" do
      port = open_cat_port()
      idle = %{"method" => "thread/status/changed", "params" => %{"status" => %{"type" => "idle"}}}

      control = %{request_id: 7, generation: 3}

      state = %{
        base_state()
        | turn_started?: true,
          pause_request_id: control,
          pending_interrupt_request_id: 42,
          interrupt_action: :pause
      }

      assert {:continue, idle_state} =
               TurnLoop.handle_method(%{port: port}, state, idle, Jason.encode!(idle), idle["method"])

      assert Map.drop(idle_state, [:interrupt_idle_seen?, :interrupt_idle_payload]) ==
               Map.drop(state, [:interrupt_idle_seen?, :interrupt_idle_payload])

      assert idle_state.interrupt_idle_seen?

      interrupted = turn_completed_payload("turn-1", "interrupted")

      assert {:paused, %{control: ^control, turn_id: "turn-1", details: ^interrupted}} =
               TurnLoop.handle_method(
                 %{port: port},
                 idle_state,
                 interrupted,
                 Jason.encode!(interrupted),
                 interrupted["method"]
               )

      close_port(port)
    end

    test "idle waits for paired interrupted completion for operator delivery" do
      port = open_cat_port()
      idle = %{"method" => "thread/status/changed", "params" => %{"status" => %{"type" => "idle"}}}

      state = %{
        base_state()
        | turn_started?: true,
          pending_interrupt_request_id: 43,
          interrupt_action: :operator_message
      }

      assert {:continue, idle_state} =
               TurnLoop.handle_method(%{port: port}, state, idle, Jason.encode!(idle), idle["method"])

      assert Map.drop(idle_state, [:interrupt_idle_seen?, :interrupt_idle_payload]) ==
               Map.drop(state, [:interrupt_idle_seen?, :interrupt_idle_payload])

      assert idle_state.interrupt_idle_seen?

      interrupted = turn_completed_payload("turn-1", "interrupted")

      assert {:ok, :turn_interrupted_for_operator_message} =
               TurnLoop.handle_method(
                 %{port: port},
                 idle_state,
                 interrupted,
                 Jason.encode!(interrupted),
                 interrupted["method"]
               )

      close_port(port)
    end

    test "retryable errors and debug notifications continue through safe checkpoints" do
      port = open_cat_port()

      assert {:continue, _state} =
               TurnLoop.handle_method(
                 %{port: port},
                 base_state(),
                 %{"method" => "error"},
                 ~s({"method":"error"}),
                 "error"
               )

      assert {:continue, _state} =
               TurnLoop.handle_method(
                 %{port: port},
                 base_state(),
                 %{"method" => "mcp/event"},
                 ~s({"method":"mcp/event"}),
                 "mcp/event"
               )

      close_port(port)
    end
  end

  describe "handle_malformed/3" do
    test "emits malformed only for JSON-like protocol lines" do
      port = open_cat_port()

      assert {:continue, _state} =
               TurnLoop.handle_malformed(base_state(), "plain text warning", port)

      refute_received {:event, :malformed}

      assert {:continue, _state} =
               TurnLoop.handle_malformed(base_state(), "  {\"method\":\"turn/completed\"", port)

      assert_received {:event, :malformed}

      assert {:continue, _state} = TurnLoop.handle_malformed(base_state(), " [not-json", port)
      assert_received {:event, :malformed}

      close_port(port)
    end
  end
end
