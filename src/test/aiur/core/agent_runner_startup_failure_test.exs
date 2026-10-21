defmodule Aiur.Core.AgentRunnerStartupFailureTest do
  use Aiur.TestSupport

  alias Aiur.Workspace.Layout

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-single-host")

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/aiur-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__AIUR_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__AIUR_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__AIUR_WORKSPACE__' '1' '/remote/home/.aiur-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.aiur-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a"
      refute trace =~ "worker-b"
      assert trace =~ ~S(env -u BASH_ENV -u ENV ZDOTDIR=/dev/null HOME="$AIUR_REMOTE_HOME" bash -c)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner pauses on before_run failure and resumes after operator intervention" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-before-run-pause")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      before_run_trace = Path.join(test_root, "before-run.trace")
      codex_trace = Path.join(test_root, "codex.trace")
      resume_marker = Path.join(test_root, "allow-before-run")
      identifier = "MT-BEFORE-RUN-PAUSE-#{System.unique_integer([:positive])}"

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file=#{inspect(codex_trace)}
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        request_id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
          *'"method":"initialize"'*)
            printf '{"id":%s,"result":{}}\\n' "$request_id"
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '{"id":%s,"result":{"thread":{"id":"thread-before-run-resume"}}}\\n' "$request_id"
            ;;
          *'"method":"turn/start"'*)
            printf '{"id":%s,"result":{"turn":{"id":"turn-before-run-resume"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        hook_before_run: """
        printf '%s\\t%s\\t%s\\t%s\\n' "$AIUR_HOOK_TICKET_ID" "$AIUR_HOOK_TICKET_IDENTIFIER" "$AIUR_HOOK_RUNNER_PID" "$PWD" >> #{before_run_trace}
        if [ ! -f #{resume_marker} ]; then
          printf '%s\\n' 'dependency fetch failed' >&2
          exit 74
        fi
        """,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, test_workspace} =
        Layout.workspace_path_for_issue(Layout.safe_identifier(identifier), nil)

      issue = %Issue{
        id: "issue-before-run-pause",
        identifier: identifier,
        title: "Pause on hook failure",
        description: "before_run should pause instead of exhausting retries",
        state: "In Progress",
        url: "https://example.org/issues/MT-BEFORE-RUN-PAUSE",
        labels: []
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            test_pid,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end)

      assert_receive {:worker_control_state, "issue-before-run-pause", :paused, %{kind: :before_run_failure}},
                     5_000

      refute_receive {:codex_worker_update, "issue-before-run-pause", %{event: :session_started}}, 200
      assert Task.yield(task, 50) == nil

      File.write!(resume_marker, "ok\n")
      send(task.pid, {:resume_agent, 101})

      assert_receive {:worker_control_state, "issue-before-run-pause", :working}, 5_000

      receive do
        {:codex_worker_update, "issue-before-run-pause", %{event: :session_started}} -> :ok
      after
        5_000 ->
          flunk("session did not start after resume; codex trace:\n#{File.read!(codex_trace)}")
      end

      assert {:ok, :ok} = Task.yield(task, 15_000)

      trace_lines = before_run_trace |> File.read!() |> String.split("\n", trim: true)

      all_owned_by_test? =
        Enum.all?(trace_lines, fn line ->
          case String.split(line, "\t", parts: 4) do
            [ticket_id, ticket_identifier, runner_pid, workspace] ->
              ticket_id == issue.id and ticket_identifier == issue.identifier and
                runner_pid == inspect(task.pid) and workspace == test_workspace

            _ ->
              false
          end
        end)

      assert length(trace_lines) == 2 and all_owned_by_test?,
             "expected exactly two before_run entries from this test runner; got #{inspect(trace_lines)}"
    after
      File.rm_rf(test_root)
    end
  end
end
