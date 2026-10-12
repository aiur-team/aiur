defmodule Aiur.ProcessTreeTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Codex.AppServerPort
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

  describe "process liveness probes" do
    test "reports the running BEAM as alive" do
      # The containment loop polls process_alive? before reaping the paused root;
      # a live root must read as alive so a cooperative pause is never force-reaped.
      assert ProcessTree.process_alive?(String.to_integer(System.pid()))
    end

    test "treats a nil or non-positive pid / group as not alive" do
      # A session that never reported a real os pid (nil / 0) has nothing to probe,
      # so both liveness checks read false instead of shelling out to `kill`.
      refute ProcessTree.process_alive?(nil)
      refute ProcessTree.process_alive?(0)
      refute ProcessTree.process_group_alive?(nil)
      refute ProcessTree.process_group_alive?(0)
    end

    test "killing an absent process group short-circuits to :gone" do
      # With no group id to signal, teardown reports the group already gone instead
      # of blocking on a TERM/KILL grace wait for a group that never existed.
      assert ProcessTree.graceful_kill_process_group(nil) == {:ok, :gone}
      assert ProcessTree.graceful_kill_process_group(0) == {:ok, :gone}
    end
  end

  describe "process identity" do
    test "binds a running process to its procfs birth and session" do
      os_pid = System.pid() |> String.to_integer()

      assert {:ok, {:procfs_birth_and_session, start_time, session}} = ProcessTree.process_identity(os_pid)
      assert start_time =~ ~r/^\d+$/
      assert session =~ ~r/^\d+$/
    end

    test "treats missing process identifiers as gone" do
      assert ProcessTree.process_identity(nil) == :gone
      assert ProcessTree.process_identity(0) == :gone
    end
  end

  describe "pidfd containment reapers" do
    test "fails closed when the captured identity cannot bind a pidfd" do
      process_group_id = System.unique_integer([:positive])

      assert {:error, :identity_unverified} = ProcessTree.reap_process_group(nil, {:known, :identity})

      assert {:error, :identity_signal_unavailable} =
               ProcessTree.reap_process_group(
                 process_group_id,
                 {:known, {:ps_birth_and_session, "portable-identity"}}
               )
    end

    test "binds a group signal to the production reaper boundary" do
      parent = self()
      process_group_id = System.unique_integer([:positive])
      {:ok, identity} = Agent.start_link(fn -> :original end)

      on_exit(fn -> Aiur.TestSupport.safe_stop(identity) end)

      reaper = fn group, expected_identity, :group ->
        send(parent, {:identity_signal_barrier, self(), group, expected_identity})

        receive do
          :continue_identity_signal ->
            if Agent.get(identity, &(&1 == expected_identity)),
              do: {:ok, :reaped},
              else: {:error, :identity_changed}
        end
      end

      task = Task.async(fn -> ProcessTree.reap_process_group(process_group_id, {:known, :original}, reaper) end)
      assert_receive {:identity_signal_barrier, reaper_pid, ^process_group_id, :original}, 1000
      Agent.update(identity, fn _ -> :replacement end)
      send(reaper_pid, :continue_identity_signal)
      assert {:error, :identity_changed} = Task.await(task)
    end

    test "reaps a verified process group through pidfds" do
      port = Port.open({:spawn_executable, ~c"/bin/sleep"}, [:binary, args: [~c"600"]])
      {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
      process_group_id = AppServerPort.process_group_for_pid(os_pid)

      on_exit(fn ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end
      end)

      assert {:ok, identity} = ProcessTree.process_identity(process_group_id)
      assert {:ok, :reaped} = ProcessTree.reap_process_group(process_group_id, {:known, identity})
      refute ProcessTree.process_group_alive?(process_group_id)
    end
  end

  describe "graceful_kill/1" do
    test "blocks until the OS process has actually exited" do
      # Child handles SIGTERM after a deliberate delay (mirrors claude flushing
      # its debug-file on the way down). A correct teardown must not return —
      # and must not delete the debug-file — until that exit completes.
      command = "trap 'sleep 0.25; exit 0' TERM; printf 'up\\n'; while true; do sleep 0.05; done"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
          [:binary, :exit_status, :stderr_to_stdout, args: [~c"-lc", String.to_charlist(command)], line: 64_000]
        )

      {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
      on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true) end)

      # "up" prints only after the trap is installed — wait for it so SIGTERM
      # can't beat the trap and hit bash's default (instant) disposition.
      assert_receive {^port, {:data, {:eol, "up"}}}, 2_000

      started = System.monotonic_time(:millisecond)
      assert :ok = ProcessTree.graceful_kill(os_pid)
      elapsed = System.monotonic_time(:millisecond) - started

      # Waited out the child's ~250ms shutdown, and the process is gone on return.
      assert elapsed >= 150
      refute match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
    end
  end

  describe "graceful_kill_tree/1" do
    @tag skip: Aiur.TestSupport.pgrep_skip_reason()
    test "reaps the bash wrapper AND its surviving child (the headless orphan)" do
      # Mirror the headless backend: a `bash -lc` wrapper that forks a child
      # it does NOT exec into. Killing only the bash pid leaves that child
      # reparented to init — the exact orphan U7/#109 must prevent. The job
      # is backgrounded so the shell's SIGTERM does not propagate to it.
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

      # The child is a real, distinct descendant that single-pid graceful_kill
      # would strand — that is the whole point of the tree variant.
      assert is_integer(child_pid)
      assert child_pid != bash_pid
      assert os_alive?(child_pid)

      assert :ok = ProcessTree.graceful_kill_tree(bash_pid)

      refute os_alive?(bash_pid)
      refute os_alive?(child_pid)
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

  describe "graceful_kill_process_group/1" do
    test "reaps a child after its session leader exits" do
      # Redirect the backgrounded child's stdio so the session leader can exit
      # and `System.cmd` returns; an inherited stdout pipe would block the call
      # until the child itself exits.
      {out, 0} = System.cmd("setsid", ["sh", "-c", "sleep 600 >/dev/null 2>&1 & echo $!"], stderr_to_stdout: true)
      child_pid = out |> String.trim() |> String.to_integer()

      on_exit(fn ->
        System.cmd("kill", ["-KILL", Integer.to_string(child_pid)], stderr_to_stdout: true)
      end)

      {pgid_out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(child_pid)], stderr_to_stdout: true)
      process_group_id = pgid_out |> String.trim() |> String.to_integer()

      assert ProcessTree.process_group_alive?(process_group_id)
      assert {:ok, :reaped} = ProcessTree.graceful_kill_process_group(process_group_id)
      refute ProcessTree.process_group_alive?(process_group_id)
    end
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
end
