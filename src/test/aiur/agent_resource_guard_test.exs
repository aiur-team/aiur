defmodule Aiur.AgentResourceGuardTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentResourceGuard

  test "agent_root_pids returns only local agent os pids" do
    entries = [
      {{:os_pid, 100}, :agent, %{}},
      {{:pane, "%1"}, :agent, %{}},
      {{:os_pid, 200}, :serve, %{}},
      {{:os_pid, 100}, :agent, %{}}
    ]

    assert AgentResourceGuard.agent_root_pids(entries) == [100]
  end

  test "synthetic_load_generator? recognizes known generator commands" do
    assert AgentResourceGuard.synthetic_load_generator?(%{pid: 1, comm: "yes", cmdline: "yes"})
    assert AgentResourceGuard.synthetic_load_generator?(%{pid: 2, comm: "bash", cmdline: "/usr/bin/stress --cpu 16"})
    assert AgentResourceGuard.synthetic_load_generator?(%{pid: 3, comm: "stress-ng", cmdline: "stress-ng --cpu 16"})

    refute AgentResourceGuard.synthetic_load_generator?(%{pid: 4, comm: "beam.smp", cmdline: "mix test --seed 229"})
    refute AgentResourceGuard.synthetic_load_generator?(%{pid: 5, comm: "bash", cmdline: "bash ./.repro_flake.sh"})
  end

  test "enforce_once trims excess yes descendants and preserves non-generators" do
    test_pid = self()
    yes_pids = Enum.to_list(201..216)
    mix_pid = 301

    children = fn
      100 -> yes_pids ++ [mix_pid]
      _ -> []
    end

    process_info = fn
      pid when pid in 201..216 -> %{pid: pid, comm: "yes", cmdline: "yes"}
      ^mix_pid -> %{pid: mix_pid, comm: "beam.smp", cmdline: "mix test --seed 229"}
      _ -> nil
    end

    result =
      AgentResourceGuard.enforce_once(
        cap: 3,
        kill_detected: false,
        entries_fun: fn -> [{{:os_pid, 100}, :agent, %{comm: "codex"}}] end,
        children_fun: children,
        process_info_fun: process_info,
        orphans_fun: fn -> [] end,
        sample_fun: fn _pid -> nil end,
        cwd_fun: fn 100 -> "/ws/aiur/42" end,
        alert_fun: fn topic, alert -> send(test_pid, {:alert, topic, alert}) end,
        kill_fun: fn pid -> send(test_pid, {:killed, pid}) end
      )

    expected_killed = Enum.to_list(204..216)
    assert result == [%{root_pid: 100, cap: 3, killed: expected_killed, reported: [], workspace: "/ws/aiur/42"}]

    assert_receive {:alert, "system.agent.synthetic_load_cap", alert}, 1000
    assert alert[:message] =~ "Agent workspace /ws/aiur/42 exceeded the synthetic load cap of 3; killed 13 "

    for pid <- expected_killed do
      assert_receive {:killed, ^pid}, 1000
    end

    refute_receive {:killed, 201}, 50
    refute_receive {:killed, 202}, 50
    refute_receive {:killed, 203}, 50
    refute_receive {:killed, ^mix_pid}, 50
  end

  test "enforce_once is disabled at cap zero" do
    assert [] =
             AgentResourceGuard.enforce_once(
               cap: 0,
               entries_fun: fn -> flunk("entries should not be read when disabled") end,
               orphan_holders_fun: fn -> flunk("the per-tick pass must not scan for orphan holders") end
             )
  end

  test "finds only legacy holders whose lock path is gone, wherever it lived" do
    proc_dir = Aiur.TestSupport.tmp_root!("gate-orphan-proc")
    # Deliberately not under Aiur.BuildGate.lock_dir(): real leaks lock test temp dirs.
    lock_root = Path.join(proc_dir, "locks")
    live_lock = Path.join([lock_root, "live.locks", "slot-1.lock"])
    File.mkdir_p!(Path.dirname(live_lock))
    File.touch!(live_lock)
    script = "exec 8<>\"$1\"; flock 8; while [[ ! -e $3 ]]; do sleep 0.05; done"
    test_pid = self()

    write_proc = fn pid, comm, argv ->
      File.mkdir_p!(Path.join(proc_dir, "#{pid}"))
      File.write!(Path.join([proc_dir, "#{pid}", "comm"]), comm <> "\n")
      File.write!(Path.join([proc_dir, "#{pid}", "cmdline"]), Enum.map_join(argv, &(&1 <> <<0>>)))
    end

    write_proc.(123, "bash", ["/usr/bin/bash", "-c", script, "build-gate-holder", "#{lock_root}/removed.locks/slot-1.lock"])
    write_proc.(124, "bash", ["bash", "-c", "sleep forever"])
    write_proc.(125, "bash", ["/usr/bin/bash", "-c", script, "build-gate-holder", live_lock])
    write_proc.(126, "beam.smp", ["/usr/bin/bash", "-c", script, "build-gate-holder", "#{lock_root}/removed.locks/slot-2.lock"])
    write_proc.(127, "bash", ["/run/current-system/bin/bash", "-c", script, "build-gate-holder", "/tmp/aiur-gate-gone-#{System.unique_integer([:positive])}.locks/slot-1.lock"])
    # The current test holder polls at 0.5 s and exits by itself; it is never a reap target.
    write_proc.(128, "bash", ["/usr/bin/bash", "-c", String.replace(script, "0.05", "0.5"), "build-gate-holder", "#{lock_root}/removed.locks/slot-3.lock"])

    identity_fun = fn pid ->
      send(test_pid, {:identity_read, pid})
      {:ok, {:known, pid}}
    end

    found = AgentResourceGuard.orphaned_build_gate_holders(proc_dir, identity_fun)
    assert Enum.sort(found) == [{123, {:known, 123}}, {127, {:known, 127}}]
    refute_received {:identity_read, 126}

    File.rm_rf!(proc_dir)
  end

  test "reap_orphaned_build_gate_holders reaps each discovered holder by its captured identity" do
    test_pid = self()

    assert [777] =
             AgentResourceGuard.reap_orphaned_build_gate_holders(
               orphan_holders_fun: fn -> [{777, {:known, :identity}}] end,
               orphan_kill_fun: fn pid, identity -> send(test_pid, {:killed, pid, identity}) end
             )

    assert_received {:killed, 777, {:known, :identity}}
  end

  test "the guard reaps orphan holders on the throttled orphan scan" do
    test_pid = self()

    opts = [
      cap: 1,
      entries_fun: fn -> [] end,
      orphans_fun: fn -> [] end,
      orphan_holders_fun: fn ->
        send(test_pid, :holders_scanned)
        [{777, {:known, :identity}}]
      end,
      orphan_kill_fun: fn pid, _identity -> send(test_pid, {:killed, pid}) end
    ]

    {:ok, guard} = AgentResourceGuard.start_link(name: nil, interval_ms: 60_000, enforce_opts: opts)
    on_exit(fn -> Aiur.TestSupport.safe_stop(guard) end)

    :ok = GenServer.call(guard, :tick)
    assert_receive :holders_scanned, 0
    assert_receive {:killed, 777}, 0

    :ok = GenServer.call(guard, :tick)
    refute_receive :holders_scanned, 50
    refute_receive {:killed, 777}, 50
  end

  test "collect_descendants walks recursively" do
    children = fn
      1 -> [2, 3]
      2 -> [4]
      3 -> []
      4 -> []
    end

    assert AgentResourceGuard.collect_descendants(1, children_fun: children) == [2, 3, 4]
  end

  test "scheduled enforcement runs with injected process sources" do
    test_pid = self()

    {:ok, pid} =
      AgentResourceGuard.start_link(
        name: nil,
        interval_ms: 60_000,
        enforce_opts: [
          cap: 1,
          orphans_fun: fn ->
            send(test_pid, :orphans_scanned)
            []
          end,
          entries_fun: fn ->
            send(test_pid, :guard_enforced)
            []
          end
        ]
      )

    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

    :ok = GenServer.call(pid, :tick)
    assert_receive :guard_enforced, 0
    assert Process.alive?(pid)

    # The host-wide orphan scan is throttled; enforcement still runs every tick.
    :ok = GenServer.call(pid, :tick)
    assert_receive :guard_enforced, 0
    assert_receive :orphans_scanned, 0
    refute_receive :orphans_scanned, 50
  end
end
