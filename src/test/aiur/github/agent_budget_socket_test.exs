defmodule Aiur.GitHub.AgentBudgetSocketTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.AgentBudgetSocket

  test "forwards local agent budget commands to the daemon socket" do
    socket_dir = Path.join(System.tmp_dir!(), "agent-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(socket_dir)
    path = Path.join(socket_dir, "agent-github-budget.sock")
    parent = self()

    command_fun = fn args ->
      send(parent, {:budget_command, args})
      {:ok, "granted socket-lease\n"}
    end

    name = String.to_atom("agent_budget_socket_test_#{System.unique_integer([:positive])}")
    {:ok, _server} = AgentBudgetSocket.start_link(socket_path: path, command_fun: command_fun, name: name)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(socket_dir) end)

    args = ["acquire", "--endpoint-family", "issues"]
    assert {:ok, "granted socket-lease\n"} = AgentBudgetSocket.request(path, args)
    assert_receive {:budget_command, ^args}, 100
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end
end
