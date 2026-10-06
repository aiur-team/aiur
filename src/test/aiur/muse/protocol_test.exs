defmodule Aiur.Muse.ProtocolTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.Protocol

  test "command IDs encode current time, UUID version 7, and RFC variant" do
    before_ms = System.system_time(:millisecond)
    id = Protocol.command_id()
    after_ms = System.system_time(:millisecond)

    assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    timestamp = id |> String.replace("-", "") |> binary_part(0, 12) |> String.to_integer(16)
    assert timestamp in before_ms..after_ms
    refute id == Protocol.command_id()
  end

  test "initialization requests session MCP and sends a parameterless initialized notification" do
    assert Protocol.initialize_frame(1, "1.2.3") == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "method" => "initialize",
             "params" => %{
               "clientInfo" => %{"name" => "aiur", "version" => "1.2.3"},
               "capabilities" => %{"requestedCapabilities" => ["sessionMcp"], "userInputDialogs" => false}
             }
           }

    assert Protocol.initialized_frame() == %{"jsonrpc" => "2.0", "method" => "initialized"}
    assert {:error, :session_mcp_not_granted} = Protocol.initialize_result(%{"schema" => %{"version" => 1}, "grantedCapabilities" => []})
    assert {:ok, _} = Protocol.initialize_result(%{"schema" => %{"version" => 1}, "grantedCapabilities" => ["sessionMcp"]})

    assert {:error, {:unsupported_schema_version, 2}} =
             Protocol.initialize_result(%{"schema" => %{"version" => 2}, "grantedCapabilities" => ["sessionMcp"]})
  end

  test "session frames preserve command identity and native session/cursor fields" do
    command_id = Protocol.command_id()

    assert %{"method" => "session/start", "params" => start} =
             Protocol.session_start_frame(2, "/work/issue", command_id: command_id, config: %{"mcpServers" => []})

    assert start == %{"commandId" => command_id, "workspaceRoot" => "/work/issue", "config" => %{"mcpServers" => []}}

    assert %{"method" => "session/resume", "params" => resume} =
             Protocol.session_resume_frame(3, "session-1", command_id: command_id, cursor: "cursor-1")

    assert resume == %{"commandId" => command_id, "sessionId" => "session-1", "cursor" => "cursor-1"}
    assert {:ok, _} = Protocol.session_result(%{"session" => %{"sessionId" => "session-1"}, "viewCursor" => "cursor-2"})
    assert {:error, :invalid_session_result} = Protocol.session_result(%{"session" => %{"id" => "session-1"}, "viewCursor" => "cursor-2"})
  end

  test "turn receipts are accepted commands, not terminal outcomes" do
    command_id = Protocol.command_id()

    assert %{"jsonrpc" => "2.0", "method" => "turn/start", "params" => start} =
             Protocol.turn_start_frame(4, "session-1", "Do the task", command_id: command_id, if_busy: "queue")

    assert start == %{
             "commandId" => command_id,
             "sessionId" => "session-1",
             "input" => [%{"type" => "text", "text" => "Do the task"}],
             "ifBusy" => "queue"
           }

    receipt = %{"commandId" => command_id, "status" => "accepted", "turnId" => "turn-1", "disposition" => "queued", "startedNewTurn" => false}
    assert {:accepted, ^receipt} = Protocol.turn_start_result(receipt, command_id)
    assert {:error, :invalid_turn_start_receipt} = Protocol.turn_start_result(receipt, "other-command")

    assert %{"method" => "turn/interrupt", "params" => interrupt} =
             Protocol.turn_interrupt_frame(5, "session-1", "turn-1", command_id: command_id)

    assert interrupt == %{"commandId" => command_id, "sessionId" => "session-1", "turnId" => "turn-1"}
    assert {:accepted, _} = Protocol.turn_interrupt_result(%{"commandId" => command_id, "status" => "accepted", "turnId" => "turn-1"}, command_id)
  end

  test "only a matching typed completion gives a turn outcome" do
    base = %{
      "method" => "turn/completed",
      "params" => %{
        "sessionId" => "session-1",
        "turnId" => "turn-1",
        "terminal" => "completed",
        "viewCursor" => "cursor-3",
        "sourceRange" => %{}
      }
    }

    assert {:terminal, :completed, _} = Protocol.turn_completed(base, "session-1", "turn-1")
    assert {:error, :invalid_turn_completion} = Protocol.turn_completed(base, "session-2", "turn-1")
    assert {:error, :invalid_turn_completion} = Protocol.turn_completed(put_in(base, ["params", "terminal"], "unknown"), "session-1", "turn-1")
    assert {:error, :missing_turn_error} = Protocol.turn_completed(put_in(base, ["params", "terminal"], "failed"), "session-1", "turn-1")

    failed = base |> put_in(["params", "terminal"], "failed") |> put_in(["params", "error"], %{"kind" => "provider", "message" => "failed", "retryable" => true})
    assert {:terminal, :failed, _} = Protocol.turn_completed(failed, "session-1", "turn-1")
    assert {:terminal, :cancelled, _} = Protocol.turn_completed(put_in(base, ["params", "terminal"], "cancelled"), "session-1", "turn-1")
  end
end
