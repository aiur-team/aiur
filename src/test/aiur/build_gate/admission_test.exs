Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.AdmissionTest do
  use Aiur.TestSupport.BuildGateCase

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

    # An *empty file with a recognised extension*, not `/dev/null`. This test
    # only needs mise to load no tool configuration, and `/dev/null` used to be
    # an accepted way to say that. It is not a supported value: mise infers the
    # config format from the file name, and since 2026.9.0 it rejects one it
    # cannot classify —
    #
    #   mise ERROR error parsing config file: /dev/null
    #   mise ERROR unknown config file type: /dev/null
    #
    # — exiting 1 before it ever runs the command. Because CI installs the
    # latest mise rather than the version pinned in `mise.toml`, that release
    # turned this test red on unmodified `main`, with no commit involved. An
    # empty `mise.toml` states the same intent in a form every version parses.
    empty_mise_config = Path.join(context.gate_dir, "empty-mise.toml")
    File.write!(empty_mise_config, "")

    guarded_context =
      context
      |> with_command_wrappers!()
      |> Map.merge(%{
        bin_dir: real_bin,
        system_path: Path.dirname(real_mise) <> ":/usr/bin:/bin",
        extra_env: [{"MISE_CONFIG_FILE", empty_mise_config}],
        lease_strategy: "pid"
      })

    fake_mix = Path.join(real_bin, "mix")
    capture_path = Path.join(context.gate_dir, "real-mise.output")

    for command <- [
          "mise exec -C / -c '#{fake_mix} test'",
          "mise x -C / --command '#{fake_mix} do compile + test'"
        ] do
      # The command's own output is redirected into `capture_path`, so a
      # non-zero exit leaves the assertion with nothing but `{"", 1}` unless the
      # captured file is read back into the failure message. Three CI runs
      # failed here and named no cause for exactly that reason; the tool's error
      # was sitting in a file nobody printed.
      {shell_output, status} = run_sh("#{command} > '#{capture_path}' 2>&1", guarded_context)

      assert status == 0,
             """
             #{command} exited #{status}
             shell output: #{inspect(shell_output)}
             captured output:
             #{File.read(capture_path) |> elem(1)}
             """

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
end
