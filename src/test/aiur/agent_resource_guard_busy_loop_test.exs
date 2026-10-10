defmodule Aiur.AgentResourceGuardBusyLoopTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentResourceGuard
  alias Aiur.AgentResourceGuard.BusyLoop

  defp sample(pid, overrides), do: Map.merge(%{pid: pid, start: "1", state: "R", cpu: 0, minflt: 10, io: 5}, Map.new(overrides))

  describe "BusyLoop.advance/4" do
    test "flags a process only after it has spun for the whole window" do
      {busy, tracked} = BusyLoop.advance(%{}, [sample(7, cpu: 10)], 0, 1_000)
      assert MapSet.size(busy) == 0

      {busy, tracked} = BusyLoop.advance(tracked, [sample(7, cpu: 20)], 500, 1_000)
      assert MapSet.size(busy) == 0

      {busy, _tracked} = BusyLoop.advance(tracked, [sample(7, cpu: 30)], 1_000, 1_000)
      assert MapSet.to_list(busy) == [7]
    end

    test "a starved spin still counts: no share-of-a-core threshold" do
      {_busy, tracked} = BusyLoop.advance(%{}, [sample(7, cpu: 10)], 0, 1_000)
      {busy, _tracked} = BusyLoop.advance(tracked, [sample(7, cpu: 11)], 1_000, 1_000)
      assert MapSet.to_list(busy) == [7]
    end

    test "I/O, a page fault, sleeping, or idling each reset the spin" do
      for working <- [[io: 6], [minflt: 11], [state: "S"], [cpu: 10]] do
        {_busy, tracked} = BusyLoop.advance(%{}, [sample(7, cpu: 10)], 0, 1_000)
        {busy, tracked} = BusyLoop.advance(tracked, [sample(7, [cpu: 20] ++ working)], 1_000, 1_000)
        assert MapSet.size(busy) == 0, "#{inspect(working)} must not read as a busy loop"

        # The window restarts from the working sample, not from the first one.
        {busy, _tracked} = BusyLoop.advance(tracked, [sample(7, [cpu: 30] ++ working)], 1_500, 1_000)
        assert MapSet.size(busy) == 0
      end
    end

    test "a recycled pid does not inherit the previous process's history" do
      {_busy, tracked} = BusyLoop.advance(%{}, [sample(7, cpu: 10)], 0, 1_000)
      {busy, _tracked} = BusyLoop.advance(tracked, [sample(7, cpu: 20, start: "2")], 1_000, 1_000)
      assert MapSet.size(busy) == 0
    end
  end

  test "enforce counts busy descendants toward the cap and reaps busy orphans outright" do
    test_pid = self()
    cpu = :counters.new(1, [])

    opts = [
      cap: 1,
      busy_window_ms: 1_000,
      entries_fun: fn -> [{{:os_pid, 100}, :agent, %{}}] end,
      children_fun: fn
        100 -> [201, 202, 203]
        _ -> []
      end,
      orphans_fun: fn -> [%{pid: 301, cwd: "/ws/aiur/7/src"}, %{pid: 302, cwd: "/ws/aiur/7/src"}] end,
      # 203 and 302 do I/O, so they are ordinary workers rather than spinners.
      sample_fun: fn pid -> sample(pid, cpu: :counters.get(cpu, 1), io: if(pid in [203, 302], do: :counters.get(cpu, 1), else: 5)) end,
      process_info_fun: fn pid -> %{pid: pid, comm: "sh", cmdline: "sh -c while :; do :; done"} end,
      cwd_fun: fn 100 -> "/ws/aiur/42" end,
      alert_fun: fn _topic, alert -> send(test_pid, {:alert, alert[:message]}) end,
      kill_fun: fn pid -> send(test_pid, {:killed, pid}) end
    ]

    :counters.add(cpu, 1, 1)
    assert {[], tracked} = AgentResourceGuard.enforce([now_ms: 0] ++ opts, %{})
    :counters.add(cpu, 1, 1)
    assert {results, _tracked} = AgentResourceGuard.enforce([now_ms: 1_000] ++ opts, tracked)

    assert results == [
             %{root_pid: 100, cap: 1, killed: [202], workspace: "/ws/aiur/42"},
             %{root_pid: nil, cap: 0, killed: [301], workspace: "/ws/aiur/7/src"}
           ]

    assert_receive {:killed, 202}, 1000
    assert_receive {:killed, 301}, 1000
    refute_receive {:killed, _other}, 50
    assert_receive {:alert, "Agent workspace /ws/aiur/42 exceeded the synthetic load cap of 1; killed 1 " <> _}, 1000
    assert_receive {:alert, "Agent workspace /ws/aiur/7/src left orphaned synthetic load running; killed 1 " <> _}, 1000
  end

  @tag :tmp_dir
  test "a busy loop backgrounded by an agent command is counted while it runs and reaped once the command ends", %{tmp_dir: tmp_dir} do
    # Stand-in for an agent root whose tool command backgrounds two real busy
    # loops and returns when told to; the root itself stays alive, like an agent.
    # The command gets its own session, as agent tool commands do, so the test
    # holds whichever process adopts the orphan (init, or a build-gate holder).
    script = Path.join(tmp_dir, "agent.sh")
    workspace = Path.join(tmp_dir, "42")
    File.mkdir_p!(workspace)

    File.write!(script, """
    cd "$1"
    setsid -w sh -c 'sh -c "while :; do :; done" "$0" & sh -c "while :; do :; done" "$0" & echo started; read -r _' "$1"
    echo command-ended
    read -r _
    """)

    port = Port.open({:spawn_executable, System.find_executable("sh")}, [:binary, :exit_status, args: [script, workspace]])
    {:os_pid, root} = Port.info(port, :os_pid)
    # Every fixture process carries tmp_dir in its command line.
    on_exit(fn -> System.cmd("pkill", ["-KILL", "-f", tmp_dir]) end)
    assert_receive {^port, {:data, "started\n"}}, 5_000

    opts = [
      cap: 1,
      busy_window_ms: 300,
      entries_fun: fn -> [{{:os_pid, root}, :agent, %{}}] end,
      orphans_fun: fn -> AgentResourceGuard.workspace_orphans(tmp_dir) end,
      alert_fun: fn _topic, _alert -> :ok end
    ]

    # Two loops against a cap of one: both are counted, so exactly one is trimmed.
    assert {[%{root_pid: ^root, cap: 1, killed: [trimmed]}], tracked} = enforce_until_result(opts, %{})
    {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(workspace)
    assert {[], tracked} = AgentResourceGuard.enforce(opts, tracked)

    # End the command: the remaining loop reparents out of the agent's tree.
    Port.command(port, "\n")
    assert_receive {^port, {:data, "command-ended\n"}}, 5_000
    assert {[%{root_pid: nil, killed: [orphan], workspace: ^canonical_workspace}], _tracked} = enforce_until_result(opts, tracked)
    refute orphan == trimmed
    # Dead or an unreaped zombie; either way it no longer burns CPU.
    assert Enum.any?(1..50, fn _ -> BusyLoop.sample(orphan) == nil or Process.sleep(100) != :ok end)
  end

  defp enforce_until_result(opts, tracked, attempts \\ 100) do
    case AgentResourceGuard.enforce(opts, tracked) do
      {[], tracked} when attempts > 0 ->
        Process.sleep(100)
        enforce_until_result(opts, tracked, attempts - 1)

      result ->
        result
    end
  end
end
