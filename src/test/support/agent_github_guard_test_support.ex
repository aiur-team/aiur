defmodule Aiur.AgentGitHubGuardTestSupport do
  @moduledoc false
  # Runs the installed `gh` and `git` guards for `Aiur.AgentGitHubGuardCase` tests.

  import ExUnit.Assertions

  alias Aiur.AgentGitHubGuard.Script

  # The assembled `gh` guard as a file, for tests that run it uninstalled.
  def write_gh_guard(directory) do
    path = Path.join(directory, "guard.sh")
    File.write!(path, Script.gh())
    path
  end

  def wait_until(predicate, attempts \\ 500) do
    cond do
      predicate.() -> :ok
      attempts <= 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(predicate, attempts - 1)
    end
  end

  def run_guard(context, args, extra_env \\ []) do
    extra_env = Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    budget_env =
      if Enum.any?(extra_env, fn
           {"AIUR_GITHUB_BUDGET_ROOT", value} -> value != ""
           _other -> false
         end),
         do: [{"AIUR_GITHUB_BUDGET_ENABLED", "1"}],
         else: []

    System.cmd(context.wrapper, args,
      env: guard_env(context) ++ budget_env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  def run_guard_with_stdin(context, args, input, extra_env \\ []) do
    {output, status} =
      System.cmd(
        "python3",
        ["-c", "import subprocess,sys; raise SystemExit(subprocess.run(sys.argv[2:], input=sys.argv[1].encode()).returncode)", input, context.wrapper | args],
        env: guard_env(context) ++ Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end),
        stderr_to_stdout: true
      )

    {output, status}
  end

  def run_agent_guard(context, args, env) do
    System.cmd(context.wrapper, args, env: env, stderr_to_stdout: true)
  end

  # The same script run from outside `.aiur-runtime/bin` and without the agent
  # workspace marker: this is how the Executor invokes it, with full authority.
  #
  # `System.cmd` merges the parent environment rather than replacing it, so
  # "remove the marker" is not enough when the test VM itself runs inside an
  # Aiur agent workspace (AIUR_AGENT_WORKSPACE is inherited back in). The guard
  # treats an empty AIUR_AGENT_WORKSPACE as absent (`-z "${AIUR_AGENT_WORKSPACE:-}"`),
  # so pinning it to "" genuinely simulates an Executor shell everywhere.
  def run_executor_guard(context, args, extra_env) do
    bin = Path.join(context.workspace, "executor-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)
    wrapper = Path.join(bin, "gh")
    File.cp!(context.wrapper, wrapper)
    File.chmod!(wrapper, 0o755)

    # An Executor shell has none of the agent-workspace budget exports: the
    # identity key and consumer are scrubbed (the inherited values from an
    # agent test VM would otherwise make the wrapper bind the publication
    # credential and label the caller `workspace:...` instead of exercising
    # the host path under test).
    env =
      Enum.reject(guard_env(context), fn {name, _value} -> name == "AIUR_AGENT_WORKSPACE" end) ++
        [
          {"AIUR_GITHUB_BUDGET_ENABLED", "1"},
          {"AIUR_AGENT_WORKSPACE", ""},
          {"AIUR_GITHUB_BUDGET_IDENTITY_KEY", ""},
          {"AIUR_GITHUB_BUDGET_CONSUMER", ""}
        ] ++ Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    System.cmd(wrapper, args, env: env, stderr_to_stdout: true)
  end

  def run_git_credential(context, input, extra_env) do
    base_env = [
      {"AIUR_REAL_GIT", real_git()},
      {"AIUR_GITHUB_CREDENTIAL_FILE", Path.join(context.state_path, "no-agent-token")}
    ]

    overrides = Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)
    env = Enum.reject(base_env, fn {name, _value} -> List.keymember?(overrides, name, 0) end) ++ overrides

    System.cmd("sh", ["-c", ~s(printf '%s' "$2" | "$1" credential fill), "sh", context.git_wrapper, input],
      env: env,
      stderr_to_stdout: true
    )
  end

  def run_git_guard(context, args, extra_env \\ []) do
    extra_env = Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    System.cmd(context.git_wrapper, args,
      cd: context.workspace,
      env:
        [
          {"AIUR_REAL_GIT", real_git()},
          {"AIUR_AGENT_WORKSPACE", context.workspace},
          {"GITHUB_TOKEN", "agent-token"}
        ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  def init_git_workspace(context) do
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", context.workspace], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", context.workspace, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", context.workspace, "config", "user.name", "Test"], stderr_to_stdout: true)
    File.write!(Path.join(context.workspace, "tracked.txt"), "tracked\n")
    assert {_, 0} = System.cmd(real_git(), ["-C", context.workspace, "add", "tracked.txt"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", context.workspace, "commit", "--quiet", "-m", "initial"], stderr_to_stdout: true)
  end

  # A linked worktree of the agent workspace itself, so
  # `-C workspace worktree remove <it>` passes the #2049 workspace-authority
  # check and reaches the #2094 liveness and uncommitted-changes checks.
  def make_workspace_worktree(context, name) do
    init_git_workspace(context)
    worktree = Path.join(context.workspace, name)

    assert {_, 0} =
             System.cmd(real_git(), ["-C", context.workspace, "worktree", "add", "--quiet", worktree, "-b", name], stderr_to_stdout: true)

    worktree
  end

  # A wrapper installed outside `<workspace>/.aiur-runtime/bin`, the shape the
  # host-level install (`~/.aiur/bin/git`, alongside `aiurdev`) takes for a
  # plain-shell caller. Returns the host bin directory so the caller can prepend
  # it to PATH exactly as an operator shell would.
  def install_host_wrapper(context) do
    host_bin = Path.join(context.workspace, "host-bin")
    File.mkdir_p!(host_bin)
    host_wrapper = Path.join(host_bin, "git")
    File.cp!(context.git_wrapper, host_wrapper)
    File.chmod!(host_wrapper, 0o755)
    host_bin
  end

  def make_host_worktree(context) do
    main = Path.join(context.workspace, "host-main")
    File.mkdir_p!(main)
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", main], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "config", "user.name", "Test"], stderr_to_stdout: true)
    File.write!(Path.join(main, "tracked.txt"), "tracked\n")
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "add", "tracked.txt"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "commit", "--quiet", "-m", "initial"], stderr_to_stdout: true)
    worktree = Path.join(main, "wt")
    assert {_, 0} = System.cmd(real_git(), ["-C", main, "worktree", "add", "--quiet", worktree, "-b", "wt"], stderr_to_stdout: true)
    {main, worktree}
  end

  # Invoke `git` the way a plain operator shell would: the host bin directory
  # prepended to PATH so the bare `git` resolves to the host wrapper, and no
  # AIUR_REAL_GIT or workspace marker. The wrapper resolves the real executable
  # from the rest of PATH on its own.
  def run_host_guard(host_bin, main, args) do
    script = "exec git " <> Enum.map_join(args, " ", &shell_quote/1)

    System.cmd("sh", ["-c", script],
      cd: main,
      env: [
        {"PATH", host_bin <> ":" <> (System.get_env("PATH") || "")},
        {"AIUR_REAL_GIT", nil}
      ],
      stderr_to_stdout: true
    )
  end

  def shell_quote(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  # A "sibling wrapper" process rooted in a worktree: the spawned command line
  # never mentions git or worktree, which is precisely the shape that defeats
  # naive `/proc/*/cmdline` matching. `exec` replaces the shell, so the port's
  # OS pid IS the rooted process.
  def spawn_rooted_sibling(worktree, command) do
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, args: ["-c", "cd \"$1\" && exec $2", "sh", worktree, command]]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    {port, pid}
  end

  def wait_rooted(pid, worktree, attempts \\ 200)

  def wait_rooted(_pid, _worktree, 0), do: flunk("sibling wrapper never rooted in the worktree")

  def wait_rooted(pid, worktree, attempts) do
    case File.read_link("/proc/#{pid}/cwd") do
      {:ok, cwd} when is_binary(cwd) ->
        if Path.expand(cwd) == Path.expand(worktree) do
          :ok
        else
          Process.sleep(10)
          wait_rooted(pid, worktree, attempts - 1)
        end

      _ ->
        Process.sleep(10)
        wait_rooted(pid, worktree, attempts - 1)
    end
  end

  def stop_rooted_sibling(_port, pid) do
    # The port closes with its owning test process; only the rooted process
    # needs an explicit kill, and `kill` by pid works from any process, so the
    # on_exit callback can reuse this without touching the dead owner's port.
    _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  def real_git, do: System.get_env("AIUR_REAL_GIT") || System.find_executable("git")

  def guard_env(context) do
    [
      {"AIUR_REAL_GH", context.fake_gh},
      {"AIUR_REPO_STATE_PATH", context.state_path},
      {"AIUR_AGENT_QUOTA_STATE_PATH", Path.join(context.state_path, "github-quota")},
      {"AIUR_AGENT_WORKSPACE", context.workspace},
      {"FAKE_GH_CALLS", context.calls},
      {"GITHUB_TOKEN", ""},
      # #2356: the guard reads the credential from this file. Pointed at a
      # path that never exists so the harness never picks up a real host token;
      # tests that exercise the file supply their own.
      {"AIUR_GITHUB_CREDENTIAL_FILE", Path.join(context.state_path, "no-agent-token")},
      {"AIUR_GITHUB_BUDGET_ENABLED", "0"},
      {"AIUR_GITHUB_BUDGET_ROOT", ""},
      {"AIUR_GITHUB_BUDGET_KEY", ""},
      # The test VM runs inside an Aiur agent workspace, so the daemon's own
      # budget exports leak back in through System.cmd's env merge. Scrub them
      # here so a `run_guard` test controls every admission: a leaked
      # `AIUR_GITHUB_BUDGET_IDENTITY_KEY` makes the broker bind every run's
      # ledger to whichever token first claimed the identity, silently merging
      # two distinct token keys into one — the very vacuity the `/rate_limit`
      # spelling test must catch (#2353 review).
      {"AIUR_GITHUB_BUDGET_IDENTITY_KEY", ""},
      {"AIUR_GITHUB_BUDGET_CONSUMER", ""},
      {"AIUR_GITHUB_BUDGET_BROKER", "/nonexistent/aiur-github-budget"}
    ]
  end

  def isolated_command_path(context, extra_commands) do
    bin = Path.join(context.workspace, "isolated-command-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)

    commands =
      ~w(awk basename cat cut date dirname grep mkdir mktemp mv rm sed sleep tail wc) ++
        extra_commands

    Enum.each(commands, fn command ->
      executable = System.find_executable(command) || flunk("#{command} executable is required for this guard test")
      File.ln_s!(executable, Path.join(bin, command))
    end)

    bin
  end

  def wait_for_calls(path, expected, attempts \\ 50)

  def wait_for_calls(_path, _expected, 0), do: flunk("timed out waiting for guarded gh call")

  def wait_for_calls(path, expected, attempts) do
    calls =
      case File.read(path) do
        {:ok, contents} -> String.split(contents, "\n", trim: true) |> length()
        _missing -> 0
      end

    if calls >= expected do
      :ok
    else
      Process.sleep(10)
      wait_for_calls(path, expected, attempts - 1)
    end
  end

  def sha256_hex(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
