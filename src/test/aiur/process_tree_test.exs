defmodule Aiur.ProcessTreeTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.ProcessTree

  test "future regression guard: nil has no process to kill" do
    assert ProcessTree.graceful_kill(nil) == :ok
    assert ProcessTree.graceful_kill_tree(nil) == :ok
  end

  @tag skip: Aiur.TestSupport.pgrep_skip_reason()
  test "future regression guard: tree cleanup kills the root and both background children" do
    command = "sleep 30 & first=$!; sleep 30 & second=$!; printf '%s %s\\n' \"$first\" \"$second\"; wait"
    port = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, :exit_status, args: [~c"-c", String.to_charlist(command)], line: 1_024])
    {:os_pid, root} = Port.info(port, :os_pid)
    receive_barrier({^port, {:data, {:eol, children}}})
    children = children |> String.split() |> Enum.map(&String.to_integer/1)
    pids = [root | children]

    on_exit(fn ->
      Enum.each(pids, &System.cmd("kill", ["-KILL", Integer.to_string(&1)], stderr_to_stdout: true))
    end)

    assert length(children) == 2
    assert Enum.sort(ProcessTree.process_tree(root)) == Enum.sort(pids)
    assert Enum.all?(pids, &alive?/1)
    assert ProcessTree.graceful_kill_tree(root) == :ok
    Enum.each(pids, fn pid -> refute alive?(pid), "process #{pid} survived tree cleanup" end)
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
end
