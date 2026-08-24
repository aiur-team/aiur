defmodule Aiur.BuildGateTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentBuildGuard, BuildGate, PauseContainment}

  @linux_build_gate match?({:unix, :linux}, :os.type()) and
                      not is_nil(System.find_executable("flock"))
  @linux_only if(@linux_build_gate,
                do: [linux_lock: true],
                else: [skip: "requires Linux flock leases"]
              )

  setup do
    gate_id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    gate_dir = Path.join(System.tmp_dir!(), "aiur-build-gate-#{gate_id}")
    lock_dir = BuildGate.lock_dir(gate_dir)
    bin_dir = Path.join(gate_dir, "bin")
    log_path = Path.join(gate_dir, "mix.log")
    started_path = Path.join(gate_dir, "mix.started")
    timing_log_path = Path.join(gate_dir, "mix.timing.log")
    concurrency_path = Path.join(gate_dir, "mix.concurrency")
    max_concurrency_path = Path.join(gate_dir, "mix.max-concurrency")
    descendant_path = Path.join(gate_dir, "mix.descendant")
    descendant_release_path = Path.join(gate_dir, "mix.descendant.release")
    mix_pid_path = Path.join(gate_dir, "mix.pid")
    real_mix_project = Path.join(gate_dir, "real-mix-project")

    assert {:ok, _canonical_gate_dir} =
             BuildGate.prepare_writable_root(gate_dir: gate_dir, lock_dir: lock_dir, slots: 4)

    File.mkdir_p!(bin_dir)
    write_fake_mix!(Path.join(bin_dir, "mix"))
    write_fake_mise!(Path.join(bin_dir, "mise"))
    write_real_mix_project!(real_mix_project)

    on_exit(fn ->
      File.chmod(lock_dir, 0o755)
      File.rm_rf!(gate_dir)
      File.rm_rf!(lock_dir)
    end)

    %{
      bin_dir: bin_dir,
      gate_dir: gate_dir,
      lock_dir: lock_dir,
      log_path: log_path,
      started_path: started_path,
      timing_log_path: timing_log_path,
      concurrency_path: concurrency_path,
      max_concurrency_path: max_concurrency_path,
      descendant_path: descendant_path,
      descendant_release_path: descendant_release_path,
      mix_pid_path: mix_pid_path,
      real_mix_project: real_mix_project
    }
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

  test "does not inject a shell hook when operators opt out", context do
    assert BuildGate.shell_env(slots: 0, stagger_seconds: 0, min_free_memory_mb: nil) == []

    env =
      BuildGate.shell_env(
        slots: 3,
        stagger_seconds: 7,
        min_free_memory_mb: 4_096,
        gate_dir: context.gate_dir,
        hook_path: "/tmp/hook"
      )

    assert {"AIUR_BUILD_GATE_SLOTS", "3"} in env
    assert {"AIUR_BUILD_GATE_LOCK_DIR", context.lock_dir} in env
    assert {"AIUR_BUILD_START_STAGGER_SECONDS", "7"} in env
    assert {"AIUR_MIN_FREE_MEMORY_MB", "4096"} in env

    assert {"BASH_ENV", "/tmp/hook"} in BuildGate.shell_env(
             slots: 0,
             stagger_seconds: 0,
             min_free_memory_mb: 4_096,
             gate_dir: context.gate_dir,
             hook_path: "/tmp/hook"
           )

    assert {"BASH_ENV", "/tmp/hook"} in BuildGate.shell_env(
             slots: 0,
             stagger_seconds: 5,
             min_free_memory_mb: nil,
             gate_dir: context.gate_dir,
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

  test "strips --trace when --max-cases N (N>1) would otherwise silently serialize", context do
    assert {output, 0} = run_bash("mix test --max-cases 4 --trace", context)
    assert output =~ "aiur_build_gate trace_stripped"
    assert File.read!(context.log_path) == "test --max-cases 4\n"
  end

  test "strips --trace with the --max-cases=N form and leaves non-conflicting flags alone", context do
    assert {output, 0} = run_bash("mix test --max-cases=4 --trace", context)
    assert output =~ "aiur_build_gate trace_stripped"
    assert File.read!(context.log_path) == "test --max-cases=4\n"

    for command <- [
          "mix test --max-cases 4",
          "mix test --trace",
          "mix test --max-cases 1 --trace"
        ] do
      assert {command_output, 0} = run_bash(command, context)
      refute command_output =~ "aiur_build_gate trace_stripped"
    end

    assert File.read!(context.log_path) ==
             "test --max-cases=4\ntest --max-cases 4\ntest --trace\ntest --max-cases 1 --trace\n"
  end

  test "normalizes a mise exec -- mix command combining --trace with --max-cases", context do
    guarded_context = with_command_wrappers!(context)

    assert {output, 0} = run_sh("mise exec -- mix test --max-cases 4 --trace", guarded_context)
    assert output =~ "aiur_build_gate trace_stripped"
    assert File.read!(context.log_path) == "test --max-cases 4\n"
  end

  test "normalizes an elixir -S mix command combining --trace with --max-cases", context do
    elixir_bin = Path.join(context.gate_dir, "elixir-bin")
    File.mkdir_p!(elixir_bin)
    write_fake_elixir_mix!(Path.join(elixir_bin, "mix"))

    guarded_context =
      context
      |> with_command_wrappers!()
      |> Map.merge(%{
        bin_dir: elixir_bin,
        system_path: system_path_without_build_wrapper()
      })

    assert {output, 0} = run_sh("elixir -S mix test --max-cases 4 --trace", guarded_context)
    assert output =~ "aiur_build_gate trace_stripped"

    assert context.log_path |> File.read!() |> String.split("\n", trim: true) |> List.last() ==
             "test --max-cases 4"
  end

  test "a non-mix elixir eval passes through the gate with its arguments intact", context do
    assert {output, 0} = run_bash(~s|elixir -e 'IO.puts("ok")'|, context)
    assert output =~ "ok"
    refute File.exists?(context.log_path)
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

  test "parallel Mix commands from a non-Bash shell never exceed the configured capacity", context do
    File.write!(context.concurrency_path, "0\n")
    File.write!(context.max_concurrency_path, "0\n")

    guarded_context =
      context
      |> with_command_wrappers!()
      |> Map.merge(%{
        slots: 2,
        sleep_seconds: 1,
        started_path: "",
        track_concurrency: true
      })

    results =
      1..4
      |> Enum.map(fn index ->
        Task.async(fn -> run_sh("mix test --partition #{index}", guarded_context) end)
      end)
      |> Task.await_many(8_000)

    assert Enum.all?(results, &match?({_output, 0}, &1))
    assert context.max_concurrency_path |> File.read!() |> String.trim() == "2"
  end

  test "a non-Bash mise wrapper holds only one slot for its nested Mix command", context do
    for strategy <- ["auto", "pid"] do
      assert {output, 0} =
               context
               |> with_command_wrappers!()
               |> Map.put(:lease_strategy, strategy)
               |> then(&run_sh("mise exec -- mix test", &1))

      assert length(Regex.scan(~r/aiur_build_gate acquired/, output)) == 1
    end

    assert File.read!(context.log_path) == "test\ntest\n"
  end

  test "an unlimited gate admits a nested mise command only once", context do
    assert {output, 0} =
             context
             |> with_command_wrappers!()
             |> Map.put(:slots, 0)
             |> then(&run_sh("mise exec -- mix test", &1))

    assert length(Regex.scan(~r/aiur_build_gate queued/, output)) == 1
    assert length(Regex.scan(~r/aiur_build_gate completed/, output)) == 1
    assert File.read!(context.log_path) == "test\n"
  end

  test "non-Bash command wrappers gate every supported Mix build form", context do
    guarded_context = with_command_wrappers!(context)

    for {command, phase} <- [
          {"mix compile", "compile"},
          {"mix test", "test"},
          {"mix do compile + test", "compile"},
          {"mix do format + test", "test"},
          {"mix do --app demo compile --list, test", "compile"},
          {"mise exec -- mix compile", "compile"},
          {"mise x -- mix test", "test"},
          {"mise exec -- #{Path.join(context.bin_dir, "mix")} test", "test"},
          {"mise exec -c 'mix test'", "test"}
        ] do
      assert {output, 0} = run_sh(command, guarded_context)
      assert length(Regex.scan(~r/aiur_build_gate acquired/, output)) == 1

      assert context.log_path |> File.read!() |> String.split("\n", trim: true) |> List.last() =~
               phase
    end
  end

  test "compound non-build Mix commands remain ungated", context do
    context = with_command_wrappers!(context)

    assert {output, 0} = run_sh("mix do format + help", context)
    refute output =~ "aiur_build_gate"

    assert {argument_output, 0} = run_sh("mix do help compile", context)
    refute argument_output =~ "aiur_build_gate"
    assert File.read!(context.log_path) == "do format + help\ndo help compile\n"
  end

  test "real mise command strings acquire one lease for the whole Mix build", context do
    real_mise = real_executable_behind_wrapper!("mise")
    real_bin = Path.join(context.gate_dir, "real-mise-bin")
    File.mkdir_p!(real_bin)
    File.cp!(Path.join(context.bin_dir, "mix"), Path.join(real_bin, "mix"))

    guarded_context =
      context
      |> with_command_wrappers!()
      |> Map.merge(%{
        bin_dir: real_bin,
        system_path: Path.dirname(real_mise) <> ":/usr/bin:/bin",
        extra_env: [{"MISE_CONFIG_FILE", "/dev/null"}],
        lease_strategy: "pid"
      })

    fake_mix = Path.join(real_bin, "mix")
    capture_path = Path.join(context.gate_dir, "real-mise.output")

    for command <- [
          "mise exec -C / -c '#{fake_mix} test'",
          "mise x -C / --command '#{fake_mix} do compile + test'"
        ] do
      assert {_shell_output, 0} =
               run_sh("#{command} > '#{capture_path}' 2>&1", guarded_context)

      output = File.read!(capture_path)
      assert length(Regex.scan(~r/aiur_build_gate acquired/, output)) == 1
    end

    assert File.read!(context.log_path) == "test\ndo compile + test\n"
  end

  test "ambiguous mise command strings fail closed instead of bypassing admission", context do
    guarded_context = with_command_wrappers!(context)

    for command <- [
          "mise exec -c 'printf ready && mix test'",
          "mise exec -c 'mix test' extra",
          "mise exec -c 'mix test' -- mix compile"
        ] do
      assert {output, 125} = run_sh(command, guarded_context)
      assert output =~ "gate_error reason=ambiguous_command"
    end

    refute File.exists?(context.log_path)
  end

  test "unsupported mise prefixes before Mix fail closed", context do
    fake_mix = Path.join(context.bin_dir, "mix")

    for command <- [
          "mise exec -- env DEMO=1 #{fake_mix} test",
          "mise exec env DEMO=1 mix test",
          "mise exec -c 'env DEMO=1 #{fake_mix} test'"
        ] do
      assert {output, 125} = run_sh(command, with_command_wrappers!(context))
      assert output =~ "gate_error reason=ambiguous_command"
    end

    refute File.exists?(context.log_path)
  end

  test "mise command strings with expansion fail closed before hidden Mix can run", context do
    guarded_context =
      Map.put(context, :extra_env, [{"HIDDEN_MIX", Path.join(context.bin_dir, "mix")}])

    assert {output, 125} =
             run_sh("mise exec -c '$HIDDEN_MIX test'", with_command_wrappers!(guarded_context))

    assert output =~ "gate_error reason=ambiguous_command"
    refute File.exists?(context.log_path)
  end

  test "errexit preserves non-build Mix elixir and mise commands", context do
    assert {output, 0} =
             run_bash(
               "set -e; mix format; mise exec -- mix format; elixir -e ':ok'; printf survived",
               context
             )

    assert output =~ "survived"
    refute output =~ "aiur_build_gate acquired"
    assert File.read!(context.log_path) == "format\nformat\n"
  end

  test "simple non-build mise command strings remain ungated", context do
    assert {output, 0} = run_bash("mise exec -c 'printf ready'", context)
    assert output =~ "ready"
    refute output =~ "aiur_build_gate"
    refute File.exists?(context.log_path)

    assert {argument_output, 0} =
             run_sh("mise exec -- printf '%s' mix", with_command_wrappers!(context))

    assert argument_output =~ "mix"
    refute argument_output =~ "aiur_build_gate"
  end

  test "malformed compound Mix grammar fails closed", context do
    guarded_context = with_command_wrappers!(context)

    for command <- ["mix do", "mix do compile +", "mix do --app compile"] do
      assert {output, 125} = run_sh(command, guarded_context)
      assert output =~ "gate_error reason=ambiguous_command"
    end

    refute File.exists?(context.log_path)
  end

  test "wrapper aliases resolve past themselves without recursion", context do
    guarded_context = with_command_wrappers!(context)
    alias_bin = Path.join(context.gate_dir, "alias-bin")
    File.mkdir_p!(alias_bin)
    File.ln_s!(Path.join(guarded_context.wrapper_bin, "mix"), Path.join(alias_bin, "mix"))

    aliased_context =
      Map.merge(guarded_context, %{
        bin_dir: alias_bin,
        system_path: context.bin_dir <> ":" <> System.get_env("PATH", "")
      })

    assert {output, 0} = run_sh("mix test", aliased_context)
    assert length(Regex.scan(~r/aiur_build_gate acquired/, output)) == 1

    assert {absolute_output, 0} =
             run_sh("#{guarded_context.wrapper_bin}/mix compile", aliased_context)

    assert length(Regex.scan(~r/aiur_build_gate acquired/, absolute_output)) == 1
    assert File.read!(context.log_path) == "test\ncompile\n"
  end

  test "mismatched inherited lease tokens reacquire instead of bypassing", context do
    stale_path = Path.join(context.gate_dir, "stale-lease")
    File.write!(stale_path, "version=2\ntoken=current\n")

    guarded_context =
      context
      |> with_command_wrappers!()
      |> Map.put(:extra_env, [
        {"AIUR_BUILD_GATE_LEASE_PATH", stale_path},
        {"AIUR_BUILD_GATE_LEASE_TOKEN", "stale"}
      ])

    assert {output, 0} = run_sh("mix test", guarded_context)
    assert output =~ "aiur_build_gate acquired"
    assert File.read!(context.log_path) == "test\n"
  end

  test "invalid inherited lease metadata fails closed", context do
    guarded_context =
      context
      |> with_command_wrappers!()
      |> Map.put(:extra_env, [
        {"AIUR_BUILD_GATE_LEASE_PATH", Path.join(context.gate_dir, "nested/lease")},
        {"AIUR_BUILD_GATE_LEASE_TOKEN", "token"}
      ])

    assert {output, 125} = run_sh("mix test", guarded_context)
    assert output =~ "gate_error reason=lease_marker_invalid"
    refute File.exists?(context.log_path)
  end

  test "the Bash hook resolves the real Mix command behind the installed wrapper", context do
    assert {output, 0} =
             context
             |> with_command_wrappers!()
             |> then(&run_bash("mix compile", &1))

    assert length(Regex.scan(~r/aiur_build_gate acquired/, output)) == 1
    assert File.read!(context.log_path) == "compile\n"
  end

  test "the lightweight wrapper bypasses the Bash hook for non-build commands", context do
    context =
      context
      |> with_command_wrappers!()
      |> Map.put(:bash_env, Path.join(context.gate_dir, "missing-hook"))

    assert {_output, 0} = run_sh("mix format", context)
    assert {_output, 0} = run_sh("mise exec -- mix format", context)
    assert {output, 125} = run_sh("mix test", context)
    assert output =~ "gate_error reason=hook_unavailable"
    assert File.read!(context.log_path) == "format\nformat\n"
  end

  test "the command wrapper fails closed when a readable hook omits the gate function", context do
    empty_hook = Path.join(context.gate_dir, "empty-hook")
    File.write!(empty_hook, "")

    context =
      context
      |> with_command_wrappers!()
      |> Map.put(:bash_env, empty_hook)

    assert {output, 125} = run_sh("mix test", context)
    assert output =~ "gate_error reason=hook_unavailable command=mix status=125"
    refute File.exists?(context.log_path)
  end

  test "the Bash hook reports a missing wrapped command without re-entering the wrapper", context do
    empty_bin = Path.join(context.gate_dir, "empty-bin")
    File.mkdir_p!(empty_bin)

    missing_command_context =
      context
      |> with_command_wrappers!()
      |> Map.merge(%{bin_dir: empty_bin, system_path: "/usr/bin:/bin"})

    assert {output, 127} = run_sh("timeout --kill-after=1 2 mix test", missing_command_context)
    assert output =~ "gate_error reason=command_unavailable command=mix status=127"
  end

  test "elixir -S mix commands resolve the real Mix script and gate build work", context do
    elixir_bin = Path.join(context.gate_dir, "elixir-bin")
    File.mkdir_p!(elixir_bin)
    write_fake_elixir_mix!(Path.join(elixir_bin, "mix"))

    guarded_context =
      context
      |> with_command_wrappers!()
      |> Map.merge(%{
        bin_dir: elixir_bin,
        system_path: system_path_without_build_wrapper()
      })

    for {command, phase} <- [
          {"elixir -S mix compile", "compile"},
          {"elixir -S mix test", "test"},
          {"elixir -S mix do test + format", "do test + format"}
        ] do
      assert {gated_output, 0} = run_sh(command, guarded_context)
      assert gated_output =~ "aiur_build_gate acquired slot=1"
      assert context.log_path |> File.read!() |> String.split("\n", trim: true) |> List.last() == phase
    end

    assert {ungated_output, 0} = run_sh("elixir -S mix format", guarded_context)
    refute ungated_output =~ "aiur_build_gate acquired"
    assert File.read!(context.log_path) == "compile\ntest\ndo test + format\nformat\n"
  end

  test "elixir data arguments that resemble Mix commands do not enter the gate", context do
    context =
      context
      |> with_command_wrappers!()
      |> Map.put(:system_path, system_path_without_build_wrapper())
      |> Map.put(:bash_env, Path.join(context.gate_dir, "missing-hook"))

    assert {"ok\n", 0} = run_sh(~s|elixir -e 'IO.puts("ok")' -- -S mix test|, context)
  end

  @tag @linux_only
  test "identical namespace-local PIDs publish distinct live leases", context do
    shared_pid_context =
      Map.merge(context, %{
        diagnostic_pid: 2,
        diagnostic_pgid: 1,
        sleep_seconds: 2
      })

    first = Task.async(fn -> run_bash("mix test", shared_pid_context) end)
    wait_for_file!(context.started_path)
    wait_for_file!(Path.join(context.gate_dir, "slot-1.owner"))

    second =
      Task.async(fn ->
        run_bash(
          "mix compile",
          %{shared_pid_context | started_path: "", sleep_seconds: 0}
        )
      end)

    [queue_file] = wait_for_wildcard!(Path.join(context.gate_dir, "queue/lease-v2-*"))
    assert File.read!(Path.join(context.gate_dir, "slot-1.owner")) =~ "pid=2\n"
    assert File.read!(queue_file) =~ "pid=2\n"
    assert %{active: 1, queued: 1} = build_gate_status(gate_dir: context.gate_dir, capacity: 1)
    assert Task.yield(second, 100) == nil

    assert {_output, 0} = Task.await(first, 5_000)
    assert {_output, 0} = Task.await(second, 5_000)
    assert File.read!(context.log_path) == "test\ncompile\n"
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

    assert_receive {^holder, {:data, "ready\n"}}, 2_000

    on_exit(fn ->
      File.touch!(release_path)
      if Port.info(holder), do: Port.close(holder)
    end)

    started_ms = System.monotonic_time(:millisecond)
    status = build_gate_status(gate_dir: context.gate_dir, capacity: 2, strategy: :linux_lock)
    elapsed_ms = System.monotonic_time(:millisecond) - started_ms

    assert %{active: 2, queued: 8, oldest_wait_seconds: wait, degraded?: nil} = Map.put_new(status, :degraded?, nil)
    assert wait >= 79
    assert elapsed_ms < 5_000
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
    holder_path = Path.expand("../../priv/build_gate_holder.py", __DIR__)
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

  test "the PID fallback remains safe when the invoking shell enables nounset", context do
    assert {_output, 0} =
             run_bash(
               "set -u; mix compile",
               Map.merge(context, %{slots: 2, stagger_seconds: 1, lease_strategy: "pid"})
             )

    assert File.read!(context.log_path) == "compile\n"
  end

  test "a PID-fallback descendant cannot reuse a released parent lease", context do
    release_descendant_on_exit(context)
    descendant_gate_log = Path.join(context.gate_dir, "descendant-gate.log")

    descendant_context =
      Map.merge(context, %{
        descendant_release_barrier: true,
        descendant_command: "mix compile",
        descendant_gate_log: descendant_gate_log,
        lease_strategy: "pid",
        started_path: ""
      })

    assert {_output, 0} = run_bash("mix test", descendant_context)
    wait_for_file!(context.descendant_path)
    File.touch!(context.descendant_release_path)
    wait_for_file!(context.descendant_path <> ".done")

    descendant_output = descendant_gate_log |> File.read!() |> String.replace(<<0>>, "")
    assert descendant_output =~ "aiur_build_gate acquired"
    assert descendant_output =~ "command=compile"
    assert File.read!(context.log_path) == "test\ncompile\n"
  end

  test "automatic strategy fails closed when platform detection fails", context do
    assert {output, 125} =
             run_bash(
               "uname() { return 1; }; mix compile",
               Map.put(context, :started_path, "")
             )

    assert output =~ "aiur_build_gate gate_error reason=platform_detection_failed"
    refute File.exists?(context.log_path)
    assert Path.wildcard(Path.join(context.gate_dir, "queue/*")) == []
  end

  test "automatic strategy retains the explicit PID fallback on Darwin", context do
    assert {output, 0} =
             run_bash(
               ~S|uname() { printf 'Darwin\n'; }; mix compile|,
               Map.put(context, :started_path, "")
             )

    assert output =~ "aiur_build_gate acquired slot=1"
    assert File.read!(context.log_path) == "compile\n"
    refute File.exists?(Path.join(context.gate_dir, "locks/slot-1.lock"))
  end

  test "Darwin phase pacing does not require Python", context do
    File.write!(Path.join(context.gate_dir, "phase-next-start"), "0\n")

    command = ~S"""
    type() {
      if [[ ${1:-} == -P && ${2:-} == python3 ]]; then
        return 1
      fi

      builtin type "$@"
    }
    uname() { printf 'Darwin\n'; }
    mix compile
    """

    assert {output, 0} =
             run_bash(
               command,
               Map.merge(context, %{stagger_seconds: 1, started_path: ""})
             )

    assert output =~ "aiur_build_gate acquired slot=1"
    assert File.read!(context.log_path) == "compile\n"
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
    holder_path = Path.expand("../../priv/build_gate_holder.py", __DIR__)
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

  test "preflight reports a real read-only Linux gate root" do
    if match?({:unix, :linux}, :os.type()) and File.dir?("/sys/kernel") do
      gate_dir = Path.join("/sys/kernel", "aiur-build-gate-#{System.unique_integer([:positive])}")

      assert {:error, {:build_gate_unavailable, details}} =
               BuildGate.prepare_writable_root(gate_dir: gate_dir, slots: 2)

      assert %{operation: :create_directory, path: ^gate_dir, reason: reason, recovery: recovery} = details

      assert reason in [:eacces, :eperm, :erofs]
      assert recovery =~ "repair"
    end
  end

  test "preflight rejects a lock namespace overlapping any effective writable root", context do
    writable_root = Path.dirname(context.gate_dir)
    assert {:ok, canonical_root} = Aiur.PathSafety.canonicalize(writable_root)

    assert {:error, {:build_gate_unavailable, details}} =
             BuildGate.prepare_writable_root(
               gate_dir: context.gate_dir,
               lock_dir: context.lock_dir,
               writable_roots: [writable_root],
               slots: 2
             )

    assert %{
             operation: :separate_lock_namespace,
             path: lock_dir,
             reason: {:overlaps_writable_root, ^canonical_root}
           } = details

    assert lock_dir == context.lock_dir
  end

  test "preflight succeeds with one unresolvable and one valid writable root, warning about the bad one",
       context do
    # Create a mode-000 directory; PathSafety.canonicalize fails with :eacces on
    # any child of it. Use gate_dir as the valid root (no overlap with lock_dir).
    restricted = Path.join(System.tmp_dir!(), "aiur-restricted-#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}")
    File.mkdir!(restricted)
    File.chmod!(restricted, 0o000)

    on_exit(fn ->
      File.chmod(restricted, 0o700)
      File.rm_rf(restricted)
    end)

    valid_root = context.gate_dir
    bad_root = Path.join(restricted, "subpath")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _canonical_gate_dir} =
                 BuildGate.prepare_writable_root(
                   gate_dir: context.gate_dir,
                   lock_dir: context.lock_dir,
                   writable_roots: [bad_root, valid_root],
                   slots: 2
                 )
      end)

    assert log =~ "build_gate skipped_unresolvable_writable_root"
    assert log =~ bad_root
  end

  test "preflight fails when all writable roots are unresolvable", context do
    # Create a mode-000 directory so PathSafety.canonicalize fails with :eacces
    # on any path rooted inside it.
    restricted = Path.join(System.tmp_dir!(), "aiur-restricted-#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}")
    File.mkdir!(restricted)
    File.chmod!(restricted, 0o000)

    on_exit(fn ->
      File.chmod(restricted, 0o700)
      File.rm_rf(restricted)
    end)

    bad_root_a = Path.join(restricted, "a")
    bad_root_b = Path.join(restricted, "b")

    assert {:error, {:build_gate_unavailable, details}} =
             BuildGate.prepare_writable_root(
               gate_dir: context.gate_dir,
               lock_dir: context.lock_dir,
               writable_roots: [bad_root_a, bad_root_b],
               slots: 2
             )

    assert %{operation: :canonicalize_writable_root} = details
  end

  test "preflight rejects a lock namespace overlapping an effective writable root, even with unresolvable roots in the list",
       context do
    # Create a mode-000 directory so one root genuinely fails canonicalization.
    restricted = Path.join(System.tmp_dir!(), "aiur-restricted-#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}")
    File.mkdir!(restricted)
    File.chmod!(restricted, 0o000)

    on_exit(fn ->
      File.chmod(restricted, 0o700)
      File.rm_rf(restricted)
    end)

    # valid_root is /tmp — it overlaps the lock_dir which lives under /tmp.
    valid_root = Path.dirname(context.gate_dir)
    bad_root = Path.join(restricted, "subpath")
    assert {:ok, canonical_root} = Aiur.PathSafety.canonicalize(valid_root)

    assert {:error, {:build_gate_unavailable, details}} =
             BuildGate.prepare_writable_root(
               gate_dir: context.gate_dir,
               lock_dir: context.lock_dir,
               writable_roots: [bad_root, valid_root],
               slots: 2
             )

    assert %{
             operation: :separate_lock_namespace,
             path: lock_dir,
             reason: {:overlaps_writable_root, ^canonical_root}
           } = details

    assert lock_dir == context.lock_dir
  end

  test "an unavailable gate directory fails closed without running Mix", context do
    invalid_gate_dir = Path.join(context.gate_dir, "not-a-directory")
    File.write!(invalid_gate_dir, "regular file")

    Enum.each(["auto", "pid"], fn strategy ->
      assert {output, 125} =
               run_bash(
                 "mix compile",
                 Map.merge(context, %{
                   gate_dir: invalid_gate_dir,
                   lease_strategy: strategy,
                   started_path: ""
                 })
               )

      assert output =~ "aiur_build_gate gate_error reason=directory_unavailable"
      assert output =~ "recovery=repair_gate_or_disable_all_build_admission"
      assert output =~ "build_start_stagger_seconds_0"
      assert output =~ "min_free_memory_mb_unset"
    end)

    refute File.exists?(context.log_path)
  end

  test "missing Linux flock support fails closed without running Mix", context do
    command = ~S"""
    type() {
      if [[ ${1:-} == -P && ${2:-} == flock ]]; then
        return 1
      fi

      builtin type "$@"
    }

    mix compile
    """

    assert {output, 125} =
             run_bash(
               command,
               Map.merge(context, %{lease_strategy: "linux", started_path: ""})
             )

    assert output =~ "aiur_build_gate gate_error reason=flock_unavailable"
    assert output =~ "recovery=repair_gate_or_disable_all_build_admission"
    refute File.exists?(context.log_path)
  end

  @tag @linux_only
  test "missing Linux subreaper runtime fails closed without running Mix", context do
    command = ~S"""
    type() {
      if [[ ${1:-} == -P && ${2:-} == python3 ]]; then
        return 1
      fi

      builtin type "$@"
    }

    mix compile
    """

    assert {output, 125} =
             run_bash(
               command,
               Map.merge(context, %{lease_strategy: "linux", started_path: ""})
             )

    assert output =~ "aiur_build_gate gate_error reason=lease_holder_runtime_unavailable"
    refute File.exists?(context.log_path)
  end

  @tag @linux_only
  test "publishes a complete numbered-slot owner record atomically", context do
    command = Task.async(fn -> run_bash("mix test", Map.put(context, :sleep_seconds, 2)) end)
    wait_for_file!(context.started_path)

    slot_path = Path.join(context.lock_dir, "slot-1.lock")
    owner_path = Path.join(context.gate_dir, "slot-1.owner")
    assert File.regular?(slot_path)
    assert File.regular?(owner_path)
    wait_for_file_contents!(owner_path, ~r/command_pgid=[1-9][0-9]*/)

    owner_pattern =
      ~r/^version=2\n
      token=.+\n
      pid=[1-9][0-9]*\n
      pgid=[0-9]+\n
      holder_pid=[1-9][0-9]*\n
      command_pgid=[1-9][0-9]*\n
      phase=test\n
      command=test\n
      started_at=[0-9]+\n$/x

    assert File.read!(owner_path) =~ owner_pattern

    assert {_output, 0} = Task.await(command, 5_000)
    assert File.exists?(slot_path)
    refute File.exists?(owner_path)
  end

  @tag @linux_only
  test "rejects a directory-shaped numbered-slot owner destination", context do
    owner_path = Path.join(context.gate_dir, "slot-1.owner")
    File.mkdir_p!(owner_path)

    assert {output, 125} = run_bash("mix compile", Map.put(context, :started_path, ""))

    assert output =~ "aiur_build_gate gate_error reason=owner_destination_invalid"
    assert File.dir?(owner_path)
    assert File.ls!(owner_path) == []
    refute File.exists?(context.log_path)
    assert Path.wildcard(Path.join(context.gate_dir, ".owner-v2.*")) == []
    assert Path.wildcard(Path.join(context.gate_dir, "queue/lease-v2-*")) == []
  end

  test "times out without running Mix while every slot has a live owner", context do
    slot_path = Path.join(context.gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    File.write!(Path.join(slot_path, "owner"), "pid=#{System.pid()}\n")

    assert {output, 124} =
             run_bash(
               "mix compile",
               Map.merge(context, %{timeout_seconds: 0, lease_strategy: "pid"})
             )

    assert output =~ "aiur_build_gate timeout"
    refute File.exists?(context.log_path)
  end

  test "reclaims a stale owner before running a later verification command", context do
    slot_path = Path.join(context.gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    File.write!(Path.join(slot_path, "owner"), "pid=999999999\n")

    assert {output, 0} = run_bash("mix compile", Map.put(context, :lease_strategy, "pid"))
    assert output =~ "aiur_build_gate stale_owner_recovered slot=1 owner_pid=999999999"
    assert File.read!(context.log_path) == "compile\n"
  end

  test "reclaims an interrupted numbered-slot owner publication", context do
    slot_path = Path.join(context.gate_dir, "slot-1")
    File.mkdir_p!(slot_path)
    File.write!(Path.join(slot_path, "owner"), "pid=")

    assert {output, 0} = run_bash("mix compile", Map.put(context, :lease_strategy, "pid"))
    assert output =~ "aiur_build_gate stale_owner_recovered slot=1 owner_pid=unknown"
    assert File.read!(context.log_path) == "compile\n"
  end

  test "keeps a slot while a dead owner's process group still has a child", context do
    command = """
    setsid bash -c 'sleep 2 &' &
    owner_pid=$!
    wait "$owner_pid"
    printf 'pid=%s\npgid=%s\ncommand=test\n' "$owner_pid" "$owner_pid" > "#{context.gate_dir}/slot-1"
    mix compile
    """

    assert {output, 124} =
             run_bash(
               command,
               Map.merge(context, %{timeout_seconds: 0, lease_strategy: "pid"})
             )

    assert output =~ "aiur_build_gate timeout"
    refute output =~ "stale_owner_recovered"
    refute File.exists?(context.log_path)
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

  defp run_bash(command, context) do
    System.cmd("bash", ["-c", command], env: build_gate_env(context), stderr_to_stdout: true)
  end

  # Runs a gated command through the real Config -> BuildGate.shell_env
  # plumbing (not the test's hand-built build_gate_env), so a config-derived
  # value like the retain window is proven to reach and be honoured by the
  # detached holder rather than merely appearing in a log line (#2398).
  defp run_bash_with_shell_env(command, context, shell_opts) do
    shell_env =
      BuildGate.shell_env(
        Keyword.merge(
          [slots: 1, stagger_seconds: 0, min_free_memory_mb: 0, gate_dir: context.gate_dir],
          shell_opts
        )
      )

    provided = shell_env |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    test_env = Enum.reject(build_gate_env(context), fn {name, _value} -> MapSet.member?(provided, name) end)
    System.cmd("bash", ["-c", command], env: shell_env ++ test_env, stderr_to_stdout: true)
  end

  # sum_exec_runtime (ns) for a PID, the same scheduler runtime the holder
  # reads to gate the retain window. Used to prove an adopted-daemon fixture
  # genuinely consumes CPU (nonzero) so its release pins the idle threshold's
  # lower bound rather than passing vacuously (#2398).
  defp cpu_ns_from_schedstat(pid) do
    path = "/proc/#{pid}/schedstat"

    case File.read(path) do
      {:ok, contents} ->
        contents |> String.split() |> List.first() |> String.to_integer()

      {:error, reason} ->
        flunk("schedstat is required for the CPU-gated retain tests: #{path} (#{reason})")
    end
  end

  defp real_executable_behind_wrapper!(command) do
    wrapper = Path.join(System.get_env("AIUR_BUILD_GATE_BIN", ""), command)
    wrapper_stat = File.stat(wrapper)

    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, command))
    |> Enum.find(fn candidate ->
      case {File.stat(candidate), wrapper_stat} do
        {{:ok, %{type: :regular} = candidate_stat}, {:ok, wrapper_stat}} ->
          {candidate_stat.major_device, candidate_stat.inode} !=
            {wrapper_stat.major_device, wrapper_stat.inode}

        {{:ok, %{type: :regular}}, _} ->
          candidate != wrapper

        _ ->
          false
      end
    end)
    |> case do
      nil -> flunk("#{command} is required behind the installed build-gate wrapper")
      executable -> executable
    end
  end

  defp system_path_without_build_wrapper do
    wrapper_bin = System.get_env("AIUR_BUILD_GATE_BIN", "")

    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.reject(&(&1 == wrapper_bin))
    |> Enum.join(":")
  end

  defp run_sh(command, context) do
    System.cmd("sh", ["-c", command], env: build_gate_env(context), stderr_to_stdout: true)
  end

  defp with_command_wrappers!(context) do
    workspace = Path.join(context.gate_dir, "agent-workspace")
    File.mkdir_p!(workspace)
    assert :ok = AgentBuildGuard.install(workspace)
    Map.put(context, :wrapper_bin, AgentBuildGuard.bin_dir(workspace))
  end

  defp build_gate_status(opts) do
    BuildGate.status(Keyword.merge([stagger_seconds: 0, min_free_memory_mb: nil], opts))
  end

  defp build_gate_env(%{bin_dir: bin_dir, gate_dir: gate_dir, log_path: log_path} = context) do
    path =
      [Map.get(context, :wrapper_bin), bin_dir, Map.get(context, :system_path, System.get_env("PATH", ""))]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(":")

    env = [
      {"BASH_ENV", Map.get(context, :bash_env, BuildGate.hook_path())},
      {"AIUR_BUILD_GATE_DIR", gate_dir},
      {"AIUR_BUILD_GATE_LOCK_DIR", context.lock_dir},
      {"AIUR_BUILD_GATE_SLOTS", Integer.to_string(Map.get(context, :slots, 1))},
      {"AIUR_BUILD_START_STAGGER_SECONDS", Integer.to_string(Map.get(context, :stagger_seconds, 0))},
      {"AIUR_BUILD_GATE_TIMEOUT_SECONDS", Integer.to_string(Map.get(context, :timeout_seconds, 5))},
      {"AIUR_MIN_FREE_MEMORY_MB", Integer.to_string(Map.get(context, :min_free_memory_mb, 0))},
      {"AIUR_MEMINFO_PATH", Map.get(context, :meminfo_path, Path.join(gate_dir, "meminfo"))},
      {"FAKE_MIX_LOG", log_path},
      {"FAKE_MIX_STARTED", Map.get(context, :started_path, "")},
      {"FAKE_MIX_TIMING_LOG", Map.get(context, :timing_log_path, "")},
      {"FAKE_MIX_CONCURRENCY", if(Map.get(context, :track_concurrency, false), do: context.concurrency_path, else: "")},
      {"FAKE_MIX_MAX_CONCURRENCY", if(Map.get(context, :track_concurrency, false), do: context.max_concurrency_path, else: "")},
      {"FAKE_MIX_DESCENDANT", Map.get(context, :descendant_path, "")},
      {"FAKE_MIX_DESCENDANT_RELEASE", if(Map.get(context, :descendant_release_barrier, false), do: context.descendant_release_path, else: "")},
      {"FAKE_MIX_DESCENDANT_SLEEP", Integer.to_string(Map.get(context, :descendant_sleep_seconds, 0))},
      {"FAKE_MIX_ADOPTED_DAEMON_PID", Map.get(context, :adopted_daemon_pid_path, "")},
      {"FAKE_MIX_ADOPTED_DAEMON_DEFAULT_TERM_PID", Map.get(context, :adopted_daemon_default_term_pid_path, "")},
      {"FAKE_MIX_DESCENDANT_COMMAND", Map.get(context, :descendant_command, "")},
      {"FAKE_MIX_DESCENDANT_GATE_LOG", Map.get(context, :descendant_gate_log, "")},
      {"FAKE_MIX_PID", Map.get(context, :mix_pid_path, "")},
      {"FAKE_MIX_SLEEP", Integer.to_string(Map.get(context, :sleep_seconds, 0))},
      {"FAKE_MIX_EXIT_STATUS", Integer.to_string(Map.get(context, :mix_exit_status, 0))},
      {"FAKE_MIX_IGNORE_TERM", if(Map.get(context, :ignore_term, false), do: "1", else: "0")},
      {"FAKE_MIX_ATTACK_LOCKS", if(Map.get(context, :attack_lock_namespace, false), do: "1", else: "0")},
      {"AIUR_BUILD_GATE_DIAGNOSTIC_PID", Integer.to_string(Map.get(context, :diagnostic_pid, 0))},
      {"AIUR_BUILD_GATE_DIAGNOSTIC_PGID", Integer.to_string(Map.get(context, :diagnostic_pgid, 0))},
      {"AIUR_BUILD_GATE_HOLDER_FAIL_AFTER_POPEN", if(Map.get(context, :holder_fail_after_popen, false), do: "1", else: "0")},
      {"AIUR_BUILD_GATE_HOLDER_START_DELAY_SECONDS", to_string(Map.get(context, :holder_start_delay_seconds, 0))},
      {"AIUR_BUILD_GATE_MAX_HOLD_SECONDS", Integer.to_string(Map.get(context, :max_hold_seconds, 0))},
      {"AIUR_BUILD_GATE_RETAIN_SECONDS", to_string(Map.get(context, :retain_seconds, ""))},
      {"AIUR_TEST_STATUS_READ_DELAY_SECONDS", to_string(Map.get(context, :status_read_delay_seconds, 0))},
      {"AIUR_TEST_HANDSHAKE_FIFO_FRAGMENT", Map.get(context, :handshake_fifo_fragment, "")},
      {"AIUR_TEST_DELAY_OWNER_MV", if(Map.get(context, :delay_owner_publication, false), do: "1", else: "0")},
      {"AIUR_TEST_FAIL_FINAL_OWNER_MV", if(Map.get(context, :fail_final_owner_publication, false), do: "1", else: "0")},
      {"AIUR_TEST_MV_COUNT", Path.join(gate_dir, "mv-count")},
      {"AIUR_BUILD_GATE_LEASE_STRATEGY", Map.get(context, :lease_strategy, "auto")},
      {"AIUR_BUILD_GATE_BIN", Map.get(context, :wrapper_bin, "")},
      {"AIUR_BUILD_GATE_LEASE_PATH", ""},
      {"AIUR_BUILD_GATE_LEASE_TOKEN", ""},
      {"PATH", path}
    ]

    env ++ build_gate_holder_test_hooks(context) ++ Map.get(context, :extra_env, [])
  end

  # Holder test-hook env entries kept out of build_gate_env so that function's
  # cyclomatic complexity stays under the Credo limit. These drive the
  # #2398 review fixtures: a periodically-waking adopted daemon, and forcing
  # the no-schedstat measurement path.
  defp build_gate_holder_test_hooks(%{gate_dir: gate_dir} = context) do
    [
      {"FAKE_MIX_ADOPTED_DAEMON_WAKEUP", if(Map.get(context, :adopted_daemon_wakeup, false), do: "1", else: "0")},
      {"AIUR_BUILD_GATE_HOLDER_SCHEDSTAT_PATH", if(Map.get(context, :cpu_measure_unavailable, false), do: Path.join(gate_dir, "no-schedstat"), else: "")}
    ]
  end

  defp start_gated_port(command, context) do
    setsid = System.find_executable("setsid") || flunk("setsid is required")
    bash = System.find_executable("bash") || flunk("bash is required")
    root_pid_path = Path.join(context.gate_dir, "agent-root.pid")
    wrapped_command = ~s|printf '%s\\n' "$$" > "#{root_pid_path}"; exec #{command}|

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(setsid)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [String.to_charlist(bash), ~c"-c", String.to_charlist(wrapped_command)],
          env:
            Enum.map(build_gate_env(context), fn {name, value} ->
              {String.to_charlist(name), String.to_charlist(value)}
            end)
        ]
      )

    wait_for_file!(root_pid_path)
    root_pid = root_pid_path |> File.read!() |> String.trim() |> String.to_integer()
    {port, root_pid}
  end

  defp run_real_mix(command, %{gate_dir: gate_dir, real_mix_project: project} = context) do
    mix_path = System.find_executable("mix")

    env = [
      {"BASH_ENV", BuildGate.hook_path()},
      {"AIUR_BUILD_GATE_DIR", gate_dir},
      {"AIUR_BUILD_GATE_LOCK_DIR", context.lock_dir},
      {"AIUR_BUILD_GATE_SLOTS", "1"},
      {"AIUR_BUILD_START_STAGGER_SECONDS", "0"},
      {"AIUR_BUILD_GATE_TIMEOUT_SECONDS", "5"},
      {"AIUR_MIN_FREE_MEMORY_MB", "0"},
      {"AIUR_MEMINFO_PATH", Map.get(context, :meminfo_path, Path.join(gate_dir, "meminfo"))},
      {"AIUR_BUILD_GATE_LEASE_STRATEGY", "linux"},
      # A parent agent shell may run gated and hand this real Mix a lease path
      # into ITS gate directory. This nested Mix must acquire its own lease
      # under the temp gate, never reuse an inherited one (#2116).
      {"AIUR_BUILD_GATE_LEASE_PATH", ""},
      {"AIUR_BUILD_GATE_LEASE_TOKEN", ""},
      {"LEASE_DESCENDANT_STARTED", context.descendant_path},
      {"LEASE_DESCENDANT_RELEASE", context.descendant_release_path},
      {"LEASE_DESCENDANT_DONE", context.descendant_path <> ".done"},
      {"PATH", Path.dirname(mix_path) <> ":" <> System.get_env("PATH", "")}
    ]

    System.cmd("bash", ["-c", command], cd: project, env: env, stderr_to_stdout: true)
  end

  defp wait_for_file!(path, attempts \\ 50) do
    script = ~S"""
    for ((attempt = 0; attempt < $2; attempt++)); do
      [[ -e $1 ]] && exit 0
      sleep 0.02
    done
    exit 1
    """

    case System.cmd("bash", ["-c", script, "wait-for-file", path, Integer.to_string(attempts)]) do
      {_output, 0} -> :ok
      _ -> flunk("timed out waiting for #{path}")
    end
  end

  defp wait_for_status!(gate_dir, capacity, fun, attempts \\ 300)

  defp wait_for_status!(_gate_dir, _capacity, _fun, 0), do: flunk("timed out waiting for gate status")

  defp wait_for_status!(gate_dir, capacity, fun, attempts) do
    if fun.(build_gate_status(gate_dir: gate_dir, capacity: capacity)) do
      :ok
    else
      Process.sleep(20)
      wait_for_status!(gate_dir, capacity, fun, attempts - 1)
    end
  end

  defp release_descendant_on_exit(context) do
    on_exit(fn -> release_descendant!(context) end)
  end

  defp release_descendant!(context) do
    File.touch!(context.descendant_release_path)
    wait_for_file!(context.descendant_path <> ".done", 1500)
  end

  defp maybe_assert_recorded_process_gone!(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.trim()
      |> String.to_integer()
      |> assert_process_gone!()
    end
  end

  defp assert_process_gone!(pid, attempts \\ 200)

  defp assert_process_gone!(pid, 0) do
    {process, _status} =
      System.cmd("ps", ["-o", "pid=,ppid=,pgid=,stat=,args=", "-p", Integer.to_string(pid)], stderr_to_stdout: true)

    flunk("process remained alive after bounded cleanup: #{String.trim(process)}")
  end

  defp assert_process_gone!(pid, attempts) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {state, 0} ->
        if String.trim_leading(state) |> String.starts_with?("Z") do
          :ok
        else
          Process.sleep(10)
          assert_process_gone!(pid, attempts - 1)
        end

      {_output, _status} ->
        :ok
    end
  end

  defp wait_for_wildcard!(pattern, attempts \\ 50) do
    script = ~S"""
    for ((attempt = 0; attempt < $2; attempt++)); do
      compgen -G "$1" >/dev/null && exit 0
      sleep 0.02
    done
    exit 1
    """

    case System.cmd("bash", ["-c", script, "wait-for-wildcard", pattern, Integer.to_string(attempts)]) do
      {_output, 0} -> Path.wildcard(pattern)
      _ -> flunk("timed out waiting for #{pattern}")
    end
  end

  defp wait_for_file_contents!(path, pattern, attempts \\ 50)

  defp wait_for_file_contents!(_path, _pattern, 0), do: flunk("timed out waiting for file contents")

  defp wait_for_file_contents!(path, pattern, attempts) do
    case File.read(path) do
      {:ok, contents} ->
        if contents =~ pattern do
          :ok
        else
          Process.sleep(20)
          wait_for_file_contents!(path, pattern, attempts - 1)
        end

      _ ->
        Process.sleep(20)
        wait_for_file_contents!(path, pattern, attempts - 1)
    end
  end

  # A `setsid`-detached daemon keeps its own session once its `setsid` parent
  # exits and reparents onto the holder's subreaper. Wait until that actually
  # happened — PPID equals the holder's PID — so a pause test provably targets
  # an adopted stranger and not a process still owned by the build (#2387).
  # Gating on "not the wrapped command" was satisfiable before the reparent,
  # because the daemon's immediate parent is the intermediate subshell, never
  # the wrapped command itself (#2404).
  defp wait_for_adopted_daemon!(daemon_pid, holder_pid, attempts \\ 300)

  defp wait_for_adopted_daemon!(_daemon_pid, _holder_pid, 0),
    do: flunk("timed out waiting for the daemon to reparent onto the holder")

  defp wait_for_adopted_daemon!(daemon_pid, holder_pid, attempts) do
    case System.cmd("ps", ["-o", "ppid=", "-p", Integer.to_string(daemon_pid)], stderr_to_stdout: true) do
      {output, 0} ->
        if output |> String.trim() |> String.to_integer() == holder_pid do
          :ok
        else
          Process.sleep(10)
          wait_for_adopted_daemon!(daemon_pid, holder_pid, attempts - 1)
        end

      _ ->
        Process.sleep(10)
        wait_for_adopted_daemon!(daemon_pid, holder_pid, attempts - 1)
    end
  end

  # The holder records itself in the slot owner record once it starts; wait
  # for that so a pause test can signal the holder's exception path directly.
  defp wait_for_holder_pid!(gate_dir, attempts \\ 200)

  defp wait_for_holder_pid!(_gate_dir, 0), do: flunk("timed out waiting for a gate holder pid")

  defp wait_for_holder_pid!(gate_dir, attempts) do
    case holder_pid_from_owner(gate_dir) do
      nil ->
        Process.sleep(10)
        wait_for_holder_pid!(gate_dir, attempts - 1)

      pid ->
        pid
    end
  end

  defp holder_pid_from_owner(gate_dir) do
    gate_dir
    |> Path.join("slot-*.owner")
    |> Path.wildcard()
    |> Enum.find_value(&holder_pid_from_owner_file/1)
  end

  defp holder_pid_from_owner_file(path) do
    with {:ok, contents} <- File.read(path),
         [_, pid] <- Regex.run(~r/holder_pid=(\d+)/, contents),
         pid when pid > 0 <- String.to_integer(pid) do
      pid
    else
      _ -> nil
    end
  end

  defp write_meminfo!(context, available_mb) do
    path = Map.get(context, :meminfo_path, Path.join(context.gate_dir, "meminfo"))
    File.write!(path, "MemAvailable: #{available_mb * 1_024} kB\n")
  end

  defp timing_events!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [event, phase, timestamp] = String.split(line, " ", parts: 3)
      {{String.to_existing_atom(event), phase}, String.to_integer(timestamp)}
    end)
  end

  defp write_fake_mix!(path) do
    File.write!(path, """
    #!/usr/bin/env bash

    if [[ ${FAKE_MIX_IGNORE_TERM:-0} == 1 ]]; then
      trap '' TERM
    fi

    update_concurrency() {
      [[ -n ${FAKE_MIX_CONCURRENCY:-} ]] || return 0

      exec 8>>"${FAKE_MIX_CONCURRENCY}.lock"
      flock 8
      active=$(cat "$FAKE_MIX_CONCURRENCY")
      active=$((active + $1))
      printf '%s\n' "$active" > "$FAKE_MIX_CONCURRENCY"

      max=$(cat "$FAKE_MIX_MAX_CONCURRENCY")
      if ((active > max)); then
        printf '%s\n' "$active" > "$FAKE_MIX_MAX_CONCURRENCY"
      fi

      flock -u 8
      exec 8>&-
    }

    printf '%s\\n' "$*" >> "$FAKE_MIX_LOG"
    if [[ -n ${FAKE_MIX_PID:-} ]]; then
      printf '%s\\n' "$$" > "$FAKE_MIX_PID"
    fi
    if [[ ${FAKE_MIX_ATTACK_LOCKS:-0} == 1 ]]; then
      rm -f "$AIUR_BUILD_GATE_LOCK_DIR/slot-1.lock" && exit 90
      printf replaced > "$AIUR_BUILD_GATE_LOCK_DIR/slot-1.lock" && exit 91
    fi
    update_concurrency 1
    if [[ -n ${FAKE_MIX_TIMING_LOG:-} ]]; then
      printf 'start %s %s\\n' "$1" "$(date +%s)" >> "$FAKE_MIX_TIMING_LOG"
    fi
    if [[ -n ${FAKE_MIX_STARTED:-} ]]; then
      : > "$FAKE_MIX_STARTED"
    fi

    if [[ -n ${FAKE_MIX_ADOPTED_DAEMON_PID:-} ]]; then
      # A daemon from an unrelated session, the way dbus-daemon and
      # gnome-keyring-daemon appear under a build. It leaves this command's
      # session, ignores TERM, and outlives mix. The intermediate `( ... )`
      # subshell exits immediately so the daemon reparents onto the holder's
      # subreaper even while the command is still running -- the #2387
      # incident shape.
      (
        setsid bash -c '
          trap "" TERM
          printf "%s\\n" "$$" > "$1"
          if [[ ${FAKE_MIX_ADOPTED_DAEMON_WAKEUP:-0} == 1 ]]; then
            # A real session daemon is not `sleep`: it wakes on timers and
            # handles messages, consuming a small but nonzero slice of CPU.
            # This low-duty-cycle timer loop (a ~0.5ms burst every second) is
            # that shape, staying far below the 3ms/s busy threshold, so the
            # threshold lower bound is pinned by a test rather than by
            # assertion (#2398).
            while :; do
              for ((i = 0; i < 300; i++)); do :; done
              sleep 1
            done
          else
            exec sleep 600
          fi
        ' fake-adopted-daemon "$FAKE_MIX_ADOPTED_DAEMON_PID" </dev/null >/dev/null 2>&1 &
      ) </dev/null >/dev/null 2>&1
    fi

    if [[ -n ${FAKE_MIX_ADOPTED_DAEMON_DEFAULT_TERM_PID:-} ]]; then
      # The real gnome-keyring-daemon does not ignore SIGTERM, so the
      # TERM-ignoring daemon above is more robust than production: a partial
      # revert of #2391 that sweeps adopted daemons with SIGTERM alone would
      # kill this default-disposition daemon while the ignoring one survived,
      # and the keyring-protection test would still look green. Both must
      # survive containment (#2404).
      (
        setsid bash -c '
          printf "%s\n" "$$" > "$1"
          exec sleep 600
        ' fake-adopted-daemon-default-term "$FAKE_MIX_ADOPTED_DAEMON_DEFAULT_TERM_PID" </dev/null >/dev/null 2>&1 &
      ) </dev/null >/dev/null 2>&1
    fi

    if [[ -n ${FAKE_MIX_DESCENDANT_RELEASE:-} ]] || ((FAKE_MIX_DESCENDANT_SLEEP > 0)); then
      (
        printf '%s\\n' "$$" > "${FAKE_MIX_DESCENDANT}.pid"
        printf 'started\\n' > "$FAKE_MIX_DESCENDANT"
        if [[ -n ${FAKE_MIX_DESCENDANT_RELEASE:-} ]]; then
          # A real duty cycle, not a bare polling loop: a short busy spin per
          # wakeup keeps this "CPU-burning" descendant unambiguously above the
          # holder's 3ms/s idle threshold even when the host is loaded. A bare
          # `sleep 0.02` poll drifts to ~5-7ms/s — only ~2x the threshold —
          # and drops under it under CI load, releasing the retained slot
          # early (#2398).
          while [[ ! -e $FAKE_MIX_DESCENDANT_RELEASE ]]; do
            for ((i = 0; i < 500; i++)); do :; done
            sleep 0.02
          done
        else
          sleep "$FAKE_MIX_DESCENDANT_SLEEP"
        fi
        if [[ -n ${FAKE_MIX_DESCENDANT_COMMAND:-} ]]; then
          FAKE_MIX_DESCENDANT_RELEASE= FAKE_MIX_DESCENDANT_COMMAND= \
            bash -c "$FAKE_MIX_DESCENDANT_COMMAND" > "$FAKE_MIX_DESCENDANT_GATE_LOG" 2>&1
        fi
        printf 'done\\n' > "${FAKE_MIX_DESCENDANT}.done"
      ) </dev/null >/dev/null 2>&1 &
      update_concurrency -1
      exit 0
    fi

    sleep "${FAKE_MIX_SLEEP:-0}"
    if [[ -n ${FAKE_MIX_TIMING_LOG:-} ]]; then
      printf 'end %s %s\\n' "$1" "$(date +%s)" >> "$FAKE_MIX_TIMING_LOG"
    fi
    update_concurrency -1
    exit "${FAKE_MIX_EXIT_STATUS:-0}"
    """)

    File.chmod!(path, 0o755)
  end

  defp write_fake_elixir_mix!(path) do
    File.write!(path, """
    #!/usr/bin/env elixir
    File.write!(System.fetch_env!("FAKE_MIX_LOG"), Enum.join(System.argv(), " ") <> "\\n", [:append])
    """)

    File.chmod!(path, 0o755)
  end

  defp write_controlled_mv!(path, real_mv) do
    File.write!(path, """
    #!/usr/bin/env bash
    destination=${!#}

    if [[ $destination == */slot-1.owner ]]; then
      exec 8>>"$AIUR_TEST_MV_COUNT.lock"
      flock 8
      count=$(cat "$AIUR_TEST_MV_COUNT" 2>/dev/null || printf '0')
      count=$((count + 1))
      printf '%s\n' "$count" > "$AIUR_TEST_MV_COUNT"
      flock -u 8
      exec 8>&-

      if [[ ${AIUR_TEST_FAIL_FINAL_OWNER_MV:-0} == 1 ]] && ((count == 3)); then
        exit 88
      fi
    fi

    "#{real_mv}" "$@"
    status=$?

    if ((status == 0)) && [[ ${AIUR_TEST_DELAY_OWNER_MV:-0} == 1 ]] &&
      [[ $destination == */slot-1.owner ]]; then
      sleep 0.2
    fi

    exit "$status"
    """)

    File.chmod!(path, 0o755)
  end

  defp write_controlled_mktemp!(path, real_mktemp) do
    File.write!(path, """
    #!/usr/bin/env bash
    created=$("#{real_mktemp}" "$@") || exit $?

    if [[ -n ${AIUR_TEST_HANDSHAKE_FIFO_FRAGMENT:-} ]] &&
      [[ $created == *"$AIUR_TEST_HANDSHAKE_FIFO_FRAGMENT"* ]]; then
      rm -f "$created" || exit $?
      mkfifo "$created" || exit $?
    fi

    printf '%s\\n' "$created"
    """)

    File.chmod!(path, 0o755)
  end

  defp write_fake_mise!(path) do
    File.write!(path, """
    #!/usr/bin/env bash
    if [[ $1 =~ ^(exec|x)$ ]]; then
      shift
      while (($#)); do
        case $1 in
          --)
            shift
            exec "$@"
            ;;
          -c|--command)
            shift
            exec bash -c "$1"
            ;;
          --command=*)
            exec bash -c "${1#--command=}"
            ;;
          *) shift ;;
        esac
      done
    fi
    exit 64
    """)

    File.chmod!(path, 0o755)
  end

  defp write_real_mix_project!(path) do
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule LeaseProbe.MixProject do
      use Mix.Project

      def project, do: [app: :lease_probe, version: "0.1.0", elixir: "~> 1.15"]
    end
    """)

    File.write!(Path.join(path, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(path, "test/lease_probe_test.exs"), ~S'''
    defmodule LeaseProbeTest do
      use ExUnit.Case

      test "leaves a detached OS child alive" do
        script = ~S"""
        printf started > "$LEASE_DESCENDANT_STARTED"
        while [ ! -e "$LEASE_DESCENDANT_RELEASE" ]; do sleep 0.02; done
        printf done > "$LEASE_DESCENDANT_DONE"
        """

        {_, 0} =
          System.cmd(
            "sh",
            ["-c", ~S|sh -c "$1" </dev/null >/dev/null 2>&1 &|, "lease-probe", script]
          )
      end
    end
    ''')
  end
end
