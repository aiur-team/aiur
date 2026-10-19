defmodule Aiur.CodingAgent.InterruptTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.{CodingAgent, Tmux}

  test "interrupt/2 dispatches to the adapter's optional callback" do
    {:ok, tmux} = start_supervised({Tmux, transport: {:mock, self(), :infinity}})
    task = Task.async(fn -> CodingAgent.interrupt("claude-repl", %{tmux: tmux, pane_id: "%2"}) end)
    receive_barrier({:tmux_mock_out, command})
    send(tmux, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert Task.await(task) == :ok
    assert command == "send-keys -t %2 C-c"
  end

  test "interrupt/2 reports unsupported adapters and unknown backends" do
    assert CodingAgent.interrupt("codex", %{}) == {:error, :interrupt_not_supported}
    assert CodingAgent.interrupt("missing-backend", %{}) == {:error, :interrupt_not_supported}
  end

  test "interrupt/2 preserves callback errors" do
    assert CodingAgent.interrupt("claude-repl", %{}) == {:error, :invalid_session}
  end
end
