defmodule Aiur.AgentCommandInstallerTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentBuildGuard, AgentGitHubGuard}

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-command-installer-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, workspace: workspace}
  end

  test "remote installation rejects a directory at a command target", context do
    target = Path.join(AgentGitHubGuard.bin_dir(context.workspace), "gh")
    File.mkdir_p!(target)

    assert {output, 73} =
             System.cmd("sh", ["-lc", AgentGitHubGuard.remote_install_script(context.workspace)], stderr_to_stdout: true)

    assert output =~ "unsafe agent command target"
    assert File.dir?(target)
    assert File.ls!(target) == []
  end

  test "local installation replaces a command-target symlink", context do
    assert :ok = AgentBuildGuard.install(context.workspace)
    target = Path.join(AgentBuildGuard.bin_dir(context.workspace), "mix")
    external = Path.join(context.root, "external-mix")
    File.cp!(target, external)
    File.rm!(target)
    File.ln_s!(external, target)

    assert :ok = AgentBuildGuard.install(context.workspace)
    assert File.lstat!(target).type == :regular
    assert File.read!(target) == File.read!(external)
  end
end
