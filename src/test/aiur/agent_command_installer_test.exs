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

  # The whole remote install can travel as ONE argv string — the worst case is a
  # `bash -c <script>` / `sh -lc <script>` invocation — and Linux caps a single
  # argument at 128 KiB (`MAX_ARG_STRLEN`, 32 pages) however large `ARG_MAX` is.
  # The guards grew past the bar once, and the failure mode is `Argument list too
  # long` before a single line runs — no agent, no useful error.
  #
  # The bar was originally half the ceiling (65,536): a deliberate safety margin,
  # not a platform limit — no platform caps a single argument at 64 KiB. The real
  # limit is `MAX_ARG_STRLEN` = 32 * PAGE_SIZE = 131,072 bytes per argument,
  # documented in Linux `execve(2)` and verified empirically (a 131,072-byte
  # argument fails with `Argument list too long` / E2BIG; 131,071 succeeds). The
  # gh guard then legitimately grew — resource bucketing, the lease pools, the
  # classification arms — and the compressed install script crossed 64 KiB.
  #
  # The bar is re-based to 96 KiB (98,304 = 75% of the verified ceiling, a 25%
  # margin) so a loud CI failure is never converted into a silent runtime failure,
  # while a PR that grows the script past the bar still fails loudly here, well
  # before a remote host would. The headroom covers the guard growth queued in
  # #2353 and #2366.
  test "the remote install script fits in one argument", context do
    script = AgentGitHubGuard.remote_install_script(context.workspace)

    assert byte_size(script) < 98_304,
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
