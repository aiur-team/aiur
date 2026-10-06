defmodule Aiur.Claude.CodingAgentLimitTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.Rpc.StreamDiagnostics
  alias Aiur.Claude.CodingAgent

  test "turn/failed converts Claude rate-limit errors into a usage pause" do
    port = open_cat_port()
    parent = self()

    state = %{
      on_message: fn message -> send(parent, {:message, message}) end,
      pending_operator_requests: %{}
    }

    payload = %{
      "method" => "turn/failed",
      "params" => %{"error" => %{"type" => "rate_limit_error", "message" => "rate limit exceeded"}}
    }

    assert {:paused, %{kind: :usage_limit_exhausted, reason: reason}} =
             CodingAgent.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "turn/failed")

    assert reason =~ "rate_limit_error"
    assert_received {:message, %{event: :turn_failed}}
    close_port(port)
  end

  test "turn/failed falls back to the provider's stream output to spot a session limit" do
    port = open_cat_port()
    parent = self()

    state = %{
      on_message: fn message -> send(parent, {:message, message}) end,
      pending_operator_requests: %{}
    }

    StreamDiagnostics.record(port, "You have hit your session limit - resets 11:40pm")

    # The exact params from #2607: nothing in them names the cause.
    payload = %{
      "method" => "turn/failed",
      "params" => %{"error" => "Error: claude exited with code 1", "turn_id" => "u1"}
    }

    assert {:paused, %{kind: :usage_limit_exhausted, reset_hint: "11:40pm"}} =
             CodingAgent.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "turn/failed")

    close_port(port)
  end

  test "turn/failed stays a failure when the stream output is unrelated" do
    port = open_cat_port()

    state = %{on_message: fn _message -> :ok end, pending_operator_requests: %{}}

    StreamDiagnostics.record(port, "TypeError: undefined is not a function")

    payload = %{
      "method" => "turn/failed",
      "params" => %{"error" => "Error: claude exited with code 1", "turn_id" => "u1"}
    }

    assert {:error, {:turn_failed, %{"error" => "Error: claude exited with code 1"}}} =
             CodingAgent.handle_method(%{port: port}, state, payload, Jason.encode!(payload), "turn/failed")

    close_port(port)
  end

  defp open_cat_port do
    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
        :binary,
        :exit_status,
        line: 64_000
      ])

    on_exit(fn -> close_port(port) end)
    port
  end

  defp close_port(port) do
    if is_port(port) do
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end
  end
end
