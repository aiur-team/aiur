defmodule Aiur.AgentCommandInstallerTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentBuildGuard, AgentGitHubGuard}

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-command-installer-#{System.pid()}-#{System.unique_integer([:positive])}")
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

  test "remote installation writes executable command guards idempotently", context do
    assert {"", 0} =
             System.cmd("sh", ["-lc", AgentGitHubGuard.remote_install_script(context.workspace)], stderr_to_stdout: true)

    bin_dir = AgentGitHubGuard.bin_dir(context.workspace)
    gh_wrapper = Path.join(bin_dir, "gh")
    git_wrapper = Path.join(bin_dir, "git")

    assert File.stat!(gh_wrapper).access == :read_write
    assert File.stat!(gh_wrapper).mode |> Bitwise.band(0o111) != 0
    assert File.stat!(git_wrapper).mode |> Bitwise.band(0o111) != 0
    assert File.read!(gh_wrapper) != ""
    assert File.read!(git_wrapper) != ""

    inodes = {File.stat!(gh_wrapper).inode, File.stat!(git_wrapper).inode}

    assert {"", 0} =
             System.cmd("sh", ["-lc", AgentGitHubGuard.remote_install_script(context.workspace)], stderr_to_stdout: true)

    assert {File.stat!(gh_wrapper).inode, File.stat!(git_wrapper).inode} == inodes
  end

  # The whole remote install travels as ONE argv string, and Linux caps a single
  # argument at 128 KiB (`MAX_ARG_STRLEN`) however large `ARG_MAX` is. The guards
  # grew past that ceiling once, and the failure mode is `Argument list too long`
  # before a single line runs — no agent, no useful error. Half the ceiling is the
  # bar so the next guard that grows is caught here rather than on a remote host.
  test "the remote install script fits in one argument", context do
    script = AgentGitHubGuard.remote_install_script(context.workspace)

    assert byte_size(script) < 65_536,
           "remote install script is #{byte_size(script)} bytes; the single-argument ceiling is 131072"
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
