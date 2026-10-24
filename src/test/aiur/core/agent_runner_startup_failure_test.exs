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

  test "agent runner retries before_run timeout with backoff without pausing" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-before-run-timeout-retry")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      before_run_trace = Path.join(test_root, "before-run.trace")
      codex_trace = Path.join(test_root, "codex.trace")
      identifier = "MT-BEFORE-RUN-RETRY-#{System.unique_integer([:positive])}"

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
        run_number=$(wc -l < #{before_run_trace})
        if [ "$run_number" -eq 1 ]; then
          sleep 2
        fi
        """,
        hook_timeout_ms: 500,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, test_workspace} =
        Layout.workspace_path_for_issue(Layout.safe_identifier(identifier), nil)

      issue = %Issue{
        id: "issue-before-run-retry",
        identifier: identifier,
        title: "Retry a timed out hook",
        description: "before_run timeout should retry without consuming agent attempts",
        state: "In Progress",
        url: "https://example.org/issues/MT-BEFORE-RUN-RETRY",
        labels: []
      }

      test_pid = self()
      started_at_ms = System.monotonic_time(:millisecond)

      task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            test_pid,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end)

      receive do
        {:codex_worker_update, "issue-before-run-retry", %{event: :session_started}} -> :ok
      after
        10_000 ->
          codex_output = if File.exists?(codex_trace), do: File.read!(codex_trace), else: "(codex was never started)"
          flunk("session did not start after automatic retry; codex trace:\n#{codex_output}")
      end

      assert System.monotonic_time(:millisecond) - started_at_ms >= 1_400,
             "the timeout retry should wait for its initial backoff after the 500 ms hook timeout"

      refute_receive {:worker_control_state, "issue-before-run-retry", :paused, %{kind: :before_run_failure}}, 100
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
             "expected one timed-out before_run and one automatic retry; got #{inspect(trace_lines)}"

      timeout_identifier = "MT-BEFORE-RUN-CAP-#{System.unique_integer([:positive])}"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        hook_before_run: "printf '%s\\n' \"$AIUR_HOOK_TICKET_IDENTIFIER\" >> #{before_run_trace}; sleep 2",
        hook_timeout_ms: 500,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      timeout_issue = %Issue{
        id: "issue-before-run-timeout-cap",
        identifier: timeout_identifier,
        title: "Stop retrying persistent hook timeouts",
        description: "persistent before_run timeouts should leave the retry loop with their cause",
        state: "In Progress",
        url: "https://example.org/issues/MT-BEFORE-RUN-TIMEOUT-CAP",
        labels: []
      }

      assert catch_exit(AgentRunner.run(timeout_issue)) == {:workspace_hook_timeout, "before_run", 500}

      timeout_runs =
        before_run_trace
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.count(&(&1 == timeout_identifier))

      assert timeout_runs == 4,
             "expected the first attempt plus three automatic retries, got #{timeout_runs} hook invocations"
    after
      File.rm_rf(test_root)
    end
  end
end
