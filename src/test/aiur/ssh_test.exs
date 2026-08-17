defmodule Aiur.SSHTest do
  use ExUnit.Case, async: false

  alias Aiur.SSH

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    test_root = Path.join(System.tmp_dir!(), "aiur-ssh-ipv6-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -o SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null -p 2200 root@[::1]"
    assert trace =~ "env -u BASH_ENV -u ENV ZDOTDIR=/dev/null HOME=\"$AIUR_REMOTE_HOME\" bash -c"
    assert trace =~ "printf ok"
  end

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    test_root = Path.join(System.tmp_dir!(), "aiur-ssh-ipv6-raw-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("::1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -o SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null ::1:2200"
    refute trace =~ "-p 2200"
  end

  test "run/3 passes host:port targets through ssh -p" do
    test_root = Path.join(System.tmp_dir!(), "aiur-ssh-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("AIUR_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("AIUR_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)
    System.put_env("AIUR_SSH_CONFIG", "/tmp/aiur-test-ssh-config")

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-F /tmp/aiur-test-ssh-config"
    assert trace =~ "-T -o SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null -p 2222 localhost"
    assert trace =~ "echo ready"
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    test_root = Path.join(System.tmp_dir!(), "aiur-ssh-user-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -o SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null -p 2200 root@127.0.0.1"
    assert trace =~ "printf ok"
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "aiur-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "run_script/3 streams scripts larger than the per-argument limit" do
    test_root = Path.join(System.tmp_dir!(), "aiur-ssh-script-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    input_file = Path.join(test_root, "ssh.input")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    cat > "#{input_file}"
    exit 0
    """)

    script = "printf streamed\\n" <> String.duplicate("# payload padding\\n", 10_000)
    assert byte_size(script) > 128 * 1_024

    assert {:ok, {"", 0}} =
             SSH.run_script("worker-01:2200", script, stderr_to_stdout: true)

    assert File.read!(input_file) == script
    trace = File.read!(trace_file)
    assert trace =~ "-T -o SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null -p 2200 worker-01"
    assert trace =~ "bash -s"
  end

  test "run_script/3 removes its staged input when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "aiur-ssh-script-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)
    staged_before = staged_scripts()

    assert {:error, :ssh_not_found} = SSH.run_script("worker-01", "printf unreachable\n")
    assert staged_scripts() == staged_before
  end

  test "start_port/3 supports binary output without line mode" do
    test_root = Path.join(System.tmp_dir!(), "aiur-ssh-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("AIUR_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("AIUR_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    System.delete_env("AIUR_SSH_CONFIG")

    assert {:ok, port} = SSH.start_port("localhost", "printf ok")
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T -o SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null localhost"
    refute trace =~ " -F "
  end

  test "start_port/3 supports line mode" do
    test_root = Path.join(System.tmp_dir!(), "aiur-ssh-line-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    assert {:ok, port} = SSH.start_port("localhost:2222", "printf ok", line: 256)
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T -o SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null -p 2222 localhost"
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    command = SSH.remote_shell_command("printf 'hello'")

    assert command =~ "test \"${HOME-}\" = /dev/null"
    assert command =~ "AIUR_REMOTE_HOME=$(getent passwd \"$(id -u)\" | cut -d: -f6)"
    assert command =~ "env -u BASH_ENV -u ENV ZDOTDIR=/dev/null HOME=\"$AIUR_REMOTE_HOME\" bash -c"
    assert String.ends_with?(command, Aiur.Shell.escape("printf 'hello'"))
  end

  defp install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      script ||
        """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        exit 0
        """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp wait_for_trace!(trace_file, attempts \\ 20)
  defp wait_for_trace!(trace_file, 0), do: flunk("timed out waiting for fake ssh trace at #{trace_file}")

  defp wait_for_trace!(trace_file, attempts) do
    if File.exists?(trace_file) and File.read!(trace_file) != "" do
      :ok
    else
      Process.sleep(25)
      wait_for_trace!(trace_file, attempts - 1)
    end
  end

  defp staged_scripts do
    System.tmp_dir!()
    |> Path.join("aiur-ssh-script-*.sh")
    |> Path.wildcard()
    |> MapSet.new()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
