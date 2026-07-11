defmodule Aiur.Claude.CodingAgentLimitTest do
  use ExUnit.Case, async: true

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
