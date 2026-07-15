defmodule Aiur.Codex.ApprovalsTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Codex.Approvals

  @metadata %{backend: "codex"}

  describe "maybe_handle_approval_request/8 — item/commandExecution/requestApproval" do
    test "auto-approves with acceptForSession when auto_approve_requests is true" do
      port = open_cat_port()

      try do
        payload = %{"id" => "r1", "method" => "item/commandExecution/requestApproval"}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/commandExecution/requestApproval",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert frame["result"]["decision"] == "acceptForSession"
      after
        Port.close(port)
      end
    end

    test "returns approval_required when auto_approve_requests is false" do
      payload = %{"id" => "r1", "method" => "item/commandExecution/requestApproval"}

      assert :approval_required =
               Approvals.maybe_handle_approval_request(
                 :no_port,
                 "item/commandExecution/requestApproval",
                 payload,
                 Jason.encode!(payload),
                 fn _msg -> :ok end,
                 @metadata,
                 fn _tool, _args -> %{} end,
                 false
               )
    end
  end

  describe "maybe_handle_approval_request/8 — item/fileChange/requestApproval" do
    test "auto-approves with acceptForSession decision string" do
      port = open_cat_port()

      try do
        payload = %{"id" => "r2", "method" => "item/fileChange/requestApproval"}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/fileChange/requestApproval",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert frame["result"]["decision"] == "acceptForSession"
      after
        Port.close(port)
      end
    end
  end

  describe "maybe_handle_approval_request/8 — execCommandApproval (legacy)" do
    test "auto-approves with approved_for_session decision string" do
      port = open_cat_port()

      try do
        payload = %{"id" => "r3", "method" => "execCommandApproval"}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "execCommandApproval",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert frame["result"]["decision"] == "approved_for_session"
      after
        Port.close(port)
      end
    end
  end

  describe "maybe_handle_approval_request/8 — applyPatchApproval (legacy)" do
    test "auto-approves with approved_for_session decision string" do
      port = open_cat_port()

      try do
        payload = %{"id" => "r4", "method" => "applyPatchApproval"}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "applyPatchApproval",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert frame["result"]["decision"] == "approved_for_session"
      after
        Port.close(port)
      end
    end
  end

  describe "maybe_handle_approval_request/8 — item/tool/call" do
    test "executes tool and returns approved on success" do
      port = open_cat_port()

      try do
        params = %{"tool" => "my_tool", "arguments" => %{"key" => "val"}}
        payload = %{"id" => "t1", "method" => "item/tool/call", "params" => params}
        tool_executor = fn tool, args -> %{"success" => true, "output" => "#{tool}(#{inspect(args)})"} end
        on_message = fn msg -> send(self(), {:event, msg}) end

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/tool/call",
                   payload,
                   Jason.encode!(payload),
                   on_message,
                   @metadata,
                   tool_executor,
                   false
                 )

        frame = read_one_frame(port)
        assert frame["result"]["success"] == true
        assert_received {:event, %{event: :tool_call_completed}}
      after
        Port.close(port)
      end
    end

    test "returns unsupported_tool_call event when tool name cannot be extracted" do
      port = open_cat_port()

      try do
        params = %{}
        payload = %{"id" => "t2", "method" => "item/tool/call", "params" => params}
        on_message = fn msg -> send(self(), {:event, msg}) end

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/tool/call",
                   payload,
                   Jason.encode!(payload),
                   on_message,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   false
                 )

        assert_received {:event, %{event: :unsupported_tool_call}}
      after
        Port.close(port)
      end
    end

    test "threads the stable protocol callId into tool execution" do
      port = open_cat_port()
      test_pid = self()

      try do
        params = %{"tool" => "my_tool", "callId" => "call-stable", "arguments" => %{}}
        payload = %{"id" => 101, "method" => "item/tool/call", "params" => params}

        tool_executor = fn _tool, _args ->
          send(test_pid, {:invocation_id, ToolExecutor.invocation_id()})
          %{"success" => true}
        end

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/tool/call",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   tool_executor,
                   false
                 )

        assert_receive {:invocation_id, "call-stable"}
      after
        Port.close(port)
      end
    end

    test "replays a completed tool result without duplicating its mutation after a closed port" do
      retired_port = open_cat_port()
      Port.close(retired_port)
      replacement_port = open_cat_port()
      ledger = start_supervised!({Aiur.AppServer.ToolCallLedger, name: nil})
      scope = {:closed_port_replay, System.unique_integer([:positive])}
      {:ok, executions} = Agent.start_link(fn -> 0 end)

      params = %{
        "tool" => "emit_event",
        "callId" => "call-closed-port",
        "threadId" => "thread-closed-port",
        "turnId" => "turn-closed-port",
        "arguments" => %{"name" => "progress.checkin"}
      }

      payload = %{"id" => 102, "method" => "item/tool/call", "params" => params}

      tool_executor = fn _tool, _args ->
        Agent.update(executions, &(&1 + 1))
        %{"success" => true, "output" => "event published"}
      end

      try do
        assert {:error, :port_closed} =
                 Approvals.maybe_handle_approval_request(
                   retired_port,
                   "item/tool/call",
                   payload,
                   Jason.encode!(payload),
                   fn _message -> :ok end,
                   @metadata,
                   tool_executor,
                   false,
                   %{tool_call_scope: scope, tool_call_ledger: ledger, response_id: 102},
                   false
                 )

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   replacement_port,
                   "item/tool/call",
                   payload,
                   Jason.encode!(payload),
                   fn _message -> :ok end,
                   @metadata,
                   tool_executor,
                   false,
                   %{tool_call_scope: scope, tool_call_ledger: ledger, response_id: 102},
                   false
                 )

        assert read_one_frame(replacement_port) == %{
                 "id" => 102,
                 "result" => %{"success" => true, "output" => "event published"}
               }

        assert Agent.get(executions, & &1) == 1
      after
        Port.close(replacement_port)
      end
    end

    test "same call ID in different provider threads executes independently" do
      port = open_cat_port()
      ledger = start_supervised!({Aiur.AppServer.ToolCallLedger, name: nil})
      scope = {:cross_thread, System.unique_integer([:positive])}
      {:ok, executions} = Agent.start_link(fn -> 0 end)

      tool_executor = fn _tool, arguments ->
        Agent.update(executions, &(&1 + 1))
        %{"success" => true, "output" => arguments["value"]}
      end

      try do
        Enum.each([{"thread-a", "first", 201}, {"thread-b", "second", 202}], fn {thread_id, value, id} ->
          params = %{
            "tool" => "emit_event",
            "callId" => "call-shared",
            "threadId" => thread_id,
            "arguments" => %{"value" => value}
          }

          payload = %{"id" => id, "method" => "item/tool/call", "params" => params}

          assert :approved =
                   Approvals.maybe_handle_approval_request(
                     port,
                     "item/tool/call",
                     payload,
                     Jason.encode!(payload),
                     fn _message -> :ok end,
                     @metadata,
                     tool_executor,
                     false,
                     %{tool_call_scope: scope, tool_call_ledger: ledger, response_id: id},
                     false
                   )

          assert read_one_frame(port)["result"]["output"] == value
        end)

        assert Agent.get(executions, & &1) == 2
      after
        Port.close(port)
      end
    end

    test "same thread and call ID with conflicting payload fails closed" do
      port = open_cat_port()
      ledger = start_supervised!({Aiur.AppServer.ToolCallLedger, name: nil})
      scope = {:conflicting_payload, System.unique_integer([:positive])}
      {:ok, executions} = Agent.start_link(fn -> 0 end)

      tool_executor = fn _tool, _arguments ->
        Agent.update(executions, &(&1 + 1))
        %{"success" => true, "output" => "mutated"}
      end

      try do
        first_params = %{
          "tool" => "emit_event",
          "callId" => "call-conflict",
          "threadId" => "thread-one",
          "turnId" => "turn-one",
          "arguments" => %{"value" => 1}
        }

        first_payload = %{"id" => 203, "method" => "item/tool/call", "params" => first_params}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/tool/call",
                   first_payload,
                   Jason.encode!(first_payload),
                   fn _message -> :ok end,
                   @metadata,
                   tool_executor,
                   false,
                   %{tool_call_scope: scope, tool_call_ledger: ledger, response_id: 203},
                   false
                 )

        assert read_one_frame(port)["result"]["success"]

        conflicting_params = put_in(first_params, ["arguments", "value"], 2)
        conflicting_payload = %{"id" => 204, "method" => "item/tool/call", "params" => conflicting_params}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/tool/call",
                   conflicting_payload,
                   Jason.encode!(conflicting_payload),
                   fn _message -> :ok end,
                   @metadata,
                   tool_executor,
                   false,
                   %{tool_call_scope: scope, tool_call_ledger: ledger, response_id: 204},
                   false
                 )

        result = read_one_frame(port)["result"]
        refute result["success"]
        assert result["output"] =~ "conflicting"
        assert Agent.get(executions, & &1) == 1
      after
        Port.close(port)
      end
    end
  end

  describe "pause containment" do
    test "declines a command approval after pause is latched" do
      port = open_cat_port()

      try do
        payload = %{"id" => "p1", "method" => "item/commandExecution/requestApproval"}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/commandExecution/requestApproval",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> flunk("pause must block execution") end,
                   true,
                   true
                 )

        assert read_one_frame(port)["result"]["decision"] == "declined"
      after
        Port.close(port)
      end
    end

    test "does not invoke a dynamic tool after pause is latched" do
      port = open_cat_port()

      try do
        payload = %{"id" => "p2", "method" => "item/tool/call", "params" => %{"tool" => "dangerous", "arguments" => %{}}}

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/tool/call",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> flunk("pause must block the dynamic tool executor") end,
                   false,
                   true
                 )

        assert read_one_frame(port)["result"]["success"] == false
      after
        Port.close(port)
      end
    end

    test "passes an id-less notification through even while pause is latched" do
      port = open_cat_port()

      try do
        payload = %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "hi"}}

        assert :unhandled =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/agentMessage/delta",
                   payload,
                   Jason.encode!(payload),
                   fn _msg -> :ok end,
                   @metadata,
                   fn _tool, _args -> flunk("a notification must not invoke the executor") end,
                   false,
                   true
                 )
      after
        Port.close(port)
      end
    end
  end

  describe "maybe_handle_approval_request/8 — item/tool/requestUserInput" do
    test "auto-answers with approval option when auto_approve is true and options available" do
      port = open_cat_port()

      try do
        params = %{
          "questions" => [
            %{
              "id" => "q1",
              "options" => [%{"label" => "Approve this Session"}, %{"label" => "Reject"}]
            }
          ]
        }

        payload = %{"id" => "u1", "method" => "item/tool/requestUserInput", "params" => params}
        on_message = fn msg -> send(self(), {:event, msg}) end

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/tool/requestUserInput",
                   payload,
                   Jason.encode!(payload),
                   on_message,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert frame["result"]["answers"]["q1"]["answers"] == ["Approve this Session"]
        assert_received {:event, %{event: :approval_auto_approved}}
      after
        Port.close(port)
      end
    end

    test "replies with non-interactive answer when no approval options available" do
      port = open_cat_port()

      try do
        params = %{
          "questions" => [
            %{"id" => "q1"}
          ]
        }

        payload = %{"id" => "u2", "method" => "item/tool/requestUserInput", "params" => params}
        on_message = fn msg -> send(self(), {:event, msg}) end

        assert :approved =
                 Approvals.maybe_handle_approval_request(
                   port,
                   "item/tool/requestUserInput",
                   payload,
                   Jason.encode!(payload),
                   on_message,
                   @metadata,
                   fn _tool, _args -> %{} end,
                   true
                 )

        frame = read_one_frame(port)
        assert is_map(frame["result"]["answers"]["q1"])
        assert_received {:event, %{event: :tool_input_auto_answered}}
      after
        Port.close(port)
      end
    end

    test "returns input_required when non-interactive answer cannot be constructed" do
      payload = %{"id" => "u3", "method" => "item/tool/requestUserInput", "params" => %{}}

      assert :input_required =
               Approvals.maybe_handle_approval_request(
                 :no_port,
                 "item/tool/requestUserInput",
                 payload,
                 Jason.encode!(payload),
                 fn _msg -> :ok end,
                 @metadata,
                 fn _tool, _args -> %{} end,
                 false
               )
    end
  end

  describe "maybe_handle_approval_request/8 — unhandled methods" do
    test "returns unhandled for unknown methods" do
      assert :unhandled =
               Approvals.maybe_handle_approval_request(
                 :no_port,
                 "some/unknown/method",
                 %{},
                 "{}",
                 fn _msg -> :ok end,
                 @metadata,
                 fn _tool, _args -> %{} end,
                 true
               )
    end
  end

  defp open_cat_port do
    Port.open(
      {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
      [:binary, :exit_status, {:line, 64_000}]
    )
  end

  defp read_one_frame(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
    after
      500 -> flunk("no frame received")
    end
  end
end
