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
    assert output =~ "MISE:exec -- ./bin/symphony --logs-root #{ctx.logs_root}/actions --port 4101"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.actions.md"
  end

  test "runs the built-in symphony profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_agents(ctx, ["symphony"])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"
    assert output =~ "MISE:exec -- ./bin/symphony"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.symphony.md"
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

  test "defaults to restarting other profiles and running default foreground" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
    """)

    assert {output, 0} = run_agents(ctx, [])
    assert output =~ "SYSTEMCTL:--user restart symphony-actions\n"
    refute output =~ "SYSTEMCTL:--user restart symphony\n"
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md"
  end

  test "all restarts other profiles and runs default foreground" do
    ctx = test_context()

    write_profiles!(ctx, """
    actions|#{ctx.actions_repo}|WORKFLOW.actions.md|4101|#{ctx.logs_root}/actions|symphony-actions
    """)

    assert {output, 0} = run_agents(ctx, ["all"])
    assert output =~ "SYSTEMCTL:--user restart symphony-actions\n"
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md"
  end

  test "run starts the default profile in the foreground" do
    ctx = test_context()

    assert {output, 0} = run_agents(ctx, ["run"])
    assert output =~ "PWD=#{Path.join(ctx.repo_root, "elixir")}"
    assert output =~ "MISE:exec -- ./bin/symphony"
    assert output =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md"
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
    assert output =~ "PKILL:-f #{Path.join(ctx.repo_root, "elixir")}/WORKFLOW.md"
    assert output =~ "PKILL:-f #{Path.join(ctx.repo_root, "elixir")}/WORKFLOW.symphony.md"
    assert output =~ "PKILL:-f #{Path.join(ctx.actions_repo, "elixir")}/WORKFLOW.actions.md"
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
    refute command_log =~ "SYSTEMCTL:--user stop symphony\n"
    refute output =~ "MISE:"
  end

  defp test_context do
    root = Path.join(System.tmp_dir!(), "agents-script-test-#{System.unique_integer([:positive])}")
    repo_root = Path.join(root, "symphony")
    actions_repo = Path.join(root, "actions")
    bin_dir = Path.join(root, "bin")
    config_file = Path.join(root, "agents.profiles")
    logs_root = Path.join(root, "logs")
    command_log = Path.join(root, "commands.log")

    File.mkdir_p!(Path.join(repo_root, "elixir"))
    File.mkdir_p!(Path.join(actions_repo, "elixir"))
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(logs_root)

    fake_mise = Path.join(bin_dir, "mise")
    fake_systemctl = Path.join(bin_dir, "systemctl")
    fake_pkill = Path.join(bin_dir, "pkill")

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

    %{
      repo_root: repo_root,
      actions_repo: actions_repo,
      config_file: config_file,
      logs_root: logs_root,
      command_log: command_log,
      fake_mise: fake_mise,
      fake_systemctl: fake_systemctl,
      fake_pkill: fake_pkill
    }
  end

  defp write_profiles!(ctx, body) do
    File.write!(ctx.config_file, body)
  end

  defp run_agents(ctx, args) do
    System.cmd("bash", [@script | args],
      env: [
        {"AGENTS_REPO_ROOT", ctx.repo_root},
        {"AGENTS_CONFIG_FILE", ctx.config_file},
        {"AGENTS_ENV_FILE", Path.join(ctx.repo_root, "missing.env")},
        {"AGENTS_MISE_BIN", ctx.fake_mise},
        {"AGENTS_SYSTEMCTL_BIN", ctx.fake_systemctl},
        {"AGENTS_PKILL_BIN", ctx.fake_pkill},
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
end
