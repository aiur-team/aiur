defmodule ScriptsAiurTest do
  use ExUnit.Case, async: true

  @script Path.expand("../scripts/aiur", __DIR__)

  test "prints help without starting anything" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["--help"])
    assert output =~ "Usage: aiur"
    refute output =~ "MISE:"
    refute output =~ "SYSTEMCTL:"
    refute output =~ "PKILL:"
  end

  test "rejects unknown profiles" do
    ctx = test_context()

    assert {output, 64} = run_aiur(ctx, ["missing"])
    assert output =~ "Unknown profile: missing"
    assert output =~ "Usage: aiur"
    refute output =~ "MISE:"
  end

  test "lists built-in and configured profiles" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["list"])
    assert output =~ "default"
    assert output =~ "aiur"
    assert output =~ "actions"
    assert output =~ "WORKFLOW.actions.md"
    assert output =~ "aiur-actions"
  end

  test "runs a configured profile in the foreground" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["actions"])
    assert output =~ "PKILL:-f #{ctx.actions_repo}/WORKFLOW.actions.md"
    assert output =~ "PWD=#{ctx.actions_repo}"
    assert output =~ "MISE:exec -- ./bin/aiur --logs-root #{ctx.logs_root}/actions --port 4101"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.actions.md"
  end

  test "runs the built-in aiur profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["aiur"])
    assert output =~ "PWD=#{ctx.repo_root}"
    assert output =~ "MISE:exec -- ./bin/aiur"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./local-workflows/WORKFLOW.aiur.local.md"
  end

  test "runs the built-in actions profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["actions"])
    assert output =~ "PWD=#{ctx.repo_root}"
    assert output =~ "MISE:exec -- ./bin/aiur"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./local-workflows/WORKFLOW.actions.local.md"
  end

  test "restarts a selected background profile" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["--bg", "actions"])
    assert output =~ "SYSTEMCTL:--user restart aiur-actions\n"
    assert output =~ "SYSTEMCTL:--user status aiur-actions --no-pager\n"
    refute output =~ "MISE:"
    refute output =~ "restart aiur\n"
  end

  test "restarts every configured background profile once per service" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
    duplicate|#{ctx.actions_repo}|WORKFLOW.other.md|4102|#{ctx.logs_root}/other|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["--bg", "all"])
    assert output =~ "SYSTEMCTL:--user restart aiur\n"
    assert output =~ "SYSTEMCTL:--user restart aiur-actions\n"
    assert count_occurrences(output, "restart aiur-actions") == 1
  end

  test "no-arg invocation only runs the default profile in the foreground" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, [])
    refute output =~ "SYSTEMCTL:--user restart"
    assert output =~ "PWD=#{ctx.repo_root}"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./local-workflows/WORKFLOW.aiur.local.md"
  end

  test "run starts the default profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["run"])
    assert output =~ "PWD=#{ctx.repo_root}"
    assert output =~ "MISE:exec -- ./bin/aiur"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./local-workflows/WORKFLOW.aiur.local.md"
  end

  test "runs an ad hoc workflow path with the default repo" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["custom/WORKFLOW.md"])
    assert output =~ "PWD=#{ctx.repo_root}"
    assert output =~ "./custom/WORKFLOW.md"
  end

  test "runs an absolute ad hoc workflow path with the default repo" do
    ctx = test_context()
    workflow = Path.join(ctx.actions_repo, "WORKFLOW.custom.md")

    assert {output, 0} = run_aiur(ctx, [workflow])
    assert output =~ "PWD=#{ctx.repo_root}"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails #{workflow}"
  end

  test "stops every configured profile by default" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["stop"])
    command_log = command_log(ctx)

    assert command_log =~ "SYSTEMCTL:--user stop aiur\n"
    assert command_log =~ "SYSTEMCTL:--user stop aiur-actions\n"
    assert output =~ "PKILL:-f #{ctx.repo_root}/local-workflows/WORKFLOW.aiur.local.md"
    assert output =~ "PKILL:-f bin/aiur .*--interactive.*local-workflows/WORKFLOW.aiur.local.md"
    assert output =~ "PKILL:-f #{ctx.actions_repo}/WORKFLOW.actions.md"
    assert output =~ "PKILL:-f bin/aiur .*--interactive.*WORKFLOW.actions.md"
    assert output =~ "PKILL:-f bin/aiur .*--interactive.*--logs-root #{ctx.logs_root}/actions"
    assert output =~ "PKILL:-f bin/aiur .*--interactive.*--port 4101"
    refute output =~ "MISE:"
  end

  test "stops a selected profile" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
    """)

    assert {output, 0} = run_aiur(ctx, ["stop", "actions"])
    command_log = command_log(ctx)

    assert command_log =~ "SYSTEMCTL:--user stop aiur-actions\n"
    assert output =~ "PKILL:-f #{ctx.actions_repo}/WORKFLOW.actions.md"
    assert output =~ "PKILL:-f bin/aiur .*--interactive.*WORKFLOW.actions.md"
    assert output =~ "PKILL:-f bin/aiur .*--interactive.*--logs-root #{ctx.logs_root}/actions"
    assert output =~ "PKILL:-f bin/aiur .*--interactive.*--port 4101"
    refute command_log =~ "SYSTEMCTL:--user stop aiur\n"
    refute output =~ "MISE:"
  end

  test "default foreground run binds locally via --host 127.0.0.1" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["run", "aiur"])
    assert output =~ "MISE:exec -- ./bin/aiur --host 127.0.0.1"
  end

  test "--host opts out of the local-only injection" do
    ctx = test_context()

    assert {output, 0} = run_aiur(ctx, ["--host", "run", "aiur"])
    refute output =~ "--host 127.0.0.1"
    assert output =~ "MISE:exec -- ./bin/aiur --interactive"
  end

  test "auto-rebuilds bin/aiur when missing" do
    ctx = test_context()
    # The repo root is empty by default — bin/aiur does not
    # exist, so ensure_built should call `mix escript.build` via fake mise.
    assert {output, 0} = run_aiur(ctx, ["run", "aiur"], skip_build: false)

    assert output =~ "aiur: rebuilding bin/aiur"
    assert output =~ "MISE:exec -- mix escript.build"
    # The real Aiur invocation still runs after the rebuild step.
    assert output =~ "MISE:exec -- ./bin/aiur"
  end

  test "resolves repo root when invoked through a symlink" do
    # Regression: when the script is invoked via a symlink on PATH (e.g.
    # ~/.local/bin/aiur → ../github.com/its-everdred/aiur/scripts/aiur),
    # BASH_SOURCE points to the symlink. Without symlink resolution,
    # script_dir = ~/.local/bin and repo_root falls back to ~/.local,
    # so `cd $repo_root` fails with "No such file or directory".
    ctx = test_context()
    real_repo = Path.expand("../..", @script)

    symlink_dir =
      Path.join(System.tmp_dir!(), "aiur-symlink-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(symlink_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(symlink_dir) end)
    symlink = Path.join(symlink_dir, "aiur")
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
          {"HOME", ctx.home_dir},
          {"TMUX", ""}
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "PWD=#{real_repo}"
    refute output =~ "No such file or directory"
  end

  describe "macOS (Darwin) background mode" do
    test "--bg writes a PID file and invokes nohup, not systemctl" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
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
      assert command_log =~ "./WORKFLOW.actions.md"
      refute command_log =~ "SYSTEMCTL:"
    end

    test "--bg all starts each unique service once via nohup" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
      duplicate|#{ctx.actions_repo}|WORKFLOW.other.md|4102|#{ctx.logs_root}/other|aiur-actions
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
      assert command_log =~ "local-workflows/WORKFLOW.aiur.local.md"
      assert command_log =~ "WORKFLOW.actions.md"
      refute command_log =~ "SYSTEMCTL:"
    end

    test "stop reads the PID file, sends SIGTERM, and removes the file" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
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
      actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|aiur-actions
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
    bin_dir = Path.join(root, "bin")
    config_file = Path.join(root, "aiur.profiles")
    logs_root = Path.join(root, "logs")
    command_log = Path.join(root, "commands.log")
    bg_state_dir = Path.join(root, "bg-state")
    home_dir = Path.join(root, "home")

    # System.unique_integer resets per VM, so stale tmp dirs from prior
    # `mix test` runs can collide. Clear before setting up.
    File.rm_rf!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(repo_root)
    File.mkdir_p!(actions_repo)
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(logs_root)
    File.mkdir_p!(home_dir)

    fake_mise = Path.join(bin_dir, "mise")
    fake_systemctl = Path.join(bin_dir, "systemctl")
    fake_pkill = Path.join(bin_dir, "pkill")
    fake_nohup = Path.join(bin_dir, "nohup")
    fake_kill = Path.join(bin_dir, "kill")
    fake_tmux = Path.join(bin_dir, "tmux")

    write_executable!(fake_mise, """
    #!/usr/bin/env bash
    {
      printf 'PWD=%s\\n' "$PWD"
      printf 'MISE:%s\\n' "$*"
    } | tee -a "$AIUR_TEST_COMMAND_LOG"
    """)

    write_executable!(fake_systemctl, """
    #!/usr/bin/env bash
    printf 'SYSTEMCTL:%s\\n' "$*" | tee -a "$AIUR_TEST_COMMAND_LOG"
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
        # Always report no existing session in tests.
        exit 1
        ;;
      new-session)
        # Run the inner command synchronously so the assertions that look
        # for MISE/PWD output keep working.
        inner_cmd="${!#}"
        bash -c "$inner_cmd"
        ;;
      attach|kill-session)
        :
        ;;
    esac
    """)

    %{
      repo_root: repo_root,
      actions_repo: actions_repo,
      config_file: config_file,
      logs_root: logs_root,
      command_log: command_log,
      bg_state_dir: bg_state_dir,
      home_dir: home_dir,
      fake_mise: fake_mise,
      fake_systemctl: fake_systemctl,
      fake_pkill: fake_pkill,
      fake_nohup: fake_nohup,
      fake_kill: fake_kill,
      fake_tmux: fake_tmux
    }
  end

  defp write_profiles!(ctx, body) do
    File.write!(ctx.config_file, body)
  end

  defp run_aiur(ctx, args, opts \\ []) do
    os_override = Keyword.get(opts, :os, "Linux")
    skip_build = if Keyword.get(opts, :skip_build, true), do: "1", else: "0"

    System.cmd("bash", [@script | args],
      env: [
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
        {"HOME", ctx.home_dir},
        {"TMUX", ""}
      ],
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
