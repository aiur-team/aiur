defmodule Aiur.TestSupport.EngineCase do
  @moduledoc false
  # Shared fixtures for the tests that exec or source the launcher engine.

  import ExUnit.Callbacks, only: [on_exit: 1]

  @engine Path.expand("../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)
  @cli_package Path.expand("../../../packaging/npm/aiur-cli/package.json", __DIR__)

  def engine, do: @engine
  def cli_package, do: @cli_package

  # Run the engine's `__identity` probe with a clean AIUR_* env plus the given
  # overrides, returning the resolved KEY=VALUE map.
  def identity(overrides) do
    base = [
      {"USER", "tester"},
      {"AIUR_BG_STATE_DIR", nil},
      {"AIUR_SESSION_PREFIX", nil},
      {"AIUR_PROFILES_FILE", nil},
      {"AIUR_RELEASE_NODE", nil},
      {"AIUR_COOKIE_FILE", nil},
      {"AIUR_RELEASE_DIR", nil},
      {"AIUR_REPO_ROOT", nil},
      {"AIUR_INSTANCE_KEY", nil}
    ]

    env = base ++ overrides

    {out, 0} = System.cmd(@engine, ["__identity"], env: env, stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  def fake_release do
    dir = Aiur.TestSupport.tmp_root!("aiur-engine-rel")
    on_exit(fn -> File.rm_rf!(dir) end)
    vsn = Path.join([dir, "releases", "0.1.1"])
    File.mkdir_p!(vsn)
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join([dir, "releases", "start_erl.data"]), "16.4 0.1.1\n")
    elixir = Path.join(vsn, "elixir")
    File.write!(elixir, "#!/usr/bin/env bash\necho \"ELIXIR_ARGS: $*\"\n")
    File.chmod!(elixir, 0o755)
    for f <- ["sys", "start_clean", "vm.args"], do: File.write!(Path.join(vsn, f), "")
    File.write!(Path.join([dir, "bin", "aiur"]), "#!/usr/bin/env bash\necho \"BIN: $*\"\n")
    File.chmod!(Path.join([dir, "bin", "aiur"]), 0o755)
    dir
  end

  def run_engine(args, env) do
    System.cmd(@engine, args, env: [{"USER", "tester"} | env], stderr_to_stdout: true)
  end

  def run_engine_real(args, env) do
    System.cmd(@engine, args, env: env, stderr_to_stdout: true)
  end

  def tmp_state, do: Aiur.TestSupport.tmp_root!("aiur-st")

  def realpath(path) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(out)
  end

  def spawn_sleeper(cwd) do
    port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "exec sleep 300"], cd: cwd])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  def os_pid_alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))

  def wait_dead(pid, attempts \\ 50)
  def wait_dead(pid, 0), do: not os_pid_alive?(pid)

  def wait_dead(pid, attempts) do
    if os_pid_alive?(pid) do
      Process.sleep(50)
      wait_dead(pid, attempts - 1)
    else
      true
    end
  end

  def kill_pid(pid), do: System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

  def run_sourced_engine(script, env) do
    # The engine's launch/stop paths reap any BEAM holding their node name
    # (`kill_beams_matching "-name $AIUR_RELEASE_NODE"`). Sourced from `mix test`
    # on a host running a live aiur, an un-isolated run resolves the SAME node
    # name and reaps the operator's BEAM. Pin a unique, non-existent node unless
    # the caller set one, so these reaps can never match a real process.
    env =
      if List.keymember?(env, "AIUR_RELEASE_NODE", 0) do
        env
      else
        [{"AIUR_RELEASE_NODE", "aiur-enginetest-#{System.unique_integer([:positive])}@127.0.0.1"} | env]
      end

    System.cmd("bash", ["-c", "set -euo pipefail\nsource \"$AIUR_ENGINE\"\n#{script}"],
      env: [{"AIUR_ENGINE", @engine} | env],
      stderr_to_stdout: true
    )
  end

  def fake_tmux_script(body) do
    dir = Aiur.TestSupport.tmp_root!("aiur-fake-tmux")
    File.mkdir_p!(dir)
    path = Path.join(dir, "tmux")
    File.write!(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  def run_control_rpc_captured(expression, env, prelude \\ "") do
    run_control_captured("run_control_rpc", expression, env, prelude)
  end

  def silent_failure_shapes do
    [
      {"silent nonzero exit", "#!/usr/bin/env bash\nexit 1\n", "1"},
      {"nonzero marker, no output", "#!/usr/bin/env bash\necho \"__AIUR_CONTROL_EXIT__:1\"\n", "1"},
      {"no marker at all", "#!/usr/bin/env bash\n", "1"},
      {"hung rpc", "#!/usr/bin/env bash\nsleep 5\n", "1"}
    ]
  end

  def run_control_captured(function, expression, env, prelude \\ "") do
    stdout_path = Aiur.TestSupport.tmp_root!("aiur-control-stdout")
    stderr_path = Aiur.TestSupport.tmp_root!("aiur-control-stderr")

    on_exit(fn ->
      File.rm(stdout_path)
      File.rm(stderr_path)
    end)

    script = """
    #{prelude}
    if "$CONTROL_FUNCTION" "$CONTROL_EXPRESSION" >"$STDOUT_PATH" 2>"$STDERR_PATH"; then
      code=0
    else
      code=$?
    fi
    echo "CODE=$code"
    echo "STDOUT_BYTES=$(wc -c < \"$STDOUT_PATH\")"
    echo "STDERR_LINES=$(wc -l < \"$STDERR_PATH\")"
    cat "$STDERR_PATH"
    """

    run_sourced_engine(script, [
      {"CONTROL_FUNCTION", function},
      {"CONTROL_EXPRESSION", expression},
      {"STDOUT_PATH", stdout_path},
      {"STDERR_PATH", stderr_path}
      | env
    ])
  end
end
