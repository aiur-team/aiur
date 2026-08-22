defmodule Aiur.GitTest do
  use ExUnit.Case, async: true

  alias Aiur.Git

  @pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()

  describe "ls_remote/3" do
    test "parses ls-remote output into a ref => sha map" do
      stub_output =
        "abc123\trefs/heads/main\n" <>
          "def456\trefs/heads/feature\n"

      cmd_fun = fn {_git, _args} -> {stub_output, 0} end

      {:ok, refs} =
        Git.ls_remote("origin", ["refs/heads/main", "refs/heads/feature"], cmd_fun: cmd_fun)

      assert refs == %{
               "refs/heads/main" => "abc123",
               "refs/heads/feature" => "def456"
             }
    end

    test "returns empty map when refs argument is empty" do
      assert {:ok, %{}} = Git.ls_remote("origin", [])
    end

    test "returns empty map when remote has no matching refs" do
      cmd_fun = fn {_git, _args} -> {"", 0} end
      assert {:ok, %{}} = Git.ls_remote("origin", ["refs/heads/nope"], cmd_fun: cmd_fun)
    end

    test "returns error when git exits non-zero" do
      cmd_fun = fn {_git, _args} -> {"fatal: remote 'bogus' not found\n", 128} end

      assert {:error, {:git_ls_remote_failed, 128, "fatal: remote 'bogus' not found"}} =
               Git.ls_remote("bogus", ["refs/heads/main"], cmd_fun: cmd_fun)
    end

    test "tolerates tabs and multiple spaces as separator" do
      stub_output = "abc\t\trefs/heads/main\n"
      cmd_fun = fn {_git, _args} -> {stub_output, 0} end

      assert {:ok, %{"refs/heads/main" => "abc"}} =
               Git.ls_remote("origin", ["refs/heads/main"], cmd_fun: cmd_fun)
    end

    test "skips malformed lines without erroring" do
      stub_output = "abc123\trefs/heads/ok\nmalformed_line_no_separator\n"
      cmd_fun = fn {_git, _args} -> {stub_output, 0} end

      assert {:ok, refs} =
               Git.ls_remote("origin", ["refs/heads/ok"], cmd_fun: cmd_fun)

      assert refs == %{"refs/heads/ok" => "abc123"}
    end

    test "timeout is wall-clock bounded even when git emits output" do
      tmp =
        Path.join(System.tmp_dir!(), "aiur-git-heartbeat-#{System.pid()}-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      fake_git = Path.join(tmp, "git")

      File.write!(fake_git, """
      #!/bin/sh
      while true
      do
        echo heartbeat
        sleep 0.1
      done
      """)

      File.chmod!(fake_git, 0o755)

      on_exit(fn ->
        if pkill = System.find_executable("pkill") do
          System.cmd(pkill, ["-f", fake_git], stderr_to_stdout: true)
        end

        File.rm_rf!(tmp)
      end)

      task =
        Task.async(fn ->
          Git.ls_remote("origin", ["refs/heads/main"], git_path: fake_git, timeout_ms: 1_000)
        end)

      result = Task.yield(task, 2_500) || Task.shutdown(task, :brutal_kill)

      assert {:ok, {:error, {:git_ls_remote_timeout, 1_000, output}}} = result
      assert output =~ "heartbeat"
    end

    @tag skip: @pgrep_skip_reason
    test "times out and kills the git process tree" do
      tmp =
        Path.join(System.tmp_dir!(), "aiur-git-timeout-#{System.pid()}-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      fake_git = Path.join(tmp, "git")
      child_pid_file = Path.join(tmp, "child.pid")

      File.write!(fake_git, """
      #!/bin/sh
      sleep 60 &
      echo "$!" > "$2"
      wait
      """)

      File.chmod!(fake_git, 0o755)

      on_exit(fn ->
        case File.read(child_pid_file) do
          {:ok, pid} -> System.cmd("kill", ["-KILL", String.trim(pid)], stderr_to_stdout: true)
          _ -> :ok
        end

        File.rm_rf!(tmp)
      end)

      assert {:error, {:git_ls_remote_timeout, 1_000, ""}} =
               Git.ls_remote(child_pid_file, ["refs/heads/main"],
                 git_path: fake_git,
                 timeout_ms: 1_000
               )

      child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()
      assert wait_dead(child_pid, 50)
    end
  end

  describe "parse_origin_url/1 (repo auto-detect)" do
    test "extracts owner/name from common remote URL shapes" do
      assert Git.parse_origin_url("https://github.com/octo/repo.git") == "octo/repo"
      assert Git.parse_origin_url("https://github.com/octo/repo") == "octo/repo"
      assert Git.parse_origin_url("git@github.com:octo/repo.git") == "octo/repo"
      assert Git.parse_origin_url("ssh://git@github.com/octo/repo.git") == "octo/repo"
    end

    test "returns nil for an unparseable url" do
      assert Git.parse_origin_url("not-a-remote") == nil
      assert Git.parse_origin_url("") == nil
    end
  end

  defp wait_dead(_pid, 0), do: false

  defp wait_dead(pid, attempts) do
    if os_pid_alive?(pid) do
      Process.sleep(25)
      wait_dead(pid, attempts - 1)
    else
      true
    end
  end

  defp os_pid_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
  end
end
