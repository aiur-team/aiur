Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.StatusTest do
  use Aiur.TestSupport.BuildGateCase

  test "reports only live owners and queue entries", %{gate_dir: gate_dir} do
    File.mkdir_p!(Path.join(gate_dir, "slot-1"))
    File.mkdir_p!(Path.join(gate_dir, "slot-2"))
    File.mkdir_p!(Path.join(gate_dir, "queue"))

    File.write!(Path.join(gate_dir, "slot-1/owner"), "pid=#{System.pid()}\n")
    File.write!(Path.join(gate_dir, "slot-2/owner"), "pid=999999999\n")
    File.write!(Path.join(gate_dir, "queue/#{System.pid()}"), "pid=#{System.pid()}\n")
    File.write!(Path.join(gate_dir, "queue/stale"), "pid=999999999\n")

    assert %{enabled?: true, capacity: 2, active: 1, queued: 1} =
             build_gate_status(gate_dir: gate_dir, capacity: 2, strategy: :pid)
  end

  test "status reports the effective post-command retain window", %{gate_dir: gate_dir} do
    # The retain duration in effect is observable on the status surface so the
    # gate's throughput trade is measurable next time, not inferred from
    # `fuser` (#2398).
    assert %{enabled?: true, retain_seconds: 120} =
             build_gate_status(gate_dir: gate_dir, capacity: 1, strategy: :pid)

    assert %{enabled?: true, retain_seconds: 120} =
             build_gate_status(gate_dir: gate_dir, capacity: 1, strategy: :linux_lock)
  end

  test "reports a slot with a dead owner and live process group as active", %{gate_dir: gate_dir} do
    slot_path = Path.join(gate_dir, "slot-1")
    {pgid, 0} = System.cmd("ps", ["-o", "pgid=", "-p", System.pid()])
    File.write!(slot_path, "pid=999999999\npgid=#{String.trim(pgid)}\ncommand=test\n")

    assert %{active: 1} = build_gate_status(gate_dir: gate_dir, capacity: 1, strategy: :pid)
  end

  test "reports disabled status without inspecting a gate directory" do
    assert %{enabled?: false, capacity: 0, active: 0, queued: 0} =
             build_gate_status(
               gate_dir: "/missing",
               capacity: 0,
               stagger_seconds: 0,
               min_free_memory_mb: nil
             )
  end

  test "reports queued phase-only work when build capacity is unlimited", %{gate_dir: gate_dir} do
    File.mkdir_p!(Path.join(gate_dir, "queue"))
    File.write!(Path.join(gate_dir, "queue/#{System.pid()}"), "pid=#{System.pid()}\n")

    assert %{enabled?: true, capacity: 0, active: 0, queued: 1} =
             build_gate_status(
               gate_dir: gate_dir,
               capacity: 0,
               stagger_seconds: 5,
               min_free_memory_mb: nil,
               strategy: :pid
             )
  end

  @tag @linux_only
  test "status reclaims unlocked v2 metadata without counting it as live", context do
    File.mkdir_p!(Path.join(context.gate_dir, "queue"))
    File.touch!(Path.join(context.lock_dir, "slot-1.lock"))
    File.touch!(Path.join(context.lock_dir, "phase-start.lock"))

    owner_path = Path.join(context.gate_dir, "slot-1.owner")
    phase_owner_path = Path.join(context.gate_dir, "phase-start.owner")
    queue_path = Path.join(context.gate_dir, "queue/lease-v2-stale")
    metadata = "version=2\ntoken=stale\npid=2\npgid=1\nphase=test\ncommand=test\n"
    File.write!(owner_path, metadata)
    File.write!(phase_owner_path, metadata)
    File.write!(queue_path, metadata)

    assert %{enabled?: true, capacity: 1, active: 0, queued: 0} =
             build_gate_status(gate_dir: context.gate_dir, capacity: 1)

    refute File.exists?(owner_path)
    refute File.exists?(phase_owner_path)
    refute File.exists?(queue_path)
  end

  @tag @linux_only
  test "status names a live Linux holder and keeps a long-held lease", context do
    slot_lock = Path.join(context.lock_dir, "slot-1.lock")
    owner_path = Path.join(context.gate_dir, "slot-1.owner")
    pid_path = Path.join(context.gate_dir, "holder.pid")
    release_path = Path.join(context.gate_dir, "holder.release")
    bash = System.find_executable("bash") || flunk("bash is required")

    holder =
      Port.open({:spawn_executable, String.to_charlist(bash)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-c",
          ~S"""
          printf '%s\n' "$$" > "$4"
          exec 8<>"$1"
          flock 8
          printf 'ready\n'
          while [[ ! -e $3 ]]; do sleep 0.05; done
          """,
          "build-gate-holder",
          slot_lock,
          owner_path,
          release_path,
          pid_path
        ]
      ])

    assert_receive {^holder, {:data, "ready\n"}}, 2_000

    on_exit(fn ->
      File.touch!(release_path)
      if Port.info(holder), do: Port.close(holder)
    end)

    holder_pid = pid_path |> File.read!() |> String.trim() |> String.to_integer()

    File.write!(
      owner_path,
      "version=2\ntoken=live\npid=#{holder_pid}\npgid=1\nholder_pid=0\ncommand_pgid=1\n" <>
        "phase=test\ncommand=mix test\nstarted_at=#{System.os_time(:second) - 120}\n"
    )

    # The reported holder is a known process (the one created above) and the
    # lease has been held for the full duration. A long-held lease with a live
    # holder is NOT reclaimed by time — a blanket timeout would trade a stall
    # for a corrupted long build.
    assert %{
             enabled?: true,
             active: 1,
             holders: [%{kind: :slot, slot: 1, pid: reported_pid, command: "mix test", held_for_seconds: held}]
           } = build_gate_status(gate_dir: context.gate_dir, capacity: 1)

    assert reported_pid == holder_pid
    assert held >= 119
    assert File.exists?(owner_path)
  end

  @tag @linux_only
  test "a Linux lease whose holder has exited is released without operator action", context do
    slot_lock = Path.join(context.lock_dir, "slot-1.lock")
    owner_path = Path.join(context.gate_dir, "slot-1.owner")
    pid_path = Path.join(context.gate_dir, "holder.pid")
    release_path = Path.join(context.gate_dir, "holder.release")
    bash = System.find_executable("bash") || flunk("bash is required")

    holder =
      Port.open({:spawn_executable, String.to_charlist(bash)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-c",
          ~S"""
          printf '%s\n' "$$" > "$4"
          exec 8<>"$1"
          flock 8
          printf 'ready\n'
          while [[ ! -e $3 ]]; do sleep 0.05; done
          """,
          "build-gate-holder",
          slot_lock,
          owner_path,
          release_path,
          pid_path
        ]
      ])

    assert_receive {^holder, {:data, "ready\n"}}, 2_000

    on_exit(fn ->
      File.touch!(release_path)
      if Port.info(holder), do: Port.close(holder)
    end)

    holder_pid = pid_path |> File.read!() |> String.trim() |> String.to_integer()

    File.write!(
      owner_path,
      "version=2\ntoken=dead\npid=#{holder_pid}\npgid=1\nholder_pid=0\ncommand_pgid=1\n" <>
        "phase=test\ncommand=mix test\nstarted_at=#{System.os_time(:second) - 60}\n"
    )

    assert %{active: 1} = build_gate_status(gate_dir: context.gate_dir, capacity: 1)

    # The holder exits; the kernel releases its flock with it.
    System.cmd("kill", ["-KILL", Integer.to_string(holder_pid)], stderr_to_stdout: true)
    assert_receive {^holder, {:exit_status, _status}}, 2_000

    # The lease is free without operator action and the status surface reclaims
    # the stale metadata.
    assert %{active: 0, holders: []} = build_gate_status(gate_dir: context.gate_dir, capacity: 1)
    refute File.exists?(owner_path)

    # A later verification command acquires the freed slot.
    assert {output, 0} = run_bash("mix compile", Map.put(context, :started_path, ""))
    assert output =~ "aiur_build_gate acquired slot=1"
  end

  test "PID status reaps a lease whose holder has exited", %{gate_dir: gate_dir} do
    slot_path = Path.join(gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    owner_path = Path.join(slot_path, "owner")

    File.write!(owner_path, "pid=999999999\npgid=999999999\nversion=2\ntoken=dead\ncommand=mix test\n")

    assert %{active: 0, holders: []} =
             build_gate_status(gate_dir: gate_dir, capacity: 1, strategy: :pid)

    refute File.exists?(owner_path)
  end

  test "PID status names a live long-running holder and does not reclaim it", %{gate_dir: gate_dir} do
    slot_path = Path.join(gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    owner_path = Path.join(slot_path, "owner")
    self_pid = String.to_integer(System.pid())

    File.write!(
      owner_path,
      "pid=#{self_pid}\npgid=#{self_pid}\nversion=2\ntoken=live\n" <>
        "command=mix test\nstarted_at=#{System.os_time(:second) - 3_600}\n"
    )

    assert %{
             enabled?: true,
             active: 1,
             holders: [%{kind: :slot, slot: 1, pid: pid, command: "mix test", held_for_seconds: held}]
           } = build_gate_status(gate_dir: gate_dir, capacity: 1, strategy: :pid)

    assert pid == self_pid
    assert held >= 3_599
    assert File.exists?(owner_path)
  end

  test "PID status names a live queued holder", %{gate_dir: gate_dir} do
    queue_dir = Path.join(gate_dir, "queue")
    File.mkdir_p!(queue_dir)
    self_pid = String.to_integer(System.pid())

    # Match the PID path's queue record shape: `pid=` leads the record.
    File.write!(
      Path.join(queue_dir, "lease-v2-queued"),
      "pid=#{self_pid}\ncommand=mix compile\nstarted_at=#{System.os_time(:second) - 30}\n"
    )

    assert %{
             enabled?: true,
             queued: 1,
             holders: [%{kind: :queue, pid: pid, command: "mix compile", held_for_seconds: held}]
           } = build_gate_status(gate_dir: gate_dir, capacity: 1, strategy: :pid)

    assert pid == self_pid
    assert held >= 29
  end

  test "status reports the oldest live queue wait and zero for an empty queue", %{gate_dir: gate_dir} do
    assert %{oldest_wait_seconds: 0} =
             build_gate_status(gate_dir: gate_dir, capacity: 1, strategy: :pid)

    queue_dir = Path.join(gate_dir, "queue")
    File.mkdir_p!(queue_dir)
    self_pid = String.to_integer(System.pid())
    now = System.os_time(:second)

    File.write!(Path.join(queue_dir, "lease-v2-newer"), "pid=#{self_pid}\nstarted_at=#{now - 20}\n")
    File.write!(Path.join(queue_dir, "lease-v2-oldest"), "pid=#{self_pid}\nstarted_at=#{now - 190}\n")

    assert %{queued: 2, oldest_wait_seconds: wait} =
             build_gate_status(gate_dir: gate_dir, capacity: 1, strategy: :pid)

    assert wait >= 189
  end

  test "disabled status reports a measured empty wait" do
    assert %{enabled?: false, active: 0, queued: 0, oldest_wait_seconds: 0} =
             BuildGate.status(capacity: 0, stagger_seconds: 0, min_free_memory_mb: nil)
  end

  @tag @linux_only
  test "Linux status scans two active and eight queued holders in one bounded pass", context do
    release_path = Path.join(context.gate_dir, "scan.release")
    bash = System.find_executable("bash") || flunk("bash is required")

    holder =
      Port.open({:spawn_executable, String.to_charlist(bash)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-c",
          ~S"""
          now=$(date +%s)
          for slot in 1 2; do
            path="$2/slot-$slot.lock"
            exec {fd}<>"$path"
            flock "$fd"
            printf 'version=2\npid=%s\nstarted_at=%s\n' "$$" "$((now - slot))" > "$1/slot-$slot.owner"
          done
          mkdir -p "$1/queue"
          for queue in $(seq 1 8); do
            path="$1/queue/lease-v2-$queue"
            printf 'version=2\npid=%s\nstarted_at=%s\n' "$$" "$((now - queue * 10))" > "$path"
            exec {fd}<>"$path"
            flock "$fd"
          done
          printf 'ready\n'
          while [[ ! -e $3 ]]; do sleep 0.05; done
          """,
          "build-gate-saturated-holder",
          context.gate_dir,
          context.lock_dir,
          release_path
        ]
      ])

    on_exit(fn ->
      File.touch!(release_path)
      if Port.info(holder), do: Port.close(holder)
    end)

    # Wait on the holder's real "ready" signal; a hang is bounded by the ExUnit test timeout.
    receive do
      {^holder, {:data, "ready\n"}} -> :ok
    end

    status = build_gate_status(gate_dir: context.gate_dir, capacity: 2, strategy: :linux_lock)

    assert %{active: 2, queued: 8, oldest_wait_seconds: wait, degraded?: nil} = Map.put_new(status, :degraded?, nil)
    assert wait >= 79
  end

  @tag @linux_only
  test "status rejects a FIFO queue record without blocking", context do
    queue_dir = Path.join(context.gate_dir, "queue")
    fifo_path = Path.join(queue_dir, "lease-v2-fifo")
    File.mkdir_p!(queue_dir)
    assert {"", 0} = System.cmd("mkfifo", [fifo_path])

    status =
      Task.async(fn ->
        build_gate_status(
          gate_dir: context.gate_dir,
          capacity: 1,
          strategy: :linux_lock
        )
      end)
      |> Task.await(1_000)

    assert %{
             enabled?: true,
             queued: 0,
             degraded?: true,
             issues: issues
           } = status

    assert Enum.any?(issues, fn issue ->
             issue.reason == :lock_probe_failed and issue.path == fifo_path and
               issue.detail == %{reason: :not_regular, type: :other}
           end)
  end

  test "status reports legacy metadata as degraded without trusting its PID", context do
    legacy_path = Path.join(context.gate_dir, "slot-1")
    File.write!(legacy_path, "pid=2\npgid=1\ncommand=test\n")

    assert %{
             enabled?: true,
             capacity: 1,
             active: 0,
             queued: 0,
             degraded?: true,
             issues: [%{path: ^legacy_path, reason: :legacy_state}]
           } = build_gate_status(gate_dir: context.gate_dir, capacity: 1)
  end

  @tag @linux_only
  test "status reports a holder self-release timeout marker", context do
    marker_path = Path.join(context.gate_dir, "slot-1.hold-timeout")
    File.write!(marker_path, "version=2\ncommand=mix test --trace\nheld_for_seconds=3600\nreason=running\n")

    assert %{
             enabled?: true,
             timeouts: [%{slot: 1, command: "mix test --trace", held_for_seconds: 3600, reason: "running"}]
           } = build_gate_status(gate_dir: context.gate_dir, capacity: 1)

    # The marker does not make the slot "active" — it is a released-lease record.
    assert %{active: 0, queued: 0} = build_gate_status(gate_dir: context.gate_dir, capacity: 1)
  end

  test "status distinguishes a busy slot from a slot held without a command", %{gate_dir: gate_dir} do
    File.mkdir_p!(Path.join(gate_dir, "slot-1"))
    File.mkdir_p!(Path.join(gate_dir, "slot-2"))
    self_pid = String.to_integer(System.pid())
    {pgid, 0} = System.cmd("ps", ["-o", "pgid=", "-p", System.pid()])
    live_pgid = pgid |> String.trim() |> String.to_integer()

    File.write!(
      Path.join(gate_dir, "slot-1/owner"),
      "pid=#{self_pid}\npgid=#{self_pid}\nversion=2\ntoken=a\ncommand_pgid=#{live_pgid}\n" <>
        "phase=test\ncommand=mix test\nstarted_at=#{System.os_time(:second) - 30}\n"
    )

    File.write!(
      Path.join(gate_dir, "slot-2/owner"),
      "pid=#{self_pid}\npgid=#{self_pid}\nversion=2\ntoken=b\ncommand_pgid=999999999\n" <>
        "phase=test\ncommand=mix test\nstarted_at=#{System.os_time(:second) - 30}\n"
    )

    assert %{active: 2, holders: holders} =
             build_gate_status(gate_dir: gate_dir, capacity: 2, strategy: :pid)

    slot1 = Enum.find(holders, &(&1.slot == 1))
    slot2 = Enum.find(holders, &(&1.slot == 2))
    assert slot1.command_alive? == true
    assert slot2.command_alive? == false
  end
end
