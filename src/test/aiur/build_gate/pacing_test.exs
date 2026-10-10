Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.PacingTest do
  use Aiur.TestSupport.BuildGateCase

  test "staggers concurrent phase starts while preserving overlap", context do
    paced_context =
      Map.merge(context, %{
        slots: 2,
        stagger_seconds: 1,
        sleep_seconds: 4
      })

    first = Task.async(fn -> run_bash("mix test", paced_context) end)
    wait_for_file!(context.started_path)

    second =
      Task.async(fn ->
        run_bash(
          "mise exec -- mix compile",
          %{paced_context | started_path: ""}
        )
      end)

    assert {_first_output, 0} = Task.await(first, 7_000)
    assert {second_output, 0} = Task.await(second, 7_000)

    events = timing_events!(context.timing_log_path)
    test_start = Map.fetch!(events, {:start, "test"})
    test_end = Map.fetch!(events, {:end, "test"})
    compile_start = Map.fetch!(events, {:start, "compile"})

    assert compile_start - test_start >= 1
    assert compile_start < test_end
    assert second_output =~ "aiur_perf phase_stagger_hold surface=build phase=compile"
  end

  test "single-slot capacity skips redundant start pacing", context do
    pacing_disabled_by_capacity =
      Map.merge(context, %{
        slots: 1,
        stagger_seconds: 5,
        timeout_seconds: 0
      })

    assert {first_output, 0} = run_bash("mix test", pacing_disabled_by_capacity)
    assert {second_output, 0} = run_bash("mix compile", pacing_disabled_by_capacity)

    refute first_output =~ "phase_stagger_hold"
    refute second_output =~ "phase_stagger_hold"
    assert File.read!(context.log_path) == "test\ncompile\n"
  end

  @tag @linux_only
  test "a fast command cannot remove its final owner publication", context do
    mv_path = System.find_executable("mv") || flunk("mv is required")
    write_controlled_mv!(Path.join(context.bin_dir, "mv"), mv_path)

    assert {output, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{delay_owner_publication: true, started_path: ""})
             )

    assert output =~ "aiur_build_gate released slot=1 status=0"
    refute output =~ "owner_publish_failed"
    refute File.exists?(Path.join(context.gate_dir, "slot-1.owner"))
  end

  test "phase-only pacing remains active with unlimited build slots", context do
    phase_only_context =
      Map.merge(context, %{
        slots: 0,
        stagger_seconds: 5,
        timeout_seconds: 5
      })

    assert {_first_output, 0} = run_bash("mix test", phase_only_context)

    assert {second_output, 124} =
             run_bash(
               "mix compile",
               %{phase_only_context | timeout_seconds: 0}
             )

    assert second_output =~ "aiur_perf phase_stagger_hold surface=build phase=compile"
    assert second_output =~ "aiur_build_gate timeout"
    assert File.read!(context.log_path) == "test\n"
    refute File.exists?(Path.join(context.gate_dir, "phase-start.lock"))
  end

  test "pacing timeout releases an acquired build slot", context do
    pacing_context = Map.merge(context, %{slots: 2, stagger_seconds: 5})

    assert {_first_output, 0} = run_bash("mix test", pacing_context)

    assert {second_output, 124} =
             run_bash(
               "mix compile",
               Map.put(pacing_context, :timeout_seconds, 0)
             )

    assert second_output =~ "aiur_build_gate acquired slot="
    assert second_output =~ "aiur_build_gate timeout"
    assert File.read!(context.log_path) == "test\n"
    refute File.exists?(Path.join(context.gate_dir, "slot-1"))
    refute File.exists?(Path.join(context.gate_dir, "slot-2"))
    refute File.exists?(Path.join(context.gate_dir, "phase-start.lock"))
  end

  test "reclaims a stale phase lock before admitting a build", context do
    lock_path = Path.join(context.gate_dir, "phase-start.lock")
    File.mkdir_p!(lock_path)
    File.write!(Path.join(lock_path, "owner"), "pid=999999999\n")

    assert {output, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{slots: 2, stagger_seconds: 1, lease_strategy: "pid"})
             )

    assert output =~ "aiur_build_gate stale_phase_lock_recovered owner_pid=999999999"
    assert File.read!(context.log_path) == "compile\n"
    refute File.exists?(lock_path)
  end

  test "reclaims a phase lock whose owner publication was interrupted", context do
    lock_path = Path.join(context.gate_dir, "phase-start.lock")
    File.mkdir_p!(lock_path)
    File.write!(Path.join(lock_path, "owner"), "")

    assert {output, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{slots: 2, stagger_seconds: 1, lease_strategy: "pid"})
             )

    assert output =~ "aiur_build_gate stale_phase_lock_recovered owner_pid=unknown"
    assert File.read!(context.log_path) == "compile\n"
    refute File.exists?(lock_path)
  end

  test "replaces malformed phase state without blocking the build", context do
    phase_state_path = Path.join(context.gate_dir, "phase-next-start")
    File.write!(phase_state_path, "not-a-timestamp\n")

    assert {output, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{slots: 2, stagger_seconds: 1})
             )

    assert output =~ "aiur_build_gate gate_error reason=phase_state_invalid"
    assert File.read!(context.log_path) == "compile\n"
    assert phase_state_path |> File.read!() |> String.trim() |> Integer.parse() |> elem(1) == ""
  end

  @tag @linux_only
  test "fails closed without opening FIFO-shaped phase state", context do
    phase_state_path = Path.join(context.gate_dir, "phase-next-start")
    assert {"", 0} = System.cmd("mkfifo", [phase_state_path])

    started_at = System.monotonic_time(:millisecond)

    assert {output, 125} =
             run_bash(
               "mix compile",
               Map.merge(context, %{slots: 2, stagger_seconds: 1, started_path: ""})
             )

    assert System.monotonic_time(:millisecond) - started_at < 2_000
    assert output =~ "aiur_build_gate gate_error reason=metadata_not_regular"
    refute File.exists?(context.log_path)
    refute File.exists?(Path.join(context.gate_dir, "phase-start.owner"))
  end

  @tag @linux_only
  test "fails closed without following phase state symlinks", context do
    fifo_path = Path.join(context.gate_dir, "attacker-fifo")
    phase_state_path = Path.join(context.gate_dir, "phase-next-start")
    assert {"", 0} = System.cmd("mkfifo", [fifo_path])
    File.ln_s!(fifo_path, phase_state_path)

    started_at = System.monotonic_time(:millisecond)

    assert {output, 125} =
             run_bash(
               "mix compile",
               Map.merge(context, %{slots: 2, stagger_seconds: 1, started_path: ""})
             )

    assert System.monotonic_time(:millisecond) - started_at < 2_000
    assert output =~ "aiur_build_gate gate_error reason=metadata_not_regular"
    refute File.exists?(context.log_path)
    refute File.exists?(Path.join(context.gate_dir, "phase-start.owner"))
  end

  @tag @linux_only
  test "paced multi-slot wait remains visible as live capacity", context do
    pacing_context = Map.merge(context, %{slots: 2, stagger_seconds: 3})
    assert {_first_output, 0} = run_bash("mix test", pacing_context)

    waiting = Task.async(fn -> run_bash("mix compile", pacing_context) end)
    wait_for_file!(Path.join(context.gate_dir, "phase-start.owner"))

    assert %{enabled?: true, capacity: 2, active: 1, queued: 0} =
             build_gate_status(gate_dir: context.gate_dir, capacity: 2)

    assert {output, 0} = Task.await(waiting, 7_000)
    assert output =~ "aiur_perf phase_stagger_hold surface=build phase=compile"
  end

  test "fails closed when the phase clock is unavailable", context do
    assert {output, 125} =
             run_bash(
               "aiur_build_gate_now_seconds() { return 1; }; mix compile",
               Map.merge(context, %{slots: 2, stagger_seconds: 5})
             )

    assert output =~ "aiur_build_gate gate_error reason=phase_clock_unavailable status=125"
    refute File.exists?(context.log_path)
    refute File.exists?(Path.join(context.gate_dir, "phase-start.owner"))
  end

  @tag @linux_only
  test "fails closed when phase owner publication is unavailable", context do
    phase_owner_path = Path.join(context.gate_dir, "phase-start.owner")
    File.mkdir_p!(phase_owner_path)

    assert {output, 125} =
             run_bash(
               "mix compile",
               Map.merge(context, %{slots: 2, stagger_seconds: 5})
             )

    assert output =~ "aiur_build_gate gate_error reason=owner_destination_invalid"
    refute File.exists?(context.log_path)
    assert File.dir?(phase_owner_path)
    assert File.ls!(phase_owner_path) == []
    assert Path.wildcard(Path.join(context.gate_dir, ".owner-v2.*")) == []
  end

  @tag @linux_only
  test "Linux admission reports legacy lease debris instead of guessing PID liveness", context do
    legacy_path = Path.join(context.gate_dir, "slot-1")
    File.write!(legacy_path, "pid=2\npgid=1\ncommand=test\n")

    assert {output, 125} = run_bash("mix compile", context)
    assert output =~ "aiur_build_gate gate_error reason=legacy_state_blocked path=#{legacy_path}"
    assert output =~ "recovery=repair_gate_or_disable_all_build_admission"
    refute File.exists?(context.log_path)
  end
end
