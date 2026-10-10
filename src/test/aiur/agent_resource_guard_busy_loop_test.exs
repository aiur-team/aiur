defmodule Aiur.AgentResourceGuardBusyLoopTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentResourceGuard
  alias Aiur.AgentResourceGuard.BusyLoop

  defp sample(pid, overrides), do: Map.merge(%{pid: pid, start: "1", state: "R", cpu: 0, minflt: 10, io: 5, ctxt: 3}, Map.new(overrides))

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

    test "I/O, a page fault, blocking, sleeping, or idling each reset the spin" do
      for working <- [[io: 6], [minflt: 11], [ctxt: 4], [state: "S"], [cpu: 10]] do
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
      kill_detected: true,
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
             %{root_pid: 100, cap: 1, killed: [202], reported: [], workspace: "/ws/aiur/42"},
             %{root_pid: nil, cap: 0, killed: [301], reported: [], workspace: "/ws/aiur/7/src"}
           ]

    assert_receive {:killed, 202}, 1000
    assert_receive {:killed, 301}, 1000
    refute_receive {:killed, _other}, 50
    assert_receive {:alert, "Agent workspace /ws/aiur/42 exceeded the synthetic load cap of 1; killed 1 " <> _}, 1000
    assert_receive {:alert, "Agent workspace /ws/aiur/7/src left orphaned synthetic load running; killed 1 " <> _}, 1000
  end

  test "without the opt-in, detected busy loops and orphans are reported once and left running" do
    test_pid = self()

    opts = [
      cap: 1,
      kill_detected: false,
      busy_window_ms: 1_000,
      entries_fun: fn -> [{{:os_pid, 100}, :agent, %{}}] end,
      children_fun: fn
        100 -> [201, 202, 204]
        _ -> []
      end,
      # 204 and 302 are known generators by name: one `yes` is within the cap,
      # and an orphan is report-only whatever it is called.
      orphans_fun: fn -> [%{pid: 301, cwd: "/ws/aiur/7/src"}, %{pid: 302, cwd: "/ws/aiur/7/src"}] end,
      process_info_fun: fn
        pid when pid in [204, 302] -> %{pid: pid, comm: "yes", cmdline: "yes"}
        pid -> %{pid: pid, comm: "sh", cmdline: "sh -c spin"}
      end,
      cwd_fun: fn 100 -> "/ws/aiur/42" end,
      alert_fun: fn _topic, alert -> send(test_pid, {:alert, alert[:message]}) end,
      kill_fun: fn pid -> send(test_pid, {:killed, pid}) end
    ]

    tick = fn n, tracked ->
      spinning = fn pid -> if pid in [201, 202, 301], do: sample(pid, cpu: n) end
      AgentResourceGuard.enforce([now_ms: n * 1_000, sample_fun: spinning] ++ opts, tracked)
    end

    assert {[%{root_pid: nil, killed: [], reported: [302]}], tracked} = tick.(0, %{})
    assert {results, tracked} = tick.(1, tracked)

    assert results == [
             %{root_pid: 100, cap: 1, killed: [], reported: [202, 204], workspace: "/ws/aiur/42"},
             %{root_pid: nil, cap: 0, killed: [], reported: [301], workspace: "/ws/aiur/7/src"}
           ]

    # Still spinning, already reported: no repeat on later ticks.
    assert {[], _tracked} = tick.(2, tracked)

    assert_receive {:alert, "Agent workspace /ws/aiur/7/src left orphaned synthetic load running; killed 0 load generator process(es), left 1 running (report-only" <> _}, 1000
    assert_receive {:alert, "Agent workspace /ws/aiur/42 exceeded the synthetic load cap of 1; killed 0 load generator process(es), left 2 running (report-only" <> _}, 1000
    assert_receive {:alert, "Agent workspace /ws/aiur/7/src left orphaned" <> _}, 1000
    refute_receive {:alert, _message}, 50
    refute_receive {:killed, _pid}, 50
  end

  test "killing detected load is opt-in by config" do
    assert {:ok, %{agent: %{synthetic_load_kill_detected: false}}} = Aiur.Config.Schema.parse(%{tracker: %{kind: "memory"}})
    assert {:ok, %{agent: %{synthetic_load_kill_detected: true}}} = Aiur.Config.Schema.parse(%{tracker: %{kind: "memory"}, agent: %{synthetic_load_kill_detected: true}})
  end

  test "legitimate CPU-heavy work under a workspace is never killed, in the tree or orphaned" do
    test_pid = self()
    tick = :counters.new(1, [])

    # Each worker burns CPU on every tick but shows exactly one sign of real
    # work, so dropping any single term of the signature kills one of them.
    working = fn
      pid, n when pid in [201, 301] -> [io: n]
      pid, n when pid in [202, 302] -> [minflt: n]
      pid, n when pid in [203, 303] -> [ctxt: n]
      pid, _n when pid in [204, 304] -> [state: "S"]
      # 200 is a real spinner: it fills the cap of one, so any worker misread
      # as busy is the excess and gets trimmed.
      200, _n -> []
    end

    opts = [
      cap: 1,
      kill_detected: true,
      busy_window_ms: 1_000,
      entries_fun: fn -> [{{:os_pid, 100}, :agent, %{}}] end,
      children_fun: fn
        100 -> [200, 201, 202, 203, 204]
        _ -> []
      end,
      orphans_fun: fn -> Enum.map(301..304, &%{pid: &1, cwd: "/ws/aiur/7/src"}) end,
      sample_fun: fn pid -> sample(pid, [cpu: :counters.get(tick, 1)] ++ working.(pid, :counters.get(tick, 1))) end,
      process_info_fun: fn pid -> %{pid: pid, comm: if(rem(pid, 2) == 0, do: "mix", else: "beam.smp"), cmdline: "mix test"} end,
      cwd_fun: fn 100 -> "/ws/aiur/42" end,
      alert_fun: fn _topic, alert -> send(test_pid, {:alert, alert[:message]}) end,
      kill_fun: fn pid -> send(test_pid, {:killed, pid}) end
    ]

    tracked =
      Enum.reduce(0..3, %{}, fn n, tracked ->
        :counters.add(tick, 1, 1)
        assert {[], tracked} = AgentResourceGuard.enforce([now_ms: n * 1_000] ++ opts, tracked)
        tracked
      end)

    # The spinner was recognised, so the workers survived detection, not a blind spot.
    assert %{since: 0} = tracked[{200, "1"}]
    refute_receive {:killed, _pid}, 50
    refute_receive {:alert, _message}, 50
  end

  @tag :tmp_dir
  test "sample reads the spin signature from procfs and yields nothing without it", %{tmp_dir: proc_dir} do
    dir = Path.join(proc_dir, "7")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "stat"), "7 (a b) c) R 1 7 7 0 -1 0 11 0 0 0 40 2 0 0 20 0 1 0 9001 0 0\n")
    File.write!(Path.join(dir, "io"), "rchar: 9\nwchar: 9\nsyscr: 3\nsyscw: 4\n")
    assert BusyLoop.sample(7, proc_dir) == nil

    File.write!(Path.join(dir, "status"), "Name:\ta b) c\nvoluntary_ctxt_switches:\t12\nnonvoluntary_ctxt_switches:\t99\n")
    assert BusyLoop.sample(7, proc_dir) == %{pid: 7, state: "R", minflt: 11, cpu: 42, start: "9001", io: 7, ctxt: 12}
  end

  @tag :tmp_dir
  test "workspace_orphans selects ended-command leftovers under the root and refuses a shallow or home root", %{tmp_dir: proc_dir} do
    proc = fn pid, comm, ppid, sid, cwd ->
      dir = Path.join(proc_dir, "#{pid}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "stat"), "#{pid} (#{comm}) R #{ppid} #{pid} #{sid} 0 -1 0 0 0 0 0 0 0\n")
      File.ln_s!(cwd, Path.join(dir, "cwd"))
    end

    proc.(1, "init", 0, 1, "/")
    proc.(20, "systemd", 1, 20, "/")
    proc.(30, "zsh", 999, 30, "/nonexistent-ws/aiur/7")
    # Adopted by init, adopted by a systemd manager, and session leader gone.
    proc.(41, "sh", 1, 41, "/nonexistent-ws/aiur/7/src")
    proc.(42, "sh", 20, 42, "/nonexistent-ws/aiur/7")
    proc.(43, "sh", 30, 777, "/nonexistent-ws/aiur/8")
    # Still owned by a live command, and an orphan outside the root.
    proc.(51, "sh", 30, 30, "/nonexistent-ws/aiur/7")
    proc.(52, "sh", 1, 52, "/elsewhere/aiur/7")

    assert "/nonexistent-ws/aiur" |> AgentResourceGuard.workspace_orphans(proc_dir) |> Enum.sort_by(& &1.pid) == [
             %{pid: 41, cwd: "/nonexistent-ws/aiur/7/src"},
             %{pid: 42, cwd: "/nonexistent-ws/aiur/7"},
             %{pid: 43, cwd: "/nonexistent-ws/aiur/8"}
           ]

    assert AgentResourceGuard.workspace_orphans("/nonexistent-ws", proc_dir) == []

    # An operator app adopted by init with its cwd under $HOME: a workspace
    # root of $HOME would put it in scope, so that root is refused.
    {:ok, home} = Aiur.PathSafety.canonicalize(System.user_home!())
    proc.(61, "steam", 1, 61, Path.join(home, "games/x"))
    assert AgentResourceGuard.workspace_orphans(home, proc_dir) == []
    assert [%{pid: 61}] = AgentResourceGuard.workspace_orphans(Path.join(home, "games"), proc_dir)
  end

  @tag :tmp_dir
  test "load backgrounded by an agent command is counted while it runs and reaped once the command ends", %{tmp_dir: tmp_dir} do
    # Stand-in for an agent root whose tool command backgrounds two children and
    # returns when told to; the root itself stays alive, like an agent. The
    # children are idle `sleep`s made to look like busy loops through the sample
    # seam, so the real process tree, orphan scan and kill run with no CPU load.
    # The command gets its own session, as agent tool commands do, so the test
    # holds whichever process adopts the orphan (init, or a build-gate holder).
    script = Path.join(tmp_dir, "agent.sh")
    workspace = Path.join(tmp_dir, "42")
    File.mkdir_p!(workspace)

    File.write!(script, """
    cd "$1"
    setsid -w sh -c 'sleep 300 & a=$!; sleep 300 & echo "started $a $!"; read -r _'
    echo command-ended
    read -r _
    """)

    port = Port.open({:spawn_executable, System.find_executable("sh")}, [:binary, :exit_status, args: [script, workspace]])
    {:os_pid, root} = Port.info(port, :os_pid)
    assert_receive {^port, {:data, "started " <> started}}, 5_000
    sleeps = started |> String.split() |> Enum.map(&String.to_integer/1)
    on_exit(fn -> System.cmd("kill", ["-KILL" | Enum.map([root | sleeps], &Integer.to_string/1)], stderr_to_stdout: true) end)

    cpu = :counters.new(1, [])

    spinning = fn pid ->
      :counters.add(cpu, 1, 1)

      # A killed child lingers as a zombie under its parent; it must stop counting.
      with true <- pid in sleeps, %{state: state} = real when state != "Z" <- BusyLoop.sample(pid) do
        %{real | state: "R", cpu: :counters.get(cpu, 1)}
      else
        _ -> nil
      end
    end

    opts = [
      cap: 1,
      kill_detected: true,
      busy_window_ms: 300,
      entries_fun: fn -> [{{:os_pid, root}, :agent, %{}}] end,
      orphans_fun: fn -> AgentResourceGuard.workspace_orphans(tmp_dir) end,
      sample_fun: spinning,
      alert_fun: fn _topic, _alert -> :ok end
    ]

    # Two loops against a cap of one: both are counted, so exactly one is trimmed.
    assert {[%{root_pid: ^root, cap: 1, killed: [trimmed]}], tracked} = enforce_until_result(opts, %{})
    {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(workspace)
    assert {[], tracked} = AgentResourceGuard.enforce(opts, tracked)

    # End the command: the remaining child reparents out of the agent's tree.
    Port.command(port, "\n")
    assert_receive {^port, {:data, "command-ended\n"}}, 5_000
    assert {[%{root_pid: nil, killed: [orphan], workspace: ^canonical_workspace}], _tracked} = enforce_until_result(opts, tracked)
    assert Enum.sort([trimmed, orphan]) == Enum.sort(sleeps)
    # Dead or an unreaped zombie; either way it is no longer running.
    assert Enum.any?(1..50, fn _ -> not match?(%{state: state} when state != "Z", BusyLoop.sample(orphan)) or Process.sleep(100) != :ok end)
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
