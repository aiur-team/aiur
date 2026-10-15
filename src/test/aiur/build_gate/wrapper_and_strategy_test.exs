Code.require_file("../../support/build_gate_case.ex", __DIR__)

defmodule Aiur.BuildGate.WrapperAndStrategyTest do
  use Aiur.TestSupport.BuildGateCase

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
      |> Map.merge(%{
        bin_dir: empty_bin,
        system_path: "/usr/bin:/bin",
        # Resolution now falls back to the toolchain manager (#2542), so an
        # installed `mise` must be pointed at an empty data directory for this
        # fixture to still be a machine with no Mix on it at all.
        extra_env: [{"MISE_DATA_DIR", Path.join(context.gate_dir, "no-mise-data")}]
      })

    assert {output, 127} = run_sh("timeout --kill-after=1 2 mix test", missing_command_context)
    assert output =~ "gate_error reason=command_unavailable command=mix"
    assert output =~ "status=127"
    # The 127 names the wrapper and the self-check, so the next reader knows
    # which file shadowed the toolchain (#2542).
    assert output =~ "wrapper=#{Path.join(missing_command_context.wrapper_bin, "mix")}"
    assert output =~ "__aiur_build_gate_self_check__"
  end

  test "the command wrapper resolves the toolchain through mise when PATH holds only wrappers", context do
    # #2542: a `mise reshim` can leave ~/.local/share/mise/shims/mix as a copy of
    # this wrapper, so PATH holds no real Mix at all and a PATH-order-only
    # resolution exits 127. Resolution asks the toolchain manager instead, and
    # refuses to hand the command to another copy of itself.
    %{shim_dir: shim_dir, toolchain: toolchain, context: shadowed} = shadowed_toolchain_context(context)

    assert {_output, 0} = run_sh("mix format", shadowed)
    assert File.read!(context.log_path) == "format\n"

    assert {output, 0} = run_sh("mix __aiur_build_gate_self_check__", shadowed)
    assert output =~ "self_check command=mix"
    assert output =~ "source=mise"
    assert output =~ "real=#{Path.join(toolchain, "mix")}"
    assert output =~ "status=0"
    refute output =~ "real=#{Path.join(shim_dir, "mix")}"

    assert {erl_output, 0} = run_sh("erl __aiur_build_gate_self_check__", shadowed)
    assert erl_output =~ "self_check command=erl"
    assert erl_output =~ "real=#{Path.join(toolchain, "erl")}"
  end

  test "the command wrapper self-check reports the PATH binary it wraps", context do
    guarded = with_command_wrappers!(context)

    assert {output, 0} = run_sh("mix __aiur_build_gate_self_check__", guarded)
    assert output =~ "self_check command=mix"
    assert output =~ "wrapper=#{Path.join(guarded.wrapper_bin, "mix")}"
    assert output =~ "source=path"
    assert output =~ "real=#{Path.join(context.bin_dir, "mix")}"
    refute File.exists?(context.log_path)
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
end
