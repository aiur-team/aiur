Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.RetainTest do
  use Aiur.TestSupport.BuildGateCase

  @tag @linux_only
  test "cleanup waits for a descendant release acknowledgement", context do
    task = Task.async(fn -> release_descendant!(context) end)
    wait_for_file!(context.descendant_release_path)
    assert Task.yield(task, 0) == nil

    File.touch!(context.descendant_path)
    File.touch!(context.descendant_path <> ".done")
    assert Task.await(task) == :ok
  end

  @tag @linux_only
  test "a slot holder protects a Mix descendant after its wrapper exits", context do
    release_descendant_on_exit(context)

    descendant_context =
      Map.merge(context, %{
        descendant_release_barrier: true,
        started_path: ""
      })

    assert {output, 0} = run_bash("shopt -s varredir_close; mix test", descendant_context)
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    wait_for_file!(context.descendant_path)

    assert {blocked_output, 124} =
             run_bash(
               "mix compile",
               Map.merge(context, %{timeout_seconds: 0, started_path: ""})
             )

    assert blocked_output =~ "aiur_build_gate timeout"
    release_descendant!(context)
    assert {_output, 0} = run_bash("mix compile", Map.put(context, :started_path, ""))
  end

  @tag @linux_only
  test "a real Mix descendant retains capacity after the BEAM exits", context do
    release_descendant_on_exit(context)

    assert {output, 0} = run_real_mix("mix test", context)
    assert output =~ "aiur_build_gate acquired slot=1 command=test"
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    wait_for_file!(context.descendant_path)

    assert {blocked_output, 124} =
             run_bash(
               "mix compile",
               Map.merge(context, %{timeout_seconds: 0, started_path: ""})
             )

    assert blocked_output =~ "aiur_build_gate timeout"
    release_descendant!(context)
    assert {_output, 0} = run_bash("mix compile", Map.put(context, :started_path, ""))
  end

  @tag @linux_only
  test "an unreapable adopted daemon does not hold the slot after the command exits", context do
    # The #2381 incident, reproduced. The wrapped command exits, but a daemon
    # from an unrelated session (dbus-daemon, gnome-keyring-daemon) has
    # reparented onto the subreaper. `waitpid(-1)` never reaches ECHILD, so the
    # holder used to wait — and, once the cap fired, spin in an unbounded kill
    # loop — while still holding the slot flock. Four slots leaked this way in
    # fifteen minutes.
    #
    # The daemons are never going to exit, so the release has to come from the
    # CPU-gated retain (#2398) rather than from `waitpid` — and it has to come
    # without signalling the daemons. Both daemons are idle (0% CPU), so the
    # holder releases the slot after the one-second idle window, long before
    # the 120s default retain window expires.
    daemon_pid_path = Path.join(context.gate_dir, "adopted-daemon.pid")
    default_term_daemon_pid_path = Path.join(context.gate_dir, "adopted-daemon-default-term.pid")

    gated_context =
      Map.merge(context, %{
        adopted_daemon_pid_path: daemon_pid_path,
        adopted_daemon_default_term_pid_path: default_term_daemon_pid_path,
        started_path: ""
      })

    assert {output, 0} = run_bash("mix test", gated_context)
    assert output =~ "aiur_build_gate acquired slot=1 command=test"
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    # The effective retain window is observable on the gate log.
    assert output =~ "retain_seconds=120"
    wait_for_file!(daemon_pid_path)
    wait_for_file!(default_term_daemon_pid_path)
    daemon_pid = daemon_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    default_term_daemon_pid =
      default_term_daemon_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    on_exit(fn ->
      System.cmd("kill", ["-KILL", Integer.to_string(daemon_pid)], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", Integer.to_string(default_term_daemon_pid)], stderr_to_stdout: true)
    end)

    # The slot comes back on its own, well inside the default retain window:
    # the idle daemon is not doing build work, so the courtesy is over in ~1s.
    wait_for_status!(context.gate_dir, 1, fn status -> status.active == 0 end)
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))

    # An early release is the expected steady state, not a timeout: it must not
    # leave a `reason=retained` marker that the daemon turns into a
    # needs-attention alert for every build that saw an adopted daemon.
    refute File.exists?(Path.join(context.gate_dir, "slot-1.hold-timeout"))

    # The daemons are left running, deliberately. gnome-keyring-daemon holds the
    # credential the fleet's GitHub access depends on: cleanup must scope
    # itself to the leased command's session and never signal an adopted
    # stranger, no matter how long it lives. Both the TERM-ignoring daemon and
    # the default-disposition one survive (#2404).
    assert {_state, 0} = System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(daemon_pid)])

    assert {_state, 0} =
             System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(default_term_daemon_pid)])

    # The flock is genuinely gone, not merely the owner file: the next gated
    # command takes the same slot.
    assert {next_output, 0} = run_bash("mix compile", Map.put(context, :started_path, ""))
    assert next_output =~ "aiur_build_gate acquired slot=1 command=compile"
  end

  @tag @linux_only
  test "a holder whose wrapped command exited releases its slot at the max-hold cap", context do
    # The leak (#2349): the wrapped command exits but a CPU-burning descendant
    # keeps the subreaper's `waitpid(-1)` from ever seeing ECHILD, so the slot
    # is held long after the command is gone. The descendant is genuinely busy
    # (#2398), so the holder keeps the lease while it compiles; the absolute
    # wall-clock cap is the backstop that frees the slot regardless.
    release_descendant_on_exit(context)

    gated_context =
      Map.merge(context, %{
        descendant_release_barrier: true,
        max_hold_seconds: 3,
        started_path: ""
      })

    assert {output, 0} = run_bash("mix test", gated_context)
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    wait_for_file!(context.descendant_path)

    # The retained descendant is still alive and busy, so the slot stays
    # protected (it must not be released by the idle window).
    assert %{active: 1} = build_gate_status(gate_dir: context.gate_dir, capacity: 1)

    # The cap expires and the holder releases the slot, leaving a durable
    # marker the daemon turns into a needs-attention alert naming the command.
    wait_for_status!(context.gate_dir, 1, fn status ->
      status.active == 0 and File.exists?(Path.join(context.gate_dir, "slot-1.hold-timeout"))
    end)

    marker = File.read!(Path.join(context.gate_dir, "slot-1.hold-timeout"))
    assert marker =~ "mix test"
    assert marker =~ "reason=retained"
    assert marker =~ "held_for_seconds="
    assert %{active: 0} = build_gate_status(gate_dir: context.gate_dir, capacity: 1)
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
  end

  @tag @linux_only
  test "an idle retained Mix descendant releases the slot well inside the retain window", context do
    # A retained descendant that consumes no CPU (here a long `sleep`) is not
    # doing build work. The holder keeps the slot only while a descendant is
    # compiling (#2398), so it releases after the one-second idle window
    # instead of holding the default 120s retain window.
    gated_context =
      Map.merge(context, %{
        descendant_sleep_seconds: 30,
        max_hold_seconds: 0,
        started_path: ""
      })

    assert {output, 0} = run_bash("mix test", gated_context)
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    wait_for_file!(context.descendant_path)

    # The slot frees long before the 120s retain window, and without a timeout
    # marker — an early release is the expected steady state, not a defect.
    wait_for_status!(context.gate_dir, 1, fn status -> status.active == 0 end)
    refute File.exists?(Path.join(context.gate_dir, "slot-1.hold-timeout"))
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
  end

  @tag @linux_only
  test "back-to-back builds that leave idle adopted daemons drain the queue without saturating the gate", context do
    # The #2398 acceptance shape: N builds completing back-to-back on an idle
    # box must not leave the gate at `0/N active` with a non-empty queue. Each
    # build spawns an idle adopted daemon that reparents onto its holder, so
    # `waitpid(-1)` never reaches ECHILD and, before #2398, every slot sat
    # "held without a command" for the full 120s retain window. The CPU-gated
    # retain releases each slot ~1s after its build exits, so the second wave
    # acquires promptly and the queue drains.
    daemon_paths = for index <- 1..4, do: Path.join(context.gate_dir, "adopted-daemon-#{index}.pid")

    on_exit(fn ->
      for path <- daemon_paths do
        if File.exists?(path) do
          pid = path |> File.read!() |> String.trim() |> String.to_integer()
          System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        end
      end
    end)

    gated_context =
      Map.merge(context, %{
        slots: 2,
        started_path: ""
      })

    results =
      daemon_paths
      |> Enum.with_index(1)
      |> Enum.map(fn {daemon_path, index} ->
        Task.async(fn ->
          run_bash(
            "mix test --partition #{index}",
            Map.put(gated_context, :adopted_daemon_pid_path, daemon_path)
          )
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.all?(results, &match?({_output, 0}, &1))

    # The queue drained and both slots returned to idle: no slot was wedged by
    # a 120s retain hold. `0/N active` with a non-empty queue is exactly the
    # saturation shape this ticket is about.
    wait_for_status!(context.gate_dir, 2, fn status ->
      status.active == 0 and status.queued == 0
    end)

    # An early release is the expected steady state, not a timeout: no
    # needs-attention markers from any of the four builds.
    refute File.exists?(Path.join(context.gate_dir, "slot-1.hold-timeout"))
    refute File.exists?(Path.join(context.gate_dir, "slot-2.hold-timeout"))
  end

  @tag @linux_only
  test "a periodically-waking adopted daemon does not hold the slot after the command exits", context do
    # A real session daemon (dbus-daemon on a live session) is not `sleep`: it
    # wakes on timers and handles messages, so it consumes a small but nonzero
    # slice of CPU. The 3ms/s idle threshold must sit above that floor, or
    # every real daemon would be misread as "build work" and #2398 would be
    # straight back. This fixture is a low-duty-cycle timer loop (~0.5ms/s)
    # that pins the lower bound: it provably consumes CPU, yet is still
    # released by the idle window.
    daemon_pid_path = Path.join(context.gate_dir, "adopted-waking-daemon.pid")

    gated_context =
      Map.merge(context, %{
        adopted_daemon_pid_path: daemon_pid_path,
        adopted_daemon_wakeup: true,
        started_path: ""
      })

    assert {output, 0} = run_bash("mix test", gated_context)
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    wait_for_file!(daemon_pid_path)
    daemon_pid = daemon_pid_path |> File.read!() |> String.trim() |> String.to_integer()
    on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(daemon_pid)], stderr_to_stdout: true) end)

    # The fixture genuinely consumes CPU — a `sleep 600` daemon consumes
    # nothing and would pin no lower bound at all.
    first_cpu = cpu_ns_from_schedstat(daemon_pid)
    Process.sleep(1_500)
    second_cpu = cpu_ns_from_schedstat(daemon_pid)
    assert second_cpu > first_cpu

    # Yet the slot still comes back inside the idle window: ~0.5ms/s is far
    # below the 3ms/s threshold, so this is not "build work".
    wait_for_status!(context.gate_dir, 1, fn status -> status.active == 0 end)
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
    refute File.exists?(Path.join(context.gate_dir, "slot-1.hold-timeout"))

    # The daemon is left running, deliberately, exactly like the keyring.
    assert {_state, 0} = System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(daemon_pid)])
  end

  @tag @linux_only
  test "a holder keeps the slot when descendant CPU measurement is unavailable", context do
    # On a kernel without CONFIG_SCHEDSTATS the holder cannot read descendant
    # CPU. The old `/proc/stat` fallback resolved to 10ms granularity against
    # the 3ms threshold, reading a genuinely compiling child in the 3-10ms/window
    # band as idle and releasing the slot out from under it (#2386).
    # Measurement-unavailable must therefore hold conservatively to the retain
    # deadline instead of guessing from a coarse number.
    gated_context =
      Map.merge(context, %{
        descendant_sleep_seconds: 30,
        retain_seconds: 4,
        cpu_measure_unavailable: true,
        started_path: ""
      })

    assert {output, 0} = run_bash("mix test", gated_context)
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    wait_for_file!(context.descendant_path)

    # Well past the 1s idle window the slot is still held: there is no idle
    # release when the measurement that would prove idleness is unavailable.
    Process.sleep(2_000)
    assert %{active: 1} = build_gate_status(gate_dir: context.gate_dir, capacity: 1)

    # The retain deadline is the guaranteed release, with the durable marker.
    wait_for_status!(context.gate_dir, 1, fn status ->
      status.active == 0 and File.exists?(Path.join(context.gate_dir, "slot-1.hold-timeout"))
    end)

    marker = File.read!(Path.join(context.gate_dir, "slot-1.hold-timeout"))
    assert marker =~ "reason=retained"
  end

  @tag @linux_only
  test "descendant CPU measurement reports unavailable instead of a coarse stat fallback", context do
    # The #2398 review pinned a latent #2386 regression: the old code fell back
    # from an unreadable schedstat to `/proc/<pid>/stat` utime+stime ticks,
    # which resolve to 10ms granularity against the 3ms idle threshold. A
    # genuinely compiling child in the 3-10ms/window band read as a delta of 0
    # — indistinguishable from an idle daemon — and the slot was released out
    # from under it. Measurement unavailable must be reported as `None` (the
    # conservative hold), never as a coarse number that looks comparable.
    python = System.find_executable("python3") || flunk("python3 is required")
    holder_path = Path.expand("../../../priv/build_gate_holder.py", __DIR__)
    missing_path = Path.join(context.gate_dir, "no-such-schedstat")

    probe = ~S"""
    import runpy, sys, os
    holder = runpy.run_path(sys.argv[1])
    value = holder["proc_cpu_ns"](os.getpid())
    print("none" if value is None else "number")
    """

    # Sanity: on this host schedstat is present, so a live process reads a
    # number through the real path.
    assert {"number\n", 0} =
             System.cmd(python, ["-c", probe, holder_path], stderr_to_stdout: true)

    # When the schedstat path is unreadable (CONFIG_SCHEDSTATS=n), the holder
    # must report measurement-unavailable (None) rather than falling back to a
    # coarse `/proc/stat` tick count.
    assert {"none\n", 0} =
             System.cmd(
               python,
               ["-c", probe, holder_path],
               env: [{"AIUR_BUILD_GATE_HOLDER_SCHEDSTAT_PATH", missing_path}],
               stderr_to_stdout: true
             )
  end

  @tag @linux_only
  test "a zero retain window disables the post-command courtesy entirely", context do
    # agent.build_gate_retain_seconds: 0 is the documented opt-out: the
    # wrapped command has already exited, so the slot is handed straight back
    # even with a still-busy descendant — no idle-window sampling, no courtesy
    # at all.
    release_descendant_on_exit(context)

    gated_context =
      Map.merge(context, %{
        descendant_release_barrier: true,
        retain_seconds: 0,
        started_path: ""
      })

    assert {output, 0} = run_bash("mix test", gated_context)
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    # The effective retain value is observable on the gate log.
    assert output =~ "retain_seconds=0"
    wait_for_file!(context.descendant_path)

    # Released promptly despite the busy descendant: the courtesy is off, so
    # nothing keeps the slot and nothing is signalled.
    wait_for_status!(context.gate_dir, 1, fn status -> status.active == 0 end)
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
    refute File.exists?(Path.join(context.gate_dir, "slot-1.hold-timeout"))
  end

  @tag @linux_only
  test "the retain value plumbed through BuildGate.shell_env is honoured by the holder", context do
    # End to end: Config.build_gate_retain_seconds -> BuildGate.shell_env
    # exports AIUR_BUILD_GATE_RETAIN_SECONDS -> the holder's retain_seconds().
    # A non-default value (2s) must actually change the holder's behaviour: a
    # busy retained descendant is released at the 2s courtesy ceiling with a
    # marker, not held for the 120s default. If the export name were wrong or
    # the holder ignored the value, the slot would still be held past the 2s
    # window and this test would time out.
    release_descendant_on_exit(context)

    gated_context =
      Map.merge(context, %{
        descendant_release_barrier: true,
        started_path: ""
      })

    assert {output, 0} = run_bash_with_shell_env("mix test", gated_context, retain_seconds: 2)
    assert output =~ "aiur_build_gate lease_retained slot=1 status=0"
    assert output =~ "retain_seconds=2"
    wait_for_file!(context.descendant_path)

    # The busy descendant keeps the slot through the 2s courtesy ceiling, then
    # the holder releases at the deadline with a durable marker.
    wait_for_status!(context.gate_dir, 1, fn status ->
      status.active == 0 and File.exists?(Path.join(context.gate_dir, "slot-1.hold-timeout"))
    end)

    marker = File.read!(Path.join(context.gate_dir, "slot-1.hold-timeout"))
    assert marker =~ "reason=retained"
  end

  @tag @linux_only
  test "a command running past the max-hold cap is terminated and releases its slot", context do
    # The #2311 shape: a running command monopolises a slot (here simulated by a
    # 30s fake mix). The absolute cap terminates it and releases the slot.
    gated_context =
      Map.merge(context, %{
        sleep_seconds: 30,
        max_hold_seconds: 1,
        started_path: ""
      })

    assert {output, 124} = run_bash("mix test", gated_context)
    assert output =~ "aiur_build_gate released slot=1 status=124"

    marker_path = Path.join(context.gate_dir, "slot-1.hold-timeout")
    assert File.exists?(marker_path)
    assert File.read!(marker_path) =~ "reason=running"
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
    assert %{active: 0} = build_gate_status(gate_dir: context.gate_dir, capacity: 1)

    # The freed slot admits a later verification command.
    assert {_output, 0} = run_bash("mix compile", Map.put(context, :started_path, ""))
  end
end
