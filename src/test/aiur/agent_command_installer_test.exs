defmodule Aiur.AgentCommandInstallerTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentBuildGuard, AgentGitHubGuard}

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-command-installer")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, workspace: workspace}
  end

  test "remote installation rejects a directory at a command target", context do
    target = Path.join(AgentGitHubGuard.bin_dir(context.workspace), "gh")
    File.mkdir_p!(target)

    assert {output, 73} = run_install_script(context, AgentGitHubGuard.remote_install_script(context.workspace))

    assert output =~ "unsafe agent command target"
    assert File.dir?(target)
    assert File.ls!(target) == []
  end

  test "remote installation writes executable command guards idempotently", context do
    assert {"", 0} = run_install_script(context, AgentGitHubGuard.remote_install_script(context.workspace))

    bin_dir = AgentGitHubGuard.bin_dir(context.workspace)
    gh_wrapper = Path.join(bin_dir, "gh")
    git_wrapper = Path.join(bin_dir, "git")

    assert File.stat!(gh_wrapper).access == :read_write
    assert File.stat!(gh_wrapper).mode |> Bitwise.band(0o111) != 0
    assert File.stat!(git_wrapper).mode |> Bitwise.band(0o111) != 0
    assert File.read!(gh_wrapper) != ""
    assert File.read!(git_wrapper) != ""

    inodes = {File.stat!(gh_wrapper).inode, File.stat!(git_wrapper).inode}

    assert {"", 0} = run_install_script(context, AgentGitHubGuard.remote_install_script(context.workspace))

    assert {File.stat!(gh_wrapper).inode, File.stat!(git_wrapper).inode} == inodes
  end

  # A growth budget, not a platform limit. Nothing breaks the moment the script
  # passes it — the remote install is staged to a file and fed to `bash -s` on
  # stdin by `Aiur.SSH.with_script/4`, so Linux's 128 KiB per-argument cap
  # (`MAX_ARG_STRLEN`) never bound it; the composed agent-support payload is
  # already megabytes and installs fine. What the budget protects is cost: the
  # `gh` guard is compiled into the daemon, held in memory, and re-sent on every
  # remote dispatch, so growth deserves a deliberate decision rather than a
  # discovery. Raise it only with a reason stated in the commit.
  test "the remote install script stays inside its growth budget", context do
    script = AgentGitHubGuard.remote_install_script(context.workspace)

    assert byte_size(script) < 98_304,
           "remote install script is #{byte_size(script)} bytes; the growth budget is 98304"
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

  # Mirrors production transport: the script is staged to a file and read by the
  # shell, never handed over as a command-line argument. Running these through
  # `sh -lc` instead would reimpose `MAX_ARG_STRLEN` on the test suite alone, so
  # a growing guard could redden tests that production does not care about.
  defp run_install_script(context, script) do
    path = Path.join(context.root, "install-#{System.unique_integer([:positive])}.sh")
    File.write!(path, script)
    System.cmd("sh", [path], stderr_to_stdout: true)
  end
end

defmodule Aiur.AgentCommandInstallerTransportTest do
  # Mutates PATH to install a fake `ssh`, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias Aiur.{AgentGitHubGuard, SSH}

  # Pins the transport property where it actually lives. The remote install does
  # not cross `execve` as an argument: `Aiur.SSH.with_script/4` stages it to a
  # file and feeds it to `bash -s` on stdin. If `ssh.ex` ever reverts to argv
  # transport, this fails here — with the real install script — rather than on a
  # remote host with `Argument list too long` and no useful error.
  test "the remote install script reaches the host on stdin, not as an argument" do
    root = Aiur.TestSupport.tmp_root!("aiur-command-installer-transport")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    trace_file = Path.join(root, "ssh.trace")
    input_file = Path.join(root, "ssh.input")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
      File.rm_rf!(root)
    end)

    install_fake_ssh!(root, trace_file, input_file)

    script = AgentGitHubGuard.remote_install_script(workspace)

    assert {:ok, {"", 0}} = SSH.run_script("worker-01", script, stderr_to_stdout: true)

    # The payload arrived whole on stdin.
    assert File.read!(input_file) == script

    # And nothing resembling the payload crossed argv — only `bash -s` did.
    trace = File.read!(trace_file)
    assert trace =~ "bash -s"
    refute trace =~ "base64 -d"
    assert byte_size(trace) < 131_072
  end

  defp install_fake_ssh!(root, trace_file, input_file) do
    fake_bin_dir = Path.join(root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")
    File.mkdir_p!(fake_bin_dir)

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    # Only a redirect from the staged file makes stdin a regular file. Argv
    # transport would leave stdin an open pipe, so read nothing and let the
    # assertion below report an empty payload instead of blocking forever.
    if [ -f /dev/stdin ]; then cat > "#{input_file}"; else : > "#{input_file}"; fi
    exit 0
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end
end
