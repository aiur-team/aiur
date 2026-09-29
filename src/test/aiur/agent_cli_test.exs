defmodule Aiur.AgentCLITest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentCLI, AgentEnvironment}
  alias Aiur.Workspace.Provisioner

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-agent-cli")
    workspace = Path.join(root, "workspace")
    global_bin = Path.join(root, "global-bin")
    File.mkdir_p!(workspace)
    File.mkdir_p!(global_bin)
    File.write!(Path.join(global_bin, "aiur"), "#!/bin/sh\necho 'unknown command: guard-pr-deletions' >&2\nexit 64\n")
    File.chmod!(Path.join(global_bin, "aiur"), 0o755)
    File.write!(Path.join(global_bin, "unrelated-tool"), "#!/bin/sh\necho unrelated-ok\n")
    File.chmod!(Path.join(global_bin, "unrelated-tool"), 0o755)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, workspace: workspace, global_bin: global_bin}
  end

  test "worker guard comes from the daemon build despite an older global aiur first on PATH", context do
    assert :ok = Provisioner.maybe_install_agent_support(context.workspace, nil)
    assert [] = AgentCLI.missing_workspace_support(context.workspace)

    command = AgentEnvironment.scrub_shell_command("aiur guard-pr-deletions")
    {output, status} = worker_command(context, command)

    assert status == 2
    assert output =~ "guard-pr-deletions: base branch is required"
    refute output =~ "unknown command"

    assert {"unrelated-ok\n", 0} = worker_command(context, AgentEnvironment.scrub_shell_command("unrelated-tool"))

    assert {"unknown command: guard-pr-deletions\n", 64} =
             worker_command(context, AgentEnvironment.scrub_shell_command("aiur --version"))
  end

  test "remote worker installation receives the same daemon-build guard", context do
    runner = fn _host, script, _timeout ->
      script_path = Path.join(context.root, "install.sh")
      File.write!(script_path, script)
      {:ok, System.cmd("sh", [script_path], stderr_to_stdout: true, env: [{"HOME", context.root}])}
    end

    assert :ok = Provisioner.maybe_install_agent_support(context.workspace, "remote-worker", runner)

    {output, status} = worker_command(context, AgentEnvironment.scrub_shell_command("aiur guard-pr-deletions"))
    assert status == 2
    assert output =~ "guard-pr-deletions: base branch is required"
  end

  test "a removed guard is repaired before local dispatch", context do
    assert :ok = Provisioner.maybe_install_agent_support(context.workspace, nil)
    guard = Path.join(context.workspace, ".aiur-runtime/bin/aiur-guard-pr-deletions")
    File.rm!(guard)

    assert [".aiur-runtime/bin/aiur-guard-pr-deletions"] = AgentCLI.missing_workspace_support(context.workspace)
    assert :ok = Provisioner.ensure_local_agent_support(context.workspace)
    assert [] = AgentCLI.missing_workspace_support(context.workspace)
  end

  defp worker_command(context, command) do
    System.cmd("bash", ["-c", command],
      stderr_to_stdout: true,
      env: [
        {"AIUR_AGENT_BIN", Path.join(context.workspace, ".aiur-runtime/bin")},
        {"AIUR_RELEASE_DIR", Path.join(context.root, "daemon-release")},
        {"PATH", context.global_bin <> ":" <> System.fetch_env!("PATH")}
      ]
    )
  end
end
