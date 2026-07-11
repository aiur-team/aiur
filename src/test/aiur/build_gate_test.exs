defmodule Aiur.BuildGateTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildGate

  setup do
    gate_dir = Path.join(System.tmp_dir!(), "aiur-build-gate-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(gate_dir, "bin")
    log_path = Path.join(gate_dir, "mix.log")
    started_path = Path.join(gate_dir, "mix.started")

    File.mkdir_p!(bin_dir)
    write_fake_mix!(Path.join(bin_dir, "mix"))
    write_fake_mise!(Path.join(bin_dir, "mise"))

    on_exit(fn -> File.rm_rf!(gate_dir) end)

    %{bin_dir: bin_dir, gate_dir: gate_dir, log_path: log_path, started_path: started_path}
  end

  test "reports only live owners and queue entries", %{gate_dir: gate_dir} do
    File.mkdir_p!(Path.join(gate_dir, "slot-1"))
    File.mkdir_p!(Path.join(gate_dir, "slot-2"))
    File.mkdir_p!(Path.join(gate_dir, "queue"))

    File.write!(Path.join(gate_dir, "slot-1/owner"), "pid=#{System.pid()}\n")
    File.write!(Path.join(gate_dir, "slot-2/owner"), "pid=999999999\n")
    File.write!(Path.join(gate_dir, "queue/#{System.pid()}"), "pid=#{System.pid()}\n")
    File.write!(Path.join(gate_dir, "queue/stale"), "pid=999999999\n")

    assert %{enabled?: true, capacity: 2, active: 1, queued: 1} =
             BuildGate.status(gate_dir: gate_dir, capacity: 2)
  end

  test "reports disabled status without inspecting a gate directory" do
    assert %{enabled?: false, capacity: 0, active: 0, queued: 0} = BuildGate.status(gate_dir: "/missing", capacity: 0)
  end

  test "does not inject a shell hook when operators opt out" do
    assert BuildGate.shell_env(slots: 0, stagger_seconds: 0, min_free_memory_mb: nil) == []

    env =
      BuildGate.shell_env(
        slots: 3,
        stagger_seconds: 7,
        min_free_memory_mb: 4_096,
        gate_dir: "/tmp/build-gate",
        hook_path: "/tmp/hook"
      )

    assert {"AIUR_BUILD_GATE_SLOTS", "3"} in env
    assert {"AIUR_BUILD_START_STAGGER_SECONDS", "7"} in env
    assert {"AIUR_MIN_FREE_MEMORY_MB", "4096"} in env

    assert {"BASH_ENV", "/tmp/hook"} in BuildGate.shell_env(
             slots: 0,
             stagger_seconds: 0,
             min_free_memory_mb: 4_096,
             gate_dir: "/tmp/build-gate",
             hook_path: "/tmp/hook"
           )

    assert {"BASH_ENV", "/tmp/hook"} in BuildGate.shell_env(
             slots: 0,
             stagger_seconds: 5,
             min_free_memory_mb: nil,
             gate_dir: "/tmp/build-gate",
             hook_path: "/tmp/hook"
           )
  end

  test "gates direct compile commands and releases their lease", context do
    assert {output, 0} = run_bash("mix compile", context)

    assert output =~ "aiur_build_gate queued"
    assert output =~ "aiur_build_gate acquired slot=1"
    assert output =~ "aiur_build_gate released slot=1 status=0"
    assert File.read!(context.log_path) == "compile\n"
    refute File.exists?(Path.join(context.gate_dir, "slot-1"))
  end

  test "gates documented mise exec Mix commands but leaves other Mix tasks alone", context do
    assert {gated_output, 0} = run_bash("mise exec -- mix test", context)
    assert gated_output =~ "aiur_build_gate acquired slot=1"

    assert {ungated_output, 0} = run_bash("mix format", context)
    refute ungated_output =~ "aiur_build_gate"

    assert File.read!(context.log_path) == "test\nformat\n"
  end

  test "queues a contending command until the prior lease releases", context do
    first = Task.async(fn -> run_bash("mix test", Map.put(context, :sleep_seconds, 2)) end)
    wait_for_file!(context.started_path)

    second = Task.async(fn -> run_bash("mix compile", context) end)
    assert Task.yield(second, 100) == nil

    assert {_first_output, 0} = Task.await(first, 5_000)
    assert {second_output, 0} = Task.await(second, 5_000)
    assert second_output =~ "aiur_build_gate queued"
    assert second_output =~ "aiur_build_gate acquired slot=1"
    assert File.read!(context.log_path) == "test\ncompile\n"
  end

  test "times out without running Mix while every slot has a live owner", context do
    slot_path = Path.join(context.gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    File.write!(Path.join(slot_path, "owner"), "pid=#{System.pid()}\n")

    assert {output, 124} = run_bash("mix compile", Map.put(context, :timeout_seconds, 0))
    assert output =~ "aiur_build_gate timeout"
    refute File.exists?(context.log_path)
  end

  test "reclaims a stale owner before running a later verification command", context do
    slot_path = Path.join(context.gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    File.write!(Path.join(slot_path, "owner"), "pid=999999999\n")

    assert {output, 0} = run_bash("mix compile", context)
    assert output =~ "aiur_build_gate stale_owner_recovered slot=1 owner_pid=999999999"
    assert File.read!(context.log_path) == "compile\n"
  end

  test "defers below the memory floor and resumes after MemAvailable recovers", context do
    write_meminfo!(context, 1_024)

    command =
      Task.async(fn ->
        run_bash(
          "mix compile",
          Map.merge(context, %{min_free_memory_mb: 2_048, timeout_seconds: 5})
        )
      end)

    assert Task.yield(command, 250) == nil
    refute File.exists?(context.started_path)

    write_meminfo!(context, 3_072)

    assert {output, 0} = Task.await(command, 5_000)
    assert output =~ "aiur_perf memory_hold surface=build available_mb=1024 threshold_mb=2048"
    assert File.read!(context.log_path) == "compile\n"
  end

  test "admits a build at the exact memory floor", context do
    write_meminfo!(context, 2_048)

    assert {output, 0} =
             run_bash("mix compile", Map.put(context, :min_free_memory_mb, 2_048))

    refute output =~ "aiur_perf memory_hold"
    assert File.read!(context.log_path) == "compile\n"
  end

  test "memory-only mode remains active when build-slot capacity is zero", context do
    write_meminfo!(context, 512)

    assert {output, 124} =
             run_bash(
               "mix compile",
               Map.merge(context, %{
                 slots: 0,
                 min_free_memory_mb: 1_024,
                 timeout_seconds: 0
               })
             )

    assert output =~ "aiur_perf memory_hold surface=build available_mb=512 threshold_mb=1024"
    refute File.exists?(context.log_path)
  end

  test "fails open when MemAvailable cannot be read", context do
    missing = Path.join(context.gate_dir, "missing-meminfo")

    assert {output, 0} =
             run_bash(
               "mix compile",
               Map.merge(context, %{
                 meminfo_path: missing,
                 min_free_memory_mb: 2_048
               })
             )

    assert output =~ "aiur_perf memory_unavailable surface=build action=fail_open"
    assert File.read!(context.log_path) == "compile\n"
  end

  defp run_bash(command, %{bin_dir: bin_dir, gate_dir: gate_dir, log_path: log_path} = context) do
    env = [
      {"BASH_ENV", BuildGate.hook_path()},
      {"AIUR_BUILD_GATE_DIR", gate_dir},
      {"AIUR_BUILD_GATE_SLOTS", Integer.to_string(Map.get(context, :slots, 1))},
      {"AIUR_BUILD_GATE_TIMEOUT_SECONDS", Integer.to_string(Map.get(context, :timeout_seconds, 5))},
      {"AIUR_MIN_FREE_MEMORY_MB", Integer.to_string(Map.get(context, :min_free_memory_mb, 0))},
      {"AIUR_MEMINFO_PATH", Map.get(context, :meminfo_path, Path.join(gate_dir, "meminfo"))},
      {"FAKE_MIX_LOG", log_path},
      {"FAKE_MIX_STARTED", Map.get(context, :started_path, "")},
      {"FAKE_MIX_SLEEP", Integer.to_string(Map.get(context, :sleep_seconds, 0))},
      {"PATH", bin_dir <> ":" <> System.get_env("PATH", "")}
    ]

    System.cmd("bash", ["-c", command], env: env, stderr_to_stdout: true)
  end

  defp wait_for_file!(path, attempts \\ 50)

  defp wait_for_file!(path, attempts) when attempts > 0 do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(20)
      wait_for_file!(path, attempts - 1)
    end
  end

  defp wait_for_file!(path, 0), do: flunk("timed out waiting for #{path}")

  defp write_meminfo!(context, available_mb) do
    path = Map.get(context, :meminfo_path, Path.join(context.gate_dir, "meminfo"))
    File.write!(path, "MemAvailable: #{available_mb * 1_024} kB\n")
  end

  defp write_fake_mix!(path) do
    File.write!(path, """
    #!/usr/bin/env bash
    printf '%s\\n' "$*" >> "$FAKE_MIX_LOG"
    if [[ -n ${FAKE_MIX_STARTED:-} ]]; then
      : > "$FAKE_MIX_STARTED"
    fi
    sleep "${FAKE_MIX_SLEEP:-0}"
    """)

    File.chmod!(path, 0o755)
  end

  defp write_fake_mise!(path) do
    File.write!(path, """
    #!/usr/bin/env bash
    if [[ $1 == exec && $2 == -- ]]; then
      shift 2
      exec "$@"
    fi
    exit 64
    """)

    File.chmod!(path, 0o755)
  end
end
