defmodule ScriptsAgentsTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/agents", __DIR__)

  test "prints help without starting anything" do
    ctx = test_context()

    assert {output, 0} = run_agents(ctx, ["--help"])
    assert output =~ "Usage: agents"
    refute output =~ "MISE:"
    refute output =~ "SYSTEMCTL:"
    refute output =~ "PKILL:"
  end

  test "rejects unknown profiles" do
    ctx = test_context()

    assert {output, 64} = run_agents(ctx, ["missing"])
    assert output =~ "Unknown profile: missing"
    assert output =~ "Usage: agents"
    refute output =~ "MISE:"
  end

  test "lists built-in and configured profiles" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
    """)

    assert {output, 0} = run_agents(ctx, ["list"])
    assert output =~ "default"
    assert output =~ "symphony"
    assert output =~ "actions"
    assert output =~ "WORKFLOW.actions.md"
    assert output =~ "symphony-actions"
  end

  test "runs a configured profile in the foreground" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
    """)

    assert {output, 0} = run_agents(ctx, ["actions"])
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "elixir")}/WORKFLOW.actions.md"
    assert output =~ "PWD=#{Path.join(ctx.actions_repo, "elixir")}"
    assert output =~ "MISE:exec -- ./bin/symphony agents-pane --logs-root #{ctx.logs_root}/actions --port 4101"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.actions.md"
  end

  test "runs the built-in symphony profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_agents(ctx, ["symphony"])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"
    assert output =~ "MISE:exec -- ./bin/symphony"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./local-workflows/WORKFLOW.symphony.local.md"
  end

  test "runs the built-in actions profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_agents(ctx, ["actions"])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"
    assert output =~ "MISE:exec -- ./bin/symphony"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./local-workflows/WORKFLOW.actions.local.md"
  end

  test "restarts a selected background profile" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
    """)

    assert {output, 0} = run_agents(ctx, ["--bg", "actions"])
    assert output =~ "SYSTEMCTL:--user restart symphony-actions\n"
    assert output =~ "SYSTEMCTL:--user status symphony-actions --no-pager\n"
    refute output =~ "MISE:"
    refute output =~ "restart symphony\n"
  end

  test "restarts every configured background profile once per service" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
    duplicate|#{ctx.actions_repo}|WORKFLOW.other.md|4102|#{ctx.logs_root}/other|symphony-actions
    """)

    assert {output, 0} = run_agents(ctx, ["--bg", "all"])
    assert output =~ "SYSTEMCTL:--user restart symphony\n"
    assert output =~ "SYSTEMCTL:--user restart symphony-actions\n"
    assert count_occurrences(output, "restart symphony-actions") == 1
  end

  test "no-arg invocation only runs the default profile in the foreground" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
    """)

    assert {output, 0} = run_agents(ctx, [])
    refute output =~ "SYSTEMCTL:--user restart"
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./local-workflows/WORKFLOW.symphony.local.md"
  end

  test "run starts the default profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_agents(ctx, ["run"])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"
    assert output =~ "MISE:exec -- ./bin/symphony"

    assert output =~
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./local-workflows/WORKFLOW.symphony.local.md"
  end

  test "runs an ad hoc workflow path with the default repo" do
    ctx = test_context()

    assert {output, 0} = run_agents(ctx, ["custom/WORKFLOW.md"])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"
    assert output =~ "./custom/WORKFLOW.md"
  end

  test "runs an absolute ad hoc workflow path with the default repo" do
    ctx = test_context()
    workflow = Path.join(ctx.actions_repo, "WORKFLOW.custom.md")

    assert {output, 0} = run_agents(ctx, [workflow])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails #{workflow}"
  end

  test "stops every configured profile by default" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
    """)

    assert {output, 0} = run_agents(ctx, ["stop"])
    command_log = command_log(ctx)

    assert command_log =~ "SYSTEMCTL:--user stop symphony\n"
    assert command_log =~ "SYSTEMCTL:--user stop symphony-actions\n"
    assert output =~ "PKILL:-f #{Path.join(ctx.repo_root, "elixir")}/local-workflows/WORKFLOW.symphony.local.md"
    assert output =~ "PKILL:-f bin/symphony .*--interactive.*local-workflows/WORKFLOW.symphony.local.md"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "elixir")}/WORKFLOW.actions.md"
    assert output =~ "PKILL:-f bin/symphony .*--interactive.*WORKFLOW.actions.md"
    assert output =~ "PKILL:-f bin/symphony .*--interactive.*--logs-root #{ctx.logs_root}/actions"
    assert output =~ "PKILL:-f bin/symphony .*--interactive.*--port 4101"
    refute output =~ "MISE:"
  end

  test "stops a selected profile" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
    """)

    assert {output, 0} = run_agents(ctx, ["stop", "actions"])
    command_log = command_log(ctx)

    assert command_log =~ "SYSTEMCTL:--user stop symphony-actions\n"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "elixir")}/WORKFLOW.actions.md"
    assert output =~ "PKILL:-f bin/symphony .*--interactive.*WORKFLOW.actions.md"
    assert output =~ "PKILL:-f bin/symphony .*--interactive.*--logs-root #{ctx.logs_root}/actions"
    assert output =~ "PKILL:-f bin/symphony .*--interactive.*--port 4101"
    refute command_log =~ "SYSTEMCTL:--user stop symphony\n"
    refute output =~ "MISE:"
  end

  test "default foreground run binds locally via --host 127.0.0.1" do
    ctx = test_context()

    assert {output, 0} = run_agents(ctx, ["run", "symphony"])
    assert output =~ "MISE:exec -- ./bin/symphony agents-pane --host 127.0.0.1"
  end

  test "--host opts out of the local-only injection" do
    ctx = test_context()

    assert {output, 0} = run_agents(ctx, ["--host", "run", "symphony"])
    refute output =~ "--host 127.0.0.1"
    assert output =~ "MISE:exec -- ./bin/symphony agents-pane --interactive"
  end

  test "auto-rebuilds bin/symphony when missing" do
    ctx = test_context()
    # The repo_root/elixir dir is empty by default — bin/symphony does not
    # exist, so ensure_built should call `mix escript.build` via fake mise.
    assert {output, 0} = run_agents(ctx, ["run", "symphony"], skip_build: false)

    assert output =~ "agents: rebuilding bin/symphony"
    assert output =~ "MISE:exec -- mix escript.build"
    # The real Symphony invocation still runs after the rebuild step.
    assert output =~ "MISE:exec -- ./bin/symphony"
  end

  describe "macOS (Darwin) background mode" do
    test "--bg writes a PID file and invokes nohup, not systemctl" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
      """)

      assert {output, 0} = run_agents(ctx, ["--bg", "actions"], os: "Darwin")

      pid_file = Path.join(ctx.bg_state_dir, "symphony-actions.pid")
      assert File.exists?(pid_file)
      assert {pid, ""} = Integer.parse(File.read!(pid_file) |> String.trim())
      assert is_integer(pid)
      assert output =~ "symphony-actions started in background"

      command_log = await_command_log(ctx, "NOHUP:")
      assert command_log =~ "NOHUP:#{ctx.fake_mise} exec -- ./bin/symphony"
      assert command_log =~ "--port 4101"
      assert command_log =~ "./WORKFLOW.actions.md"
      refute command_log =~ "SYSTEMCTL:"
    end

    test "--bg all starts each unique service once via nohup" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
      duplicate|#{ctx.actions_repo}|WORKFLOW.other.md|4102|#{ctx.logs_root}/other|symphony-actions
      """)

      assert {_output, 0} = run_agents(ctx, ["--bg", "all"], os: "Darwin")

      assert File.exists?(Path.join(ctx.bg_state_dir, "symphony.pid"))
      assert File.exists?(Path.join(ctx.bg_state_dir, "symphony-actions.pid"))

      # Both nohups run detached; poll until both lines have flushed.
      command_log =
        await_command_log_count(
          ctx,
          "NOHUP:#{ctx.fake_mise} exec -- ./bin/symphony",
          2
        )

      assert count_occurrences(command_log, "NOHUP:#{ctx.fake_mise} exec -- ./bin/symphony") == 2
      assert command_log =~ "local-workflows/WORKFLOW.symphony.local.md"
      assert command_log =~ "WORKFLOW.actions.md"
      refute command_log =~ "SYSTEMCTL:"
    end

    test "stop reads the PID file, sends SIGTERM, and removes the file" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
      """)

      File.mkdir_p!(ctx.bg_state_dir)
      pid_file = Path.join(ctx.bg_state_dir, "symphony-actions.pid")
      File.write!(pid_file, "424242\n")

      assert {_output, 0} = run_agents(ctx, ["stop", "actions"], os: "Darwin")
      command_log = command_log(ctx)

      assert command_log =~ "KILL:-TERM 424242\n"
      refute command_log =~ "SYSTEMCTL:"
      refute File.exists?(pid_file)
    end

    test "stop tolerates a missing PID file" do
      ctx = test_context()

      write_profiles!(ctx, """
      actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
      """)

      assert {_output, 0} = run_agents(ctx, ["stop", "actions"], os: "Darwin")
      command_log = command_log(ctx)

      refute command_log =~ "KILL:-TERM"
      refute command_log =~ "SYSTEMCTL:"
    end
  end

  defp test_context do
    root = Path.join(System.tmp_dir!(), "agents-script-test-#{System.unique_integer([:positive])}")
    repo_root = Path.join(root, "symphony")
    actions_repo = Path.join(root, "actions")
    bin_dir = Path.join(root, "bin")
    config_file = Path.join(root, "agents.profiles")
    logs_root = Path.join(root, "logs")
    command_log = Path.join(root, "commands.log")
    bg_state_dir = Path.join(root, "bg-state")

    # System.unique_integer resets per VM, so stale tmp dirs from prior
    # `mix test` runs can collide. Clear before setting up.
    File.rm_rf!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(repo_root, "elixir"))
    File.mkdir_p!(Path.join(actions_repo, "elixir"))
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(logs_root)

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
    } | tee -a "$AGENTS_TEST_COMMAND_LOG"
    """)

    write_executable!(fake_systemctl, """
    #!/usr/bin/env bash
    printf 'SYSTEMCTL:%s\\n' "$*" | tee -a "$AGENTS_TEST_COMMAND_LOG"
    """)

    write_executable!(fake_pkill, """
    #!/usr/bin/env bash
    printf 'PKILL:%s\\n' "$*" | tee -a "$AGENTS_TEST_COMMAND_LOG"
    """)

    write_executable!(fake_nohup, """
    #!/usr/bin/env bash
    printf 'NOHUP:%s\\n' "$*" >>"$AGENTS_TEST_COMMAND_LOG"
    sleep 0 &
    """)

    write_executable!(fake_kill, """
    #!/usr/bin/env bash
    printf 'KILL:%s\\n' "$*" | tee -a "$AGENTS_TEST_COMMAND_LOG"
    """)

    write_executable!(fake_tmux, """
    #!/usr/bin/env bash
    printf 'TMUX:%s\\n' "$*" >>"$AGENTS_TEST_COMMAND_LOG"

    case "$1" in
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

  defp run_agents(ctx, args, opts \\ []) do
    os_override = Keyword.get(opts, :os, "Linux")
    skip_build = if Keyword.get(opts, :skip_build, true), do: "1", else: "0"

    System.cmd("bash", [@script | args],
      env: [
        {"AGENTS_REPO_ROOT", ctx.repo_root},
        {"AGENTS_CONFIG_FILE", ctx.config_file},
        {"AGENTS_ENV_FILE", Path.join(ctx.repo_root, "missing.env")},
        {"AGENTS_MISE_BIN", ctx.fake_mise},
        {"AGENTS_SYSTEMCTL_BIN", ctx.fake_systemctl},
        {"AGENTS_PKILL_BIN", ctx.fake_pkill},
        {"AGENTS_NOHUP_BIN", ctx.fake_nohup},
        {"AGENTS_KILL_BIN", ctx.fake_kill},
        {"AGENTS_TMUX_BIN", ctx.fake_tmux},
        {"AGENTS_BG_STATE_DIR", ctx.bg_state_dir},
        {"AGENTS_OS_OVERRIDE", os_override},
        {"AGENTS_SKIP_BUILD", skip_build},
        {"AGENTS_TEST_COMMAND_LOG", ctx.command_log}
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
