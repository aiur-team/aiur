defmodule ScriptsAiurdevTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/aiurdev", __DIR__)

  test "prints help without starting anything" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["--help"])
    assert output =~ "Usage: aiurdev"
    refute output =~ "MISE:"
    refute output =~ "SYSTEMCTL:"
    refute output =~ "PKILL:"
  end

  test "rejects unknown profiles" do
    ctx = test_context()

    assert {output, 64} = run_aiur(ctx, ["missing"])
    assert output =~ "Unknown profile: missing"
    assert output =~ "Usage: aiurdev"
    refute output =~ "MISE:"
  end

  test "lists built-in and configured profiles" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["list"])
    assert output =~ "default"
    assert output =~ "aiur"
    assert output =~ "actions"
    assert output =~ "actions.aiurconfig"
    assert output =~ "aiur-actions"
  end

  test "runs a configured profile in the foreground" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["actions"])
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "src")}/actions.aiurconfig"
    assert output =~ "PWD=#{Path.join(ctx.actions_repo, "src")}"
    assert output =~ "MISE:exec -- ./bin/aiur --logs-root #{ctx.logs_root}/actions --port 4101"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./actions.aiurconfig"
  end

  test "runs the built-in aiur profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["aiur"])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "src")}"
    assert output =~ "MISE:exec -- ./bin/aiur"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./../.aiurconfig"
  end

  test "restarts a selected background profile" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["--bg", "actions"])
    command_log = command_log(ctx)

    assert command_log =~ "SYSTEMCTL:--user set-environment RELEASE_DISTRIBUTION=name"
    assert command_log =~ "RELEASE_NODE=aiurdev-"
    assert command_log =~ "RELEASE_COOKIE="
    assert output =~ "SYSTEMCTL:--user restart aiur-actions\n"
    assert output =~ "SYSTEMCTL:--user status aiur-actions --no-pager\n"
    refute output =~ "MISE:"
    refute output =~ "restart aiur\n"
  end

  test "falls back to nohup when a Linux background service is missing" do
    ctx = test_context()

    assert {output, 0} =
             run_aiur(ctx, ["--bg"], env: [{"AIUR_TEST_SYSTEMCTL_RESTART_FAIL", "1"}])

    command_log = await_command_log(ctx, "NOHUP:")

    assert output =~
             "⚠️  aiur systemd service unavailable; starting with nohup background runner"

    assert output =~ "aiur started in background"
    assert command_log =~ "SYSTEMCTL:--user restart aiur\n"
    assert command_log =~ "NOHUP:#{ctx.fake_mise} exec -- ./bin/aiur"
    assert command_log =~ "--host 127.0.0.1"
    assert command_log =~ "./../.aiurconfig"
  end

  test "restarts every configured background profile once per service" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    duplicate|#{ctx.actions_repo}|other.aiurconfig|4102|#{ctx.logs_root}/other|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["--bg", "all"])
    assert output =~ "SYSTEMCTL:--user restart aiur\n"
    assert output =~ "SYSTEMCTL:--user restart aiur-actions\n"
    assert count_occurrences(output, "restart aiur-actions") == 1
  end

  test "no-arg invocation only runs the default profile in the foreground" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, [])
    refute output =~ "SYSTEMCTL:--user restart"
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "src")}"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./../.aiurconfig"
  end

  test "no-arg invocation attaches to an existing default session" do
    ctx = test_context()
    session = aiur_tmux_session("default")

    assert {output, 0} = run_aiur(ctx, [], tmux_has_session: true)
    command_log = command_log(ctx)

    assert output =~ "🪟 attaching to existing default session"
    assert command_log =~ "TMUX:-L #{aiur_tmux_socket()} -f "
    assert command_log =~ "has-session -t #{session}"
    assert command_log =~ "attach -t #{session}"
    refute command_log =~ "new-session"
    refute command_log =~ "PKILL:"
    refute output =~ "MISE:"
  end

  test "profile invocation attaches to an existing profile session" do
    ctx = test_context()
    session = aiur_tmux_session("actions")

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["actions"], tmux_has_session: true)
    command_log = command_log(ctx)

    assert output =~ "🪟 attaching to existing actions session"
    assert command_log =~ "has-session -t #{session}"
    assert command_log =~ "attach -t #{session}"
    refute command_log =~ "new-session"
    refute output =~ "MISE:"
  end

  test "--fresh starts a new foreground session even when one exists" do
    ctx = test_context()
    session = aiur_tmux_session("default")

    assert {output, 0} = run_aiur(ctx, ["--fresh"], tmux_has_session: true)
    command_log = command_log(ctx)

    refute output =~ "🪟 attaching to existing"
    assert command_log =~ "kill-session -t #{session}"
    assert command_log =~ "new-session -d -s #{session}"
    assert output =~ "MISE:exec -- ./bin/aiur"
  end

  test "no-arg invocation replaces background service when no tmux session exists" do
    ctx = test_context()
    session = aiur_tmux_session("default")

    assert {output, 0} =
             run_aiur(ctx, [], env: [{"AIUR_TEST_SYSTEMCTL_ACTIVE", "1"}])

    command_log = command_log(ctx)

    assert output =~
             "⚠️  no attachable default tmux session found; replacing background aiur with a foreground session"

    assert command_log =~ "SYSTEMCTL:--user is-active --quiet aiur\n"
    assert command_log =~ "SYSTEMCTL:--user stop aiur\n"
    assert command_log =~ "has-session -t #{session}"
    assert command_log =~ "new-session -d -s #{session}"
    assert command_log =~ "attach -t #{session}"
    assert output =~ "MISE:exec -- ./bin/aiur"
  end

  test "run starts the default profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["run"])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "src")}"
    assert output =~ "MISE:exec -- ./bin/aiur"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./../.aiurconfig"
  end

  test "runs an ad hoc workflow path with the default repo" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["custom/operator.aiurconfig"])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "src")}"
    assert output =~ "./custom/operator.aiurconfig"
  end

  test "runs an absolute ad hoc workflow path with the default repo" do
    ctx = test_context()
    workflow = Path.join(ctx.actions_repo, "operator.aiurconfig")

    assert {output, 0} = run_aiur(ctx, [workflow])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "src")}"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails #{workflow}"
  end

  test "stops every configured profile by default" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["stop"])
    command_log = command_log(ctx)

    assert command_log =~ "SYSTEMCTL:--user stop aiur\n"
    assert command_log =~ "SYSTEMCTL:--user stop aiur-actions\n"
    assert output =~ "PKILL:-f #{Path.join(ctx.repo_root, "src")}/../.aiurconfig"
    assert output =~ "PKILL:-f #{Path.join(ctx.repo_root, "src")}.*bin/aiur .*--interactive.*../.aiurconfig"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "src")}/actions.aiurconfig"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "src")}.*bin/aiur .*--interactive.*actions.aiurconfig"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "src")}.*bin/aiur .*--interactive.*--logs-root #{ctx.logs_root}/actions"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "src")}.*bin/aiur .*--interactive.*--port 4101"
    refute output =~ "MISE:"
  end

  test "stops a selected profile" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["stop", "actions"])
    command_log = command_log(ctx)

    assert command_log =~ "SYSTEMCTL:--user stop aiur-actions\n"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "src")}/actions.aiurconfig"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "src")}.*bin/aiur .*--interactive.*actions.aiurconfig"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "src")}.*bin/aiur .*--interactive.*--logs-root #{ctx.logs_root}/actions"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "src")}.*bin/aiur .*--interactive.*--port 4101"
    refute command_log =~ "SYSTEMCTL:--user stop aiur\n"
    refute output =~ "MISE:"
  end

  test "default foreground run binds locally via --host 127.0.0.1" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["run", "aiur"])

    assert output =~
             ~r{MISE:exec -- \./bin/aiur --logs-root #{Regex.escape(ctx.home_dir)}/\.aiur/logs/\S+ --host 127\.0\.0\.1}
  end

  test "--host opts out of the local-only injection" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["--host", "run", "aiur"])
    refute output =~ "--host 127.0.0.1"

    assert output =~
             ~r{MISE:exec -- \./bin/aiur --logs-root #{Regex.escape(ctx.home_dir)}/\.aiur/logs/\S+ --interactive}
  end

  test "--port overrides the profile port for foreground runs" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["--port", "4099", "actions"])
    assert output =~ "MISE:exec -- ./bin/aiur --logs-root #{ctx.logs_root}/actions --port 4099"
  end

  test "--port override works with background mode" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["--port", "4099", "--bg", "actions"])
    assert output =~ "aiur-actions started in background"

    command_log = await_command_log(ctx, "NOHUP:")
    assert command_log =~ "NOHUP:#{ctx.fake_mise} exec -- ./bin/aiur"
    assert command_log =~ "--port 4099"
    assert command_log =~ "SYSTEMCTL:--user stop aiur-actions"
    refute command_log =~ "SYSTEMCTL:--user restart aiur-actions"
  end

  test "pause parses space and comma separated issue IDs for release RPC" do
    ctx = test_context()
    write_fake_release_rpc!(ctx, "aiur: paused #44 (was: running)\n__AIUR_CONTROL_EXIT__:0\n")

    assert {output, 0} = run_aiur(ctx, ["pause", "44", "45,46"])

    assert output =~ "aiur: paused #44 (was: running)"
    refute output =~ "__AIUR_CONTROL_EXIT__"

    command_log = command_log(ctx)
    assert command_log =~ ~S|AIUR_RELEASE:rpc Aiur.AgentControlCLI.pause(["44", "45", "46"])| <> "\n"
    assert command_log =~ "RELEASE_DISTRIBUTION=name\n"
    assert command_log =~ "RELEASE_NODE=aiurdev-"
  end

  test "pause --all targets the all snapshot helper" do
    ctx = test_context()
    write_fake_release_rpc!(ctx, "aiur: paused #44 (was: running)\n__AIUR_CONTROL_EXIT__:0\n")

    assert {output, 0} = run_aiur(ctx, ["pause", "--all"])

    assert output =~ "aiur: paused #44"
    assert command_log(ctx) =~ "AIUR_RELEASE:rpc Aiur.AgentControlCLI.pause(:all)\n"
  end

  test "resume --all targets paused agents through release RPC" do
    ctx = test_context()
    write_fake_release_rpc!(ctx, "aiur: resumed #44 (was: paused)\n__AIUR_CONTROL_EXIT__:0\n")

    assert {output, 0} = run_aiur(ctx, ["resume", "--all"])

    assert output =~ "aiur: resumed #44"
    assert command_log(ctx) =~ "AIUR_RELEASE:rpc Aiur.AgentControlCLI.resume(:all)\n"
  end

  test "status calls the release RPC status helper" do
    ctx = test_context()
    write_fake_release_rpc!(ctx, "ISSUE STATE   TITLE\n#44   running Test\n__AIUR_CONTROL_EXIT__:0\n")

    assert {output, 0} = run_aiur(ctx, ["status"])

    assert output =~ "ISSUE STATE"
    assert output =~ "#44"
    assert command_log(ctx) =~ "AIUR_RELEASE:rpc Aiur.AgentControlCLI.status()\n"
  end

  test "pause rejects invalid issue IDs without calling release RPC" do
    ctx = test_context()
    write_fake_release_rpc!(ctx, "__AIUR_CONTROL_EXIT__:0\n")

    assert {output, 64} = run_aiur(ctx, ["pause", "44,bad"])

    assert output =~ "aiurdev: pause expects issue IDs or --all"
    refute File.exists?(ctx.command_log) && command_log(ctx) =~ "AIUR_RELEASE:"
  end

  test "pause reports a clear error when no aiur node is running" do
    ctx = test_context()
    write_fake_release_rpc!(ctx, ":noconnection\n", exit_status: 1)

    assert {output, 1} = run_aiur(ctx, ["pause", "44"])

    assert output =~ "aiurdev: no running aiur node"
    refute output =~ ":noconnection"
  end

  test "auto-increments a busy configured profile port" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} =
             run_aiur(ctx, ["actions"], env: [{"AIUR_TEST_BUSY_PORTS", "4101,4102"}])

    assert output =~
             "⚠️  port 4101 in use; bound to 4103 instead (run with `--port` to override)"

    assert output =~ "MISE:exec -- ./bin/aiur --logs-root #{ctx.logs_root}/actions --port 4103"
  end

  test "auto-increments a busy workflow port when no profile port is set" do
    ctx = test_context()

    File.write!(Path.join(ctx.repo_root, ".aiurconfig"), """
    server:
      host: 127.0.0.1
      port: 4000
    """)

    assert {output, 0} =
             run_aiur(ctx, ["aiur"], env: [{"AIUR_TEST_BUSY_PORTS", "4000"}])

    assert output =~
             "⚠️  port 4000 in use; bound to 4001 instead (run with `--port` to override)"

    assert output =~
             ~r{MISE:exec -- \./bin/aiur --logs-root #{Regex.escape(ctx.home_dir)}/\.aiur/logs/\S+ --port 4001}
  end

  test "surfaces startup output when all auto-increment ports are busy" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    busy_ports = Enum.map_join(4101..4110, ",", &to_string/1)

    assert {output, 1} =
             run_aiur(ctx, ["actions"],
               env: [
                 {"AIUR_TEST_BUSY_PORTS", busy_ports},
                 {"AIUR_TEST_MISE_FAIL", "1"}
               ]
             )

    assert output =~ "❌ Aiur exited during startup"
    assert output =~ "Failed to start Aiur: {:shutdown, :eaddrinuse}"
    assert output =~ "Hint: port already in use."
    assert output =~ "try `aiurdev --port <N>`"
  end

  test "auto-rebuilds bin/aiur when missing" do
    ctx = test_context()
    write_mix_lock!(ctx, ["jason"])

    # The repo_root/src dir has no deps, _build, or bin/aiur, so
    # ensure_built should fetch deps, compile, then build the escript.
    assert {output, 0} = run_aiur(ctx, ["run", "aiur"], skip_build: false)

    assert output =~ "🔨 fetching and compiling Hex dependencies"
    assert output =~ "MISE:exec -- mix deps.get"
    assert output =~ "MISE:exec -- mix compile"
    assert output =~ "🔨 rebuilding bin/aiur"
    assert output =~ "MISE:exec -- mix release --overwrite"
    # The real Aiur invocation still runs after the rebuild step.
    assert output =~ "MISE:exec -- ./bin/aiur"
  end

  test "fetches dependencies when a locked dep directory is missing" do
    ctx = test_context()
    elixir_dir = Path.join(ctx.repo_root, "src")

    write_mix_lock!(ctx, ["jason", "ecto"])
    File.mkdir_p!(Path.join(elixir_dir, "_build"))
    File.mkdir_p!(Path.join(elixir_dir, "deps/jason"))
    File.mkdir_p!(Path.join(elixir_dir, "bin"))
    write_executable!(Path.join(elixir_dir, "bin/aiur"), "#!/usr/bin/env bash\n")

    assert {output, 0} = run_aiur(ctx, ["run", "aiur"], skip_build: false)

    assert output =~ "🔨 fetching and compiling Hex dependencies"
    assert output =~ "MISE:exec -- mix deps.get"
    assert output =~ "MISE:exec -- mix compile"
    assert output =~ "MISE:exec -- ./bin/aiur"
  end

  test "build command fetches dependencies before rebuilding" do
    ctx = test_context()
    write_mix_lock!(ctx, ["jason"])

    assert {output, 0} = run_aiur(ctx, ["build"], skip_build: false)

    assert output =~ "🔨 fetching and compiling Hex dependencies"
    assert output =~ "MISE:exec -- mix deps.get"
    assert output =~ "MISE:exec -- mix compile"
    assert output =~ "🔨 rebuilding bin/aiur"
    assert output =~ "MISE:exec -- mix release --overwrite"
    refute output =~ "MISE:exec -- ./bin/aiur"
  end

  test "skips dependency bootstrap when build and locked deps exist" do
    ctx = test_context()
    elixir_dir = Path.join(ctx.repo_root, "src")

    write_mix_lock!(ctx, ["jason", "ecto"])
    File.mkdir_p!(Path.join(elixir_dir, "_build"))
    File.mkdir_p!(Path.join(elixir_dir, "deps/jason"))
    File.mkdir_p!(Path.join(elixir_dir, "deps/ecto"))
    File.mkdir_p!(Path.join(elixir_dir, "bin"))
    aiur_bin = Path.join(elixir_dir, "bin/aiur")
    write_executable!(aiur_bin, "#!/usr/bin/env bash\n")
    File.touch!(aiur_bin, {{2099, 1, 1}, {0, 0, 0}})

    assert {output, 0} = run_aiur(ctx, ["run", "aiur"], skip_build: false)

    refute output =~ "MISE:exec -- mix deps.get"
    refute output =~ "MISE:exec -- mix compile"
    refute output =~ "MISE:exec -- mix escript.build"
    assert output =~ "MISE:exec -- ./bin/aiur"
  end

  test "resolves repo root when invoked through a symlink" do
    # Regression: when the script is invoked via a symlink on PATH (e.g.
    # ~/.local/bin/aiurdev → ../github.com/its-everdred/aiur/scripts/aiurdev),
    # BASH_SOURCE points to the symlink. Without symlink resolution,
    # script_dir = ~/.local/bin and repo_root falls back to ~/.local,
    # so `cd $repo_root/src` fails with "No such file or directory".
    ctx = test_context()
    real_repo = Path.expand("../..", @script)

    symlink_dir =
      Path.join(System.tmp_dir!(), "aiur-symlink-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(symlink_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(symlink_dir) end)
    symlink = Path.join(symlink_dir, "aiurdev")
    File.ln_s!(@script, symlink)

    # Invoke via the symlink WITHOUT AIUR_REPO_ROOT — force the script to
    # compute repo_root from its own location.
    {output, status} =
      System.cmd("bash", [symlink, "aiur"],
        env: [
          {"AIUR_CONFIG_FILE", ctx.config_file},
          {"AIUR_ENV_FILE", Path.join(ctx.repo_root, "missing.env")},
          {"AIUR_MISE_BIN", ctx.fake_mise},
          {"AIUR_SYSTEMCTL_BIN", ctx.fake_systemctl},
          {"AIUR_PKILL_BIN", ctx.fake_pkill},
          {"AIUR_NOHUP_BIN", ctx.fake_nohup},
          {"AIUR_KILL_BIN", ctx.fake_kill},
          {"AIUR_TMUX_BIN", ctx.fake_tmux},
          {"AIUR_BG_STATE_DIR", ctx.bg_state_dir},
          {"AIUR_OS_OVERRIDE", "Linux"},
          {"AIUR_SKIP_BUILD", "1"},
          {"AIUR_TEST_COMMAND_LOG", ctx.command_log},
          {"XDG_RUNTIME_DIR", ctx.runtime_dir},
          {"HOME", ctx.home_dir},
          {"TMUX", ""}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "PWD=#{Path.join(real_repo, "src")}"
    refute output =~ "No such file or directory"
  end

  describe "macOS (Darwin) background mode" do
    test "--bg writes a PID file and invokes nohup, not systemctl" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
      """)

      assert {output, 0} = run_aiur(ctx, ["--bg", "actions"], os: "Darwin")

      pid_file = Path.join(ctx.bg_state_dir, "aiur-actions.pid")
      assert File.exists?(pid_file)
      assert {pid, ""} = Integer.parse(File.read!(pid_file) |> String.trim())
      assert is_integer(pid)
      assert output =~ "aiur-actions started in background"

      command_log = await_command_log(ctx, "NOHUP:")
      assert command_log =~ "NOHUP:#{ctx.fake_mise} exec -- ./bin/aiur"
      assert command_log =~ "--port 4101"
      assert command_log =~ "./actions.aiurconfig"
      refute command_log =~ "SYSTEMCTL:"
    end

    test "--bg all starts each unique service once via nohup" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
      duplicate|#{ctx.actions_repo}|other.aiurconfig|4102|#{ctx.logs_root}/other|aiur-actions
      """)

      assert {_output, 0} = run_aiur(ctx, ["--bg", "all"], os: "Darwin")

      assert File.exists?(Path.join(ctx.bg_state_dir, "aiur.pid"))
      assert File.exists?(Path.join(ctx.bg_state_dir, "aiur-actions.pid"))

      # Both nohups run detached; poll until both lines have flushed.
      command_log =
        await_command_log_count(
          ctx,
          "NOHUP:#{ctx.fake_mise} exec -- ./bin/aiur",
          2
        )

      assert count_occurrences(command_log, "NOHUP:#{ctx.fake_mise} exec -- ./bin/aiur") == 2
      assert command_log =~ "../.aiurconfig"
      assert command_log =~ "actions.aiurconfig"
      refute command_log =~ "SYSTEMCTL:"
    end

    test "stop reads the PID file, sends SIGTERM, and removes the file" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
      """)

      File.mkdir_p!(ctx.bg_state_dir)
      pid_file = Path.join(ctx.bg_state_dir, "aiur-actions.pid")
      File.write!(pid_file, "424242\n")

      assert {_output, 0} = run_aiur(ctx, ["stop", "actions"], os: "Darwin")
      command_log = command_log(ctx)

      assert command_log =~ "KILL:-TERM 424242\n"
      refute command_log =~ "SYSTEMCTL:"
      refute File.exists?(pid_file)
    end

    test "stop tolerates a missing PID file" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|actions.aiurconfig|4101|#{ctx.logs_root}/actions|aiur-actions
      """)

      assert {_output, 0} = run_aiur(ctx, ["stop", "actions"], os: "Darwin")
      command_log = command_log(ctx)

      refute command_log =~ "KILL:-TERM"
      refute command_log =~ "SYSTEMCTL:"
    end
  end

  defp test_context do
    root = Path.join(System.tmp_dir!(), "aiur-script-test-#{System.unique_integer([:positive])}")
    repo_root = Path.join(root, "aiur")
    actions_repo = Path.join(root, "actions")
    home_dir = Path.join(root, "home")
    bin_dir = Path.join(root, "bin")
    config_file = Path.join(root, "aiur.profiles")
    logs_root = Path.join(root, "logs")
    command_log = Path.join(root, "commands.log")
    bg_state_dir = Path.join(root, "bg-state")
    runtime_dir = Path.join(root, "runtime")

    # System.unique_integer resets per VM, so stale tmp dirs from prior
    # `mix test` runs can collide. Clear before setting up.
    File.rm_rf!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(repo_root, "src"))
    File.mkdir_p!(Path.join(actions_repo, "src"))
    File.mkdir_p!(Path.join(home_dir, ".config/aiurdev"))
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(logs_root)
    File.mkdir_p!(bg_state_dir)
    File.mkdir_p!(runtime_dir)
    File.mkdir_p!(home_dir)

    fake_mise = Path.join(bin_dir, "mise")
    fake_systemctl = Path.join(bin_dir, "systemctl")
    fake_pkill = Path.join(bin_dir, "pkill")
    fake_nohup = Path.join(bin_dir, "nohup")
    fake_kill = Path.join(bin_dir, "kill")
    fake_tmux = Path.join(bin_dir, "tmux")
    fake_port_check = Path.join(bin_dir, "port-check")

    write_executable!(fake_mise, """
    #!/usr/bin/env bash
    {
      printf 'PWD=%s\\n' "$PWD"
      printf 'MISE:%s\\n' "$*"
    } | tee -a "$AIUR_TEST_COMMAND_LOG"

    if [ "${AIUR_TEST_MISE_FAIL:-0}" = "1" ]; then
      printf 'Failed to start Aiur: {:shutdown, :eaddrinuse}\\n'
      exit 1
    fi
    """)

    write_executable!(fake_systemctl, """
    #!/usr/bin/env bash
    printf 'SYSTEMCTL:%s\\n' "$*" | tee -a "$AIUR_TEST_COMMAND_LOG"

    if [ "${1:-}" = "--user" ] && [ "${2:-}" = "restart" ] && [ "${AIUR_TEST_SYSTEMCTL_RESTART_FAIL:-0}" = "1" ]; then
      printf 'Failed to restart %s.service: Unit %s.service not found.\\n' "${3:-}" "${3:-}" >&2
      exit 5
    fi

    if [ "${1:-}" = "--user" ] && [ "${2:-}" = "is-active" ]; then
      if [ "${AIUR_TEST_SYSTEMCTL_ACTIVE:-0}" = "1" ]; then
        exit 0
      else
        exit 3
      fi
    fi
    """)

    write_executable!(fake_pkill, """
    #!/usr/bin/env bash
    printf 'PKILL:%s\\n' "$*" | tee -a "$AIUR_TEST_COMMAND_LOG"
    """)

    write_executable!(fake_nohup, """
    #!/usr/bin/env bash
    printf 'NOHUP:%s\\n' "$*" >>"$AIUR_TEST_COMMAND_LOG"
    sleep 0 &
    """)

    write_executable!(fake_kill, """
    #!/usr/bin/env bash
    printf 'KILL:%s\\n' "$*" | tee -a "$AIUR_TEST_COMMAND_LOG"
    """)

    write_executable!(fake_tmux, """
    #!/usr/bin/env bash
    printf 'TMUX:%s\\n' "$*" >>"$AIUR_TEST_COMMAND_LOG"
    state_file="${AIUR_TEST_TMUX_STATE:-$AIUR_TEST_COMMAND_LOG.tmux-state}"

    # Skip past the isolated-socket/conf prefix so the case below still
    # matches the actual subcommand.
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -L|-f)
          shift 2
          ;;
        *)
          break
          ;;
      esac
    done

    case "${1:-}" in
      -V)
        printf 'tmux 3.5a\\n'
        ;;
      has-session)
        [ -f "$state_file" ]
        ;;
      new-session)
        # Run the inner command synchronously so the assertions that look
        # for MISE/PWD output keep working.
        inner_cmd="${!#}"
        if bash -c "$inner_cmd"; then
          : >"$state_file"
        fi
        ;;
      attach|kill-session)
        rm -f "$state_file"
        :
        ;;
    esac
    """)

    write_executable!(fake_port_check, """
    #!/usr/bin/env bash
    port="$1"
    IFS=',' read -ra busy_ports <<<"${AIUR_TEST_BUSY_PORTS:-}"
    for busy_port in "${busy_ports[@]}"; do
      if [ "$port" = "$busy_port" ]; then
        exit 0
      fi
    done
    exit 1
    """)

    %{
      repo_root: repo_root,
      actions_repo: actions_repo,
      home_dir: home_dir,
      config_file: config_file,
      logs_root: logs_root,
      command_log: command_log,
      bg_state_dir: bg_state_dir,
      runtime_dir: runtime_dir,
      fake_mise: fake_mise,
      fake_systemctl: fake_systemctl,
      fake_pkill: fake_pkill,
      fake_nohup: fake_nohup,
      fake_kill: fake_kill,
      fake_tmux: fake_tmux,
      fake_port_check: fake_port_check
    }
  end

  defp write_profiles!(ctx, body) do
    File.write!(ctx.config_file, body)
  end

  defp write_mix_lock!(ctx, deps) do
    entries =
      deps
      |> Enum.map_join("\n", fn dep -> ~s(  "#{dep}": {:hex, :#{dep}, "1.0.0"},) end)

    File.write!(Path.join([ctx.repo_root, "src", "mix.lock"]), "%{\n#{entries}\n}\n")
  end

  defp write_fake_release_rpc!(ctx, body, opts \\ []) do
    exit_status = Keyword.get(opts, :exit_status, 0)
    release_bin = Path.join([ctx.repo_root, "src", "_build", "dev", "rel", "aiur", "bin"])
    File.mkdir_p!(release_bin)

    write_executable!(Path.join(release_bin, "aiur"), """
    #!/usr/bin/env bash
    {
      printf 'AIUR_RELEASE:%s\\n' "$*"
      printf 'RELEASE_DISTRIBUTION=%s\\n' "${RELEASE_DISTRIBUTION:-}"
      printf 'RELEASE_NODE=%s\\n' "${RELEASE_NODE:-}"
      printf 'RELEASE_COOKIE_SET=%s\\n' "${RELEASE_COOKIE:+1}"
    } >>"$AIUR_TEST_COMMAND_LOG"

    printf '%b' #{inspect(body)}
    exit #{exit_status}
    """)
  end

  defp run_aiur(ctx, args, opts \\ []) do
    os_override = Keyword.get(opts, :os, "Linux")
    skip_build = if Keyword.get(opts, :skip_build, true), do: "1", else: "0"
    extra_env = Keyword.get(opts, :env, [])
    tmux_state = Path.join(ctx.bg_state_dir, "tmux-state")

    if Keyword.get(opts, :tmux_has_session, false) do
      File.mkdir_p!(ctx.bg_state_dir)
      File.write!(tmux_state, "")
    end

    System.cmd("bash", [@script | args],
      env:
        [
          {"AIUR_REPO_ROOT", ctx.repo_root},
          {"AIUR_CONFIG_FILE", ctx.config_file},
          {"AIUR_ENV_FILE", Path.join(ctx.repo_root, "missing.env")},
          {"AIUR_MISE_BIN", ctx.fake_mise},
          {"AIUR_SYSTEMCTL_BIN", ctx.fake_systemctl},
          {"AIUR_PKILL_BIN", ctx.fake_pkill},
          {"AIUR_NOHUP_BIN", ctx.fake_nohup},
          {"AIUR_KILL_BIN", ctx.fake_kill},
          {"AIUR_TMUX_BIN", ctx.fake_tmux},
          {"AIUR_BG_STATE_DIR", ctx.bg_state_dir},
          {"AIUR_OS_OVERRIDE", os_override},
          {"AIUR_SKIP_BUILD", skip_build},
          {"AIUR_TEST_COMMAND_LOG", ctx.command_log},
          {"AIUR_TEST_TMUX_STATE", tmux_state},
          {"AIUR_STARTUP_GRACE_TICKS", "1"},
          {"AIUR_STARTUP_GRACE_SLEEP", "0"},
          {"AIUR_PORT_CHECK_BIN", ctx.fake_port_check},
          {"XDG_RUNTIME_DIR", ctx.runtime_dir},
          {"HOME", ctx.home_dir},
          {"TMUX", ""}
        ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp write_executable!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp count_occurrences(text, pattern) do
    text
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp aiur_tmux_session(profile) do
    "aiurdev-#{System.get_env("USER") || "user"}-#{profile}"
  end

  defp aiur_tmux_socket do
    "aiurdev-#{System.get_env("USER") || "user"}"
  end

  defp command_log(ctx) do
    File.read!(ctx.command_log)
  end

  # nohup runs detached in --bg paths, so its log write races with the script
  # returning. Poll until the expected marker appears or the deadline elapses.
  defp await_command_log(ctx, substring, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_command_log(ctx, substring, deadline)
  end

  defp do_await_command_log(ctx, substring, deadline) do
    contents =
      case File.read(ctx.command_log) do
        {:ok, c} -> c
        _ -> ""
      end

    cond do
      String.contains?(contents, substring) ->
        contents

      System.monotonic_time(:millisecond) >= deadline ->
        contents

      true ->
        Process.sleep(20)
        do_await_command_log(ctx, substring, deadline)
    end
  end

  # Poll until the command log contains at least `expected_count` occurrences of
  # `substring`. Used when multiple detached writers append concurrently.
  defp await_command_log_count(ctx, substring, expected_count, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_command_log_count(ctx, substring, expected_count, deadline)
  end

  defp do_await_command_log_count(ctx, substring, expected_count, deadline) do
    contents =
      case File.read(ctx.command_log) do
        {:ok, c} -> c
        _ -> ""
      end

    cond do
      count_occurrences(contents, substring) >= expected_count ->
        contents

      System.monotonic_time(:millisecond) >= deadline ->
        contents

      true ->
        Process.sleep(20)
        do_await_command_log_count(ctx, substring, expected_count, deadline)
    end
  end
end
