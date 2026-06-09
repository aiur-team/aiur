defmodule Aiur.Codex.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.CodingAgent

  describe "stop_session/1 reaps the app-server process tree" do
    # The codex backend launches `bash -lc "codex ... app-server"`. bash forks
    # a `node` -> rust `codex` grandchild it does NOT exec into. Closing only
    # the port kills the bash wrapper and leaves that grandchild reparented to
    # init — a live app-server still holding the global ~/.codex/state_5.sqlite
    # lock, which poisons every subsequent codex agent with "database is locked".
    # Teardown must reap the whole tree.
    test "kills the bash wrapper AND its surviving child" do
      command = "sleep 600 & printf 'up\\n'; wait"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", String.to_charlist(command)], line: 64_000]
        )

      {:os_pid, bash_pid} = :erlang.port_info(port, :os_pid)
      assert_receive {^port, {:data, {:eol, "up"}}}, 2_000

      child_pid = wait_for_child(bash_pid, 2_000)

      on_exit(fn ->
        for p <- [bash_pid, child_pid], is_integer(p) do
          System.cmd("kill", ["-KILL", Integer.to_string(p)], stderr_to_stdout: true)
        end
      end)

      assert is_integer(child_pid)
      assert os_alive?(child_pid)

      assert :ok = CodingAgent.stop_session(%{port: port})

      refute os_alive?(bash_pid)
      refute os_alive?(child_pid)
    end
  end

  defp wait_for_child(parent, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_wait_for_child(parent, deadline)
  end

  defp do_wait_for_child(parent, deadline) do
    first_child =
      case System.cmd("pgrep", ["-P", Integer.to_string(parent)], stderr_to_stdout: true) do
        {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1) |> List.first()
        _ -> nil
      end

    cond do
      is_integer(first_child) ->
        first_child

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(25)
        do_wait_for_child(parent, deadline)
    end
  end

  defp os_alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
end
