defmodule Aiur.TestSupport.BuildGateHelpers do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Aiur.TestSupport.BuildGateFixtures, only: [write_fake_mix!: 1, write_fake_mise!: 1]
  alias Aiur.{AgentBuildGuard, BuildGate}

  def run_bash(command, context) do
    System.cmd("bash", ["-c", command], env: build_gate_env(context), stderr_to_stdout: true)
  end

  # Runs a gated command through the real Config -> BuildGate.shell_env
  # plumbing (not the test's hand-built build_gate_env), so a config-derived
  # value like the retain window is proven to reach and be honoured by the
  # detached holder rather than merely appearing in a log line (#2398).
  def run_bash_with_shell_env(command, context, shell_opts) do
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
  def cpu_ns_from_schedstat(pid) do
    path = "/proc/#{pid}/schedstat"

    case File.read(path) do
      {:ok, contents} ->
        contents |> String.split() |> List.first() |> String.to_integer()

      {:error, reason} ->
        flunk("schedstat is required for the CPU-gated retain tests: #{path} (#{reason})")
    end
  end

  def real_executable_behind_wrapper!(command) do
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

  def system_path_without_build_wrapper do
    wrapper_bin = System.get_env("AIUR_BUILD_GATE_BIN", "")

    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.reject(&(&1 == wrapper_bin))
    |> Enum.join(":")
  end

  def run_sh(command, context) do
    System.cmd("sh", ["-c", command], env: build_gate_env(context), stderr_to_stdout: true)
  end

  # A machine where the only `mix` on PATH is a copy of the gate wrapper — the
  # #2542 shape — with a `mise` that can still name the real one.
  def shadowed_toolchain_context(context) do
    guarded = with_command_wrappers!(context)
    shim_dir = Path.join(context.gate_dir, "mise-shims")
    toolchain = Path.join(context.gate_dir, "toolchain-bin")
    mise_dir = Path.join(context.gate_dir, "mise-bin")
    Enum.each([shim_dir, toolchain, mise_dir], &File.mkdir_p!/1)

    # `mise reshim` overwrites its shim directory with links to whatever it found
    # on PATH, which is how a wrapper ends up standing in for `mix` — and for
    # `erl`, a name the guard never installs a wrapper for at all (#2542).
    for name <- ["mix", "erl"] do
      shim = Path.join(shim_dir, name)
      File.cp!(Path.join(guarded.wrapper_bin, "mix"), shim)
      File.chmod!(shim, 0o755)
    end

    write_fake_mix!(Path.join(toolchain, "mix"))
    File.write!(Path.join(toolchain, "erl"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(toolchain, "erl"), 0o755)
    write_fake_mise!(Path.join(mise_dir, "mise"))

    shadowed =
      Map.merge(guarded, %{
        bin_dir: shim_dir,
        system_path: Enum.join([mise_dir, "/usr/bin", "/bin"], ":"),
        mise_which_dir: toolchain,
        bash_env: Path.join(context.gate_dir, "missing-hook")
      })

    %{shim_dir: shim_dir, toolchain: toolchain, context: shadowed}
  end

  def with_command_wrappers!(context) do
    workspace = Path.join(context.gate_dir, "agent-workspace")
    File.mkdir_p!(workspace)
    assert :ok = AgentBuildGuard.install(workspace)
    Map.put(context, :wrapper_bin, AgentBuildGuard.bin_dir(workspace))
  end

  def build_gate_status(opts) do
    BuildGate.status(Keyword.merge([stagger_seconds: 0, min_free_memory_mb: nil], opts))
  end

  def build_gate_env(%{bin_dir: bin_dir, gate_dir: gate_dir, log_path: log_path} = context) do
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
      {"FAKE_MISE_WHICH_DIR", Map.get(context, :mise_which_dir, "")},
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
  def build_gate_holder_test_hooks(%{gate_dir: gate_dir} = context) do
    [
      {"FAKE_MIX_ADOPTED_DAEMON_WAKEUP", if(Map.get(context, :adopted_daemon_wakeup, false), do: "1", else: "0")},
      {"AIUR_BUILD_GATE_HOLDER_SCHEDSTAT_PATH", if(Map.get(context, :cpu_measure_unavailable, false), do: Path.join(gate_dir, "no-schedstat"), else: "")}
    ]
  end

  def start_gated_port(command, context) do
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

  def run_real_mix(command, %{gate_dir: gate_dir, real_mix_project: project} = context) do
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

  def wait_for_file!(path, attempts \\ 50) do
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

  def wait_for_status!(gate_dir, capacity, fun, attempts \\ 300)

  def wait_for_status!(_gate_dir, _capacity, _fun, 0), do: flunk("timed out waiting for gate status")

  def wait_for_status!(gate_dir, capacity, fun, attempts) do
    if fun.(build_gate_status(gate_dir: gate_dir, capacity: capacity)) do
      :ok
    else
      Process.sleep(20)
      wait_for_status!(gate_dir, capacity, fun, attempts - 1)
    end
  end

  def release_descendant_on_exit(context) do
    on_exit(fn -> release_descendant!(context) end)
  end

  def release_descendant!(context) do
    File.touch!(context.descendant_release_path)
    wait_for_file!(context.descendant_path <> ".done", 1500)
  end

  def maybe_assert_recorded_process_gone!(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.trim()
      |> String.to_integer()
      |> assert_process_gone!()
    end
  end

  def assert_process_gone!(pid, attempts \\ 200)

  def assert_process_gone!(pid, 0) do
    {process, _status} =
      System.cmd("ps", ["-o", "pid=,ppid=,pgid=,stat=,args=", "-p", Integer.to_string(pid)], stderr_to_stdout: true)

    flunk("process remained alive after bounded cleanup: #{String.trim(process)}")
  end

  def assert_process_gone!(pid, attempts) do
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

  def wait_for_wildcard!(pattern, attempts \\ 50) do
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

  def wait_for_file_contents!(path, pattern, attempts \\ 50)

  def wait_for_file_contents!(_path, _pattern, 0), do: flunk("timed out waiting for file contents")

  def wait_for_file_contents!(path, pattern, attempts) do
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
  def wait_for_adopted_daemon!(daemon_pid, holder_pid, attempts \\ 300)

  def wait_for_adopted_daemon!(_daemon_pid, _holder_pid, 0),
    do: flunk("timed out waiting for the daemon to reparent onto the holder")

  def wait_for_adopted_daemon!(daemon_pid, holder_pid, attempts) do
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
  def wait_for_holder_pid!(gate_dir, attempts \\ 200)

  def wait_for_holder_pid!(_gate_dir, 0), do: flunk("timed out waiting for a gate holder pid")

  def wait_for_holder_pid!(gate_dir, attempts) do
    case holder_pid_from_owner(gate_dir) do
      nil ->
        Process.sleep(10)
        wait_for_holder_pid!(gate_dir, attempts - 1)

      pid ->
        pid
    end
  end

  def holder_pid_from_owner(gate_dir) do
    gate_dir
    |> Path.join("slot-*.owner")
    |> Path.wildcard()
    |> Enum.find_value(&holder_pid_from_owner_file/1)
  end

  def holder_pid_from_owner_file(path) do
    with {:ok, contents} <- File.read(path),
         [_, pid] <- Regex.run(~r/holder_pid=(\d+)/, contents),
         pid when pid > 0 <- String.to_integer(pid) do
      pid
    else
      _ -> nil
    end
  end

  def write_meminfo!(context, available_mb) do
    path = Map.get(context, :meminfo_path, Path.join(context.gate_dir, "meminfo"))
    File.write!(path, "MemAvailable: #{available_mb * 1_024} kB\n")
  end

  def timing_events!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [event, phase, timestamp] = String.split(line, " ", parts: 3)
      {{String.to_existing_atom(event), phase}, String.to_integer(timestamp)}
    end)
  end
end
