defmodule Aiur.Workspace.RemoteTest do
  use ExUnit.Case, async: false

  alias Aiur.Workspace.Remote

  test "remote_shell_assign emits escaped assignment and tilde expansion cases" do
    script = Remote.remote_shell_assign("workspace", "~/can't")

    assert script =~ "workspace='~/can'\"'\"'t'"
    assert script =~ "  '~') workspace=\"$HOME\" ;;"
    assert script =~ "  '~/'*) workspace=\"$HOME/${workspace#\\~/}\" ;;"

    {path, 0} =
      System.cmd("sh", ["-lc", "#{script}; printf '%s' \"$workspace\""], env: [{"HOME", "/remote-home"}])

    assert path == "/remote-home/can't"
  end

  test "run_remote_script removes its staged input after a timeout" do
    test_root = Path.join(System.tmp_dir!(), "aiur-remote-timeout-test-#{System.unique_integer([:positive])}")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    File.write!(fake_ssh, "#!/bin/sh\n/bin/sleep 1\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", Enum.join(Enum.reject([test_root, previous_path], &is_nil/1), ":"))

    staged_before = staged_scripts()
    script = String.duplicate("# payload padding\n", 10_000)

    assert {:error, {:workspace_hook_timeout, "remote_command", 25}} =
             Remote.run_remote_script("worker-01", script, 25)

    assert staged_scripts() == staged_before
  end

  defp staged_scripts do
    System.tmp_dir!()
    |> Path.join("aiur-ssh-script-*.sh")
    |> Path.wildcard()
    |> MapSet.new()
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
