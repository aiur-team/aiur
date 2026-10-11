Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.ContainmentTest do
  use Aiur.TestSupport.BuildGateCase

  @tag @linux_only
  test "cancellation after direct Mix exit reaps retained descendants before releasing capacity", context do
    # The descendant must be CPU-burning (#2398) so the holder is still
    # retaining when the parent is cancelled — an idle descendant would be
    # released by the idle window before the TERM arrives, which is correct for
    # an adopted daemon but not what this cancellation path is testing.
    gated_context =
      Map.merge(context, %{
        descendant_release_barrier: true,
        status_read_delay_seconds: 5,
        started_path: ""
      })

    {port, root_pid} = start_gated_port("mix test", gated_context)
    wait_for_file!(context.descendant_path)
    wait_for_file!(context.descendant_path <> ".pid")
    wait_for_file!(context.mix_pid_path)

    mix_pid = context.mix_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    descendant_pid =
      context.descendant_path
      |> Kernel.<>(".pid")
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    # The busy descendant is normally reaped by the holder's cancellation
    # cleanup; guard the early-failure window so a failed test never leaks a
    # CPU-burning loop.
    on_exit(fn ->
      System.cmd("kill", ["-KILL", Integer.to_string(descendant_pid)], stderr_to_stdout: true)
    end)

    assert_process_gone!(mix_pid)

    System.cmd("kill", ["-TERM", "--", "-#{root_pid}"], stderr_to_stdout: true)
    assert_receive {^port, {:exit_status, _status}}, 7_000
    assert_process_gone!(descendant_pid)

    assert {_output, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{started_path: "", timeout_seconds: 2})
             )
  end

  @tag @linux_only
  test "pause containment reaps Mix before the detached holder releases capacity", context do
    gated_context =
      Map.merge(context, %{
        sleep_seconds: 30,
        started_path: context.started_path
      })

    {port, root_pid} = start_gated_port("mix test", gated_context)
    wait_for_file!(context.started_path)
    wait_for_file!(context.mix_pid_path)
    mix_pid = context.mix_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    name = Module.concat(__MODULE__, "GateContainment#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      PauseContainment.start_link(
        name: name,
        grace_ms: 60_000,
        event_fun: fn _stage, _payload -> :ok end
      )

    assert {:ok, handle} = PauseContainment.register(name, "repo#1154", root_pid, root_pid)
    assert {:ok, ^handle} = PauseContainment.arm(name, "repo#1154")

    send(name, {:fallback, "repo#1154", handle.generation})
    assert_receive {^port, {:exit_status, _status}}, 7_000
    assert_process_gone!(mix_pid)

    assert {_output, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{started_path: "", timeout_seconds: 2})
             )
  end

  @tag @linux_only
  test "pause containment spares adopted session daemons while reaping the build", context do
    # #2387: pausing an agent must never take out the session keyring. The
    # pause/cancel path (`PauseContainment` -> the holder's exception path)
    # used to sweep every child of the subreaper and `killpg` its process
    # group, which is how an adopted `dbus-daemon` / `gnome-keyring-daemon`
    # died. This mirrors the assertion #2381 added for the timeout path: the
    # build's own process is gone but the adopted daemons are still alive.
    #
    # Two daemons stand in for the real daemon (#2404): one ignores TERM
    # (covers the SIGKILL-escalation path), and one keeps the default SIGTERM
    # disposition, as the real gnome-keyring-daemon does. A partial revert of
    # #2391 that sweeps adopted daemons with SIGTERM alone kills only the
    # default-disposition one; asserting both survive catches it.
    daemon_pid_path = Path.join(context.gate_dir, "pause-adopted-daemon.pid")
    default_term_daemon_pid_path = Path.join(context.gate_dir, "pause-adopted-daemon-default-term.pid")

    gated_context =
      Map.merge(context, %{
        sleep_seconds: 30,
        started_path: context.started_path,
        adopted_daemon_pid_path: daemon_pid_path,
        adopted_daemon_default_term_pid_path: default_term_daemon_pid_path
      })

    task = Task.async(fn -> run_bash("mix test", gated_context) end)

    wait_for_file!(context.started_path)
    wait_for_file!(context.mix_pid_path)
    wait_for_file!(daemon_pid_path)
    wait_for_file!(default_term_daemon_pid_path)

    mix_pid = context.mix_pid_path |> File.read!() |> String.trim() |> String.to_integer()
    daemon_pid = daemon_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    default_term_daemon_pid =
      default_term_daemon_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    # Clean up all processes even if a later assertion fails mid-test; the
    # daemons would otherwise outlive the run.
    on_exit(fn ->
      System.cmd("kill", ["-KILL", Integer.to_string(mix_pid)], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", Integer.to_string(daemon_pid)], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", Integer.to_string(default_term_daemon_pid)], stderr_to_stdout: true)
    end)

    # The holder is the subreaper that Popen'd the build; its owner record
    # carries its PID, published before the wrapped command even spawns.
    holder_pid = wait_for_holder_pid!(context.gate_dir)

    # Wait until each daemon's `setsid` parent has exited and it has actually
    # reparented onto the holder (PPID == holder_pid), so the pause lands on a
    # genuinely adopted stranger rather than a process still owned by the
    # build. Gating on "not the wrapped command" was satisfiable before the
    # reparent, because the daemon's immediate parent is the intermediate
    # subshell (#2404).
    wait_for_adopted_daemon!(daemon_pid, holder_pid)
    wait_for_adopted_daemon!(default_term_daemon_pid, holder_pid)

    # Signal the holder directly so its containment exception path (the one
    # that used to sweep the adopted daemons) runs. In production
    # `PauseContainment` reaches it via the agent's process group.
    System.cmd("kill", ["-TERM", Integer.to_string(holder_pid)], stderr_to_stdout: true)

    assert {_output, status} = Task.await(task, 10_000)
    assert status in [125, 0]

    # The build's own process is contained...
    assert_process_gone!(mix_pid)

    # ...while both adopted daemons (the gnome-keyring-daemon analogues)
    # survive — the TERM-ignoring one and the default-disposition one.
    assert {_state, 0} = System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(daemon_pid)])

    assert {_state, 0} =
             System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(default_term_daemon_pid)])

    # The slot is released promptly for the next build.
    assert {_output2, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{started_path: "", timeout_seconds: 2})
             )
  end

  @tag @linux_only
  test "a post-Popen holder failure reaps Mix before releasing the slot", context do
    assert {output, 125} =
             run_bash(
               "mix test",
               Map.merge(context, %{
                 holder_fail_after_popen: true,
                 ignore_term: true,
                 sleep_seconds: 30,
                 started_path: ""
               })
             )

    assert output =~ "aiur_build_gate gate_error reason=lease_holder_status_failed"
    maybe_assert_recorded_process_gone!(context.mix_pid_path)
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
    assert Path.wildcard(Path.join(context.gate_dir, "queue/lease-v2-*")) == []
  end

  @tag @linux_only
  test "a parent publication failure reaps TERM-resistant Mix", context do
    mv_path = System.find_executable("mv") || flunk("mv is required")
    write_controlled_mv!(Path.join(context.bin_dir, "mv"), mv_path)

    assert {output, 125} =
             run_bash(
               "mix test",
               Map.merge(context, %{
                 fail_final_owner_publication: true,
                 ignore_term: true,
                 sleep_seconds: 30,
                 started_path: ""
               })
             )

    assert output =~ "aiur_build_gate gate_error reason=owner_publish_failed"
    mix_pid = context.mix_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    on_exit(fn ->
      System.cmd("kill", ["-KILL", "--", "-#{mix_pid}"], stderr_to_stdout: true)
    end)

    assert_process_gone!(mix_pid)
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
  end

  @tag @linux_only
  test "a slow holder startup fails closed within a bounded handshake", context do
    started_at = System.monotonic_time(:millisecond)

    assert {output, 125} =
             run_bash(
               "mix test",
               Map.merge(context, %{
                 holder_start_delay_seconds: 5,
                 started_path: ""
               })
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 3_500
    assert output =~ "aiur_build_gate gate_error reason=lease_holder_start_failed"
    refute File.exists?(context.log_path)
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
    assert Path.wildcard(Path.join(context.gate_dir, ".holder-*-v2.*")) == []
  end

  @tag @linux_only
  test "Mix cannot unlink or replace host-owned slot locks", context do
    lock_path = Path.join(context.lock_dir, "slot-1.lock")
    inode = File.stat!(lock_path).inode
    File.chmod!(lock_path, 0o444)
    File.chmod!(context.lock_dir, 0o555)

    assert {output, 0} =
             run_bash(
               "mix test",
               Map.merge(context, %{attack_lock_namespace: true, started_path: ""})
             )

    assert output =~ "aiur_build_gate acquired slot=1"
    assert File.stat!(lock_path).inode == inode
    assert File.read!(context.log_path) == "test\n"
  end

  @tag @linux_only
  test "a descheduled parent receives the durable holder status", context do
    started_at = System.monotonic_time(:millisecond)

    assert {output, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{status_read_delay_seconds: 2, started_path: ""})
             )

    assert System.monotonic_time(:millisecond) - started_at >= 1_500
    assert output =~ "aiur_build_gate released slot=1 status=0"
  end

  @tag @linux_only
  test "a durable status acknowledgement wins after its parent exits", context do
    python = System.find_executable("python3") || flunk("python3 is required")
    holder_path = Path.expand("../../../priv/build_gate_holder.py", __DIR__)
    ack_path = Path.join(context.gate_dir, "late-status-ack")
    token = "test-token"
    File.write!(ack_path, "ack=#{token}\n")

    probe = ~S"""
    import runpy, sys, time

    holder = runpy.run_path(sys.argv[1])
    holder["wait_for_status_ack"](
        sys.argv[2], sys.argv[3], int(sys.argv[4]), time.monotonic() - 1
    )
    """

    assert {"", 0} =
             System.cmd(
               python,
               ["-c", probe, holder_path, ack_path, token, "999999999"],
               stderr_to_stdout: true
             )

    assert {"", 125} =
             System.cmd(
               python,
               ["-c", probe, holder_path, ack_path, "wrong-token", "999999999"],
               stderr_to_stdout: true
             )
  end

  @tag @linux_only
  test "admission timeout does not cap an admitted Mix command lifetime", context do
    started_at = System.monotonic_time(:millisecond)

    assert {output, 17} =
             run_bash(
               "mix compile",
               Map.merge(context, %{
                 timeout_seconds: 1,
                 sleep_seconds: 2,
                 mix_exit_status: 17,
                 started_path: ""
               })
             )

    assert System.monotonic_time(:millisecond) - started_at >= 1_500
    assert output =~ "aiur_build_gate acquired slot=1 command=compile"
    assert output =~ "aiur_build_gate released slot=1 status=17"
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
    assert {_output, 0} = run_bash("mix compile", Map.put(context, :started_path, ""))
  end

  @tag @linux_only
  test "substituted FIFO holder metadata fails closed without blocking", context do
    mktemp = System.find_executable("mktemp") || flunk("mktemp is required")
    write_controlled_mktemp!(Path.join(context.bin_dir, "mktemp"), mktemp)
    started_at = System.monotonic_time(:millisecond)

    assert {output, 125} =
             run_bash(
               "mix compile",
               Map.merge(context, %{
                 handshake_fifo_fragment: ".holder-started-v2.",
                 started_path: ""
               })
             )

    assert System.monotonic_time(:millisecond) - started_at < 3_500
    assert output =~ "aiur_build_gate gate_error reason=lease_holder_start_failed"
    refute File.exists?(context.log_path)
  end

  @tag @linux_only
  test "substituted FIFO status handoff fails closed without blocking", context do
    mktemp = System.find_executable("mktemp") || flunk("mktemp is required")
    write_controlled_mktemp!(Path.join(context.bin_dir, "mktemp"), mktemp)
    started_at = System.monotonic_time(:millisecond)

    assert {output, 125} =
             run_bash(
               "mix compile",
               Map.merge(context, %{
                 handshake_fifo_fragment: ".status-v2.",
                 started_path: ""
               })
             )

    assert System.monotonic_time(:millisecond) - started_at < 3_500
    assert output =~ "aiur_build_gate gate_error reason=lease_holder_status_failed"
    assert File.read!(context.log_path) == "compile\n"
  end

  @tag @linux_only
  test "a ps failure under errexit leaves no Linux queue debris", context do
    assert {output, 0} =
             run_bash(
               "set -e; ps() { return 1; }; mix compile",
               Map.merge(context, %{lease_strategy: "linux", started_path: ""})
             )

    assert output =~ "aiur_build_gate released slot=1 status=0"
    assert Path.wildcard(Path.join(context.gate_dir, "queue/lease-v2-*")) == []
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
  end

  @tag @linux_only
  test "an errexit shell preserves Mix failure after releasing its Linux lease", context do
    assert {output, 17} =
             run_bash(
               "set -e; mix compile",
               Map.merge(context, %{mix_exit_status: 17, started_path: ""})
             )

    assert output =~ "aiur_build_gate released slot=1 status=17"
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
    assert %{active: 0, queued: 0} = build_gate_status(gate_dir: context.gate_dir, capacity: 1)
  end
end
