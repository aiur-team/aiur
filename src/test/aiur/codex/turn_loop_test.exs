defmodule Aiur.Codex.TurnLoopTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.{CodingAgent, TurnLoop}

  describe "handle_method/5 terminal turn events" do
    test "turn/completed emits before completing the turn" do
      port = open_cat_port()
      payload = %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}}

      assert {:ok, :turn_completed} =
               TurnLoop.handle_method(%{port: port}, base_state(), payload, Jason.encode!(payload), "turn/completed")

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
      payload = %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "interrupted"}}}
      state = %{base_state() | interrupt_action: :operator_message}

      assert {:ok, :turn_interrupted_for_operator_message} =
               TurnLoop.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "turn/completed")

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
            10 => %{on_success: fn _ -> :ok end, on_failure: fn reason -> send(test_pid, {:failed, reason}) end}
          }
      }

      assert {:error, {:turn_failed, ^params}} =
               TurnLoop.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "turn/failed")

      assert_received {:failed, {:turn_failed, ^params}}
      assert_received {:event, :turn_failed}
      close_port(port)
    end

    test "turn/cancelled pauses when a pause request is pending" do
      port = open_cat_port()
      params = %{"reason" => "operator pause"}
      payload = %{"method" => "turn/cancelled", "params" => params}
      state = %{base_state() | pause_request_id: 55, current_turn_id: "turn-1"}

      assert {:paused, %{request_id: 55, turn_id: "turn-1", details: ^params}} =
               TurnLoop.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "turn/cancelled")

      assert_received {:event, :turn_cancelled}
      close_port(port)
    end

    test "turn/cancelled errors when no pause request is pending" do
      port = open_cat_port()
      params = %{"reason" => "cancelled"}
      payload = %{"method" => "turn/cancelled", "params" => params}

      assert {:error, {:turn_cancelled, ^params}} =
               TurnLoop.handle_method(%{port: port}, base_state(), payload, Jason.encode!(payload), "turn/cancelled")

      assert_received {:event, :turn_cancelled}
      close_port(port)
    end
  end

  describe "handle_method/5 generic method routing" do
    test "auto-approved tool calls send the tool result and continue" do
      port = open_cat_port()
      payload = %{"method" => "item/tool/call", "id" => 77, "params" => %{"tool" => "aiur.echo", "arguments" => %{}}}
      state = %{base_state() | tool_executor: fn "aiur.echo", %{} -> %{"success" => true, "output" => "ok"} end}

      assert {:continue, _state} =
               TurnLoop.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "item/tool/call")

      frame = read_one_frame(port)
      assert frame == %{"id" => 77, "result" => %{"success" => true, "output" => "ok"}}
      assert_received {:event, :tool_call_completed}
      close_port(port)
    end

    @tag :tmp_dir
    test "auto-approved tool calls spill oversized results into the session workspace", %{tmp_dir: tmp_dir} do
      {_output, 0} = System.cmd("git", ["init", "-q"], cd: tmp_dir)
      port = open_cat_port()
      output = String.duplicate("x", 100 * 1024 + 1)
      payload = %{"method" => "item/tool/call", "id" => 78, "params" => %{"tool" => "aiur.echo", "arguments" => %{}}}
      state = %{base_state() | tool_executor: fn "aiur.echo", %{} -> %{"success" => true, "output" => output} end}

      assert {:continue, _state} =
               TurnLoop.handle_method(%{port: port, workspace: tmp_dir}, state, payload, Jason.encode!(payload), "item/tool/call")

      frame = read_one_frame(port)
      assert get_in(frame, ["result", "success"])
      assert [path] = Regex.run(~r/saved as JSON to (.+)\. Read the file/, get_in(frame, ["result", "output"]), capture: :all_but_first)
      assert Jason.decode!(File.read!(path))["output"] == output
      close_port(port)
    end

    test "ordinary event metadata does not expose the workspace" do
      port = open_cat_port()
      payload = %{"method" => "session/configured", "params" => %{}}
      test_pid = self()
      state = %{base_state() | on_message: fn message -> send(test_pid, {:full_event, message}) end}

      assert {:continue, _state} =
               TurnLoop.handle_method(%{port: port, workspace: "/secret/workspace"}, state, payload, Jason.encode!(payload), payload["method"])

      assert_received {:full_event, message}
      refute Map.has_key?(message, :workspace)
      refute Map.has_key?(message, "workspace")
      close_port(port)
    end

    test "approval-required requests return an approval error" do
      port = open_cat_port()
      payload = %{"method" => "item/commandExecution/requestApproval", "id" => 88, "params" => %{}}

      assert {:error, {:approval_required, ^payload}} =
               TurnLoop.handle_method(%{port: port}, base_state(), payload, Jason.encode!(payload), payload["method"])

      assert_received {:event, :approval_required}
      close_port(port)
    end

    test "input-required requests return an input error" do
      port = open_cat_port()
      payload = %{"method" => "turn/input_required", "params" => %{"requiresInput" => true}}

      assert {:error, {:turn_input_required, ^payload}} =
               TurnLoop.handle_method(%{port: port}, base_state(), payload, Jason.encode!(payload), payload["method"])

      assert_received {:event, :turn_input_required}
      close_port(port)
    end

    test "unhandled notifications emit notification and continue" do
      port = open_cat_port()
      payload = %{"method" => "session/configured", "params" => %{}}

      assert {:continue, _state} =
               TurnLoop.handle_method(%{port: port}, base_state(), payload, Jason.encode!(payload), payload["method"])

      assert_received {:event, :notification}
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
               TurnLoop.handle_method(%{port: port}, base_state(), payload, Jason.encode!(payload), "error")

      close_port(port)
    end

    test "ordinary unretryable errors end the turn hard" do
      port = open_cat_port()
      payload = %{"method" => "error", "params" => %{"willRetry" => false, "message" => "bwrap refused"}}

      assert {:error, {:turn_unretryable, "error: bwrap refused"}} =
               TurnLoop.handle_method(%{port: port}, base_state(), payload, Jason.encode!(payload), "error")

      close_port(port)
    end

    test "turn started marks the state and processes a notification checkpoint" do
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
               TurnLoop.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "turn/started")

      assert next_state.active_turn_ids == MapSet.new(["turn-1", "turn-2"])
      assert next_state.outstanding_turns == 2
      assert_received {:checkpoint, %{kind: :notification, method: "turn/started"}}
      close_port(port)
    end

    test "idle status completes only after turn_started is true" do
      port = open_cat_port()
      payload = %{"method" => "thread/status/changed", "params" => %{"status" => %{"type" => "idle"}}}

      assert {:continue, _state} =
               TurnLoop.handle_method(%{port: port}, base_state(), payload, Jason.encode!(payload), payload["method"])

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

      state = %{
        base_state()
        | turn_started?: true,
          pause_request_id: 7,
          pending_interrupt_request_id: 42,
          interrupt_action: :pause
      }

      assert {:continue, ^state} =
               TurnLoop.handle_method(%{port: port}, state, idle, Jason.encode!(idle), idle["method"])

      interrupted = turn_completed_payload("turn-1", "interrupted")

      assert {:paused, %{request_id: 7, turn_id: "turn-1", details: ^interrupted}} =
               TurnLoop.handle_method(
                 %{port: port},
                 state,
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

      assert {:continue, ^state} =
               TurnLoop.handle_method(%{port: port}, state, idle, Jason.encode!(idle), idle["method"])

      interrupted = turn_completed_payload("turn-1", "interrupted")

      assert {:ok, :turn_interrupted_for_operator_message} =
               TurnLoop.handle_method(
                 %{port: port},
                 state,
                 interrupted,
                 Jason.encode!(interrupted),
                 interrupted["method"]
               )

      close_port(port)
    end

    test "retryable errors and debug notifications continue through safe checkpoints" do
      port = open_cat_port()

      assert {:continue, _state} =
               TurnLoop.handle_method(%{port: port}, base_state(), %{"method" => "error"}, ~s({"method":"error"}), "error")

      assert {:continue, _state} =
               TurnLoop.handle_method(%{port: port}, base_state(), %{"method" => "mcp/event"}, ~s({"method":"mcp/event"}), "mcp/event")

      close_port(port)
    end
  end

  describe "handle_malformed/3" do
    test "emits malformed only for JSON-like protocol lines" do
      port = open_cat_port()

      assert {:continue, _state} = TurnLoop.handle_malformed(base_state(), "plain text warning", port)
      refute_received {:event, :malformed}

      assert {:continue, _state} = TurnLoop.handle_malformed(base_state(), "  {\"method\":\"turn/completed\"", port)
      assert_received {:event, :malformed}

      assert {:continue, _state} = TurnLoop.handle_malformed(base_state(), " [not-json", port)
      assert_received {:event, :malformed}

      close_port(port)
    end
  end

  defp base_state(on_safe_checkpoint \\ fn _checkpoint -> :noop end) do
    test_pid = self()

    %{
      on_message: fn message -> send(test_pid, {:event, message.event}) end,
      on_safe_checkpoint: on_safe_checkpoint,
      tool_executor: fn _tool, _arguments -> %{"success" => true} end,
      auto_approve_requests: false,
      pending_operator_requests: %{},
      outstanding_turns: 1,
      pending_interrupt_request_id: nil,
      interrupt_action: nil,
      pause_request_id: nil,
      current_turn_id: "turn-1",
      turn_started?: false,
      active_turn_ids: MapSet.new(["turn-1"]),
      backend: CodingAgent
    }
  end

  defp turn_completed_payload(turn_id, status \\ "completed") do
    %{
      "method" => "turn/completed",
      "params" => %{"turn" => %{"id" => turn_id, "status" => status}}
    }
  end

  defp open_cat_port do
    Port.open(
      {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
      [:binary, :exit_status, {:line, 64_000}]
    )
  end

  defp read_one_frame(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Jason.decode!(line)

      {^port, {:data, line}} when is_binary(line) ->
        line
        |> String.trim_trailing()
        |> Jason.decode!()
    after
      1_000 -> flunk("no frame read from port within 1s")
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
