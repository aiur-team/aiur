defmodule Aiur.AppServer.RemoteTest do
  use Aiur.TestSupport

  test "app server launches over ssh for remote workers" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-app-server-remote-ssh")

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/aiur-fake-ssh.trace}"
      count=0
      printf '%s\\0' "$@" > "${trace_file}.argv"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      ssh_argv =
        (trace_file <> ".argv")
        |> File.read!()
        |> :binary.split(<<0>>, [:global, :trim_all])

      assert [
               "-T",
               "-o",
               "SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null",
               "-p",
               "2200",
               "worker-01",
               remote_command
             ] = ssh_argv

      assert remote_command =~ "test \"${HOME-}\" = /dev/null"
      assert remote_command =~ "env -u BASH_ENV -u ENV ZDOTDIR=/dev/null HOME=\"$AIUR_REMOTE_HOME\" bash -c "
      refute remote_command =~ "bash -lc "
      assert remote_command =~ "cd "
      assert remote_command =~ remote_workspace
      assert remote_command =~ "exec "
      assert remote_command =~ "fake-remote-codex app-server"
      assert remote_command =~ "HEX_HOME="
      assert remote_command =~ "${HEX_HOME#\\~/}"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace, Path.join(remote_workspace, ".git"), Path.join(remote_workspace, ".agents"), Path.join(remote_workspace, ".codex")],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => true,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => true
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
