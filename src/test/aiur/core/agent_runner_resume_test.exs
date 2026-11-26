defmodule Aiur.Core.AgentRunnerResumeTest do
  use Aiur.TestSupport

  import Aiur.CoreTestSupport

  test "agent runner processes restored and newly-queued operator input on explicit resume after pause" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-requeue")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      turn_start_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-requeue"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')

            case "$turn_start_count" in
              1)
                printf '{"id":%s,"result":{"turn":{"id":"turn-main"}}}\\n' "$request_id"
                printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"checkpoint"}]}}'
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-main","status":"completed"}}}'
                ;;
              2)
                printf '{"id":%s,"result":{"turn":{"id":"turn-checkpoint-abc"}}}\\n' "$request_id"
                ;;
              3)
                printf '{"id":%s,"result":{"turn":{"id":"turn-resume-abc"}}}\\n' "$request_id"
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
                ;;
              4)
                printf '{"id":%s,"result":{"turn":{"id":"turn-def"}}}\\n' "$request_id"
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-def","status":"completed"}}}'
                exit 0
                ;;
            esac
            ;;
          *'"method":"turn/interrupt"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '{"id":%s,"result":{}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"interrupted"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      orchestrator_name = Module.concat(__MODULE__, :CheckpointRequeueOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, _item} =
          Aiur.AgentQueue.operator_message("MT-252", "abc")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        %{state | queue_store: queue_store}
      end)

      issue = %Issue{
        id: "issue-checkpoint-requeue",
        identifier: "MT-252",
        title: "Preserve queued input across pause",
        description: "requeue checkpoint-delivered input when pause interrupts the active turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-252",
        labels: []
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            test_pid,
            orchestrator: orchestrator_name,
            issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end)

      assert_receive {:codex_worker_update, "issue-checkpoint-requeue", %{event: :session_started}}, 5_000

      # Single-writer boundary delivery: "abc" is no longer delivered on
      # turn-main's mid-turn checkpoint; it lands as a follow-up turn after
      # turn-main completes. Wait for that deferred turn/start before pausing so
      # the pause interrupts it (and restore_delivered_queue_items requeues it).
      Enum.reduce_while(1..500, nil, fn _, _ ->
        starts =
          case File.read(trace_file) do
            {:ok, c} ->
              c |> String.split("\n") |> Enum.count(&String.contains?(&1, ~s("method":"turn/start")))

            _ ->
              0
          end

        if starts >= 2, do: {:halt, :ok}, else: Process.sleep(10) && {:cont, nil}
      end)

      send(task.pid, {:pause_agent, 92})

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, item} =
          Aiur.AgentQueue.operator_message("MT-252", "def")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        send(test_pid, {:queued_request_id, item.id})
        %{state | queue_store: queue_store}
      end)

      assert_receive {:queued_request_id, _request_id}, 1000
      # The paused worker no longer eagerly claims restored items on its
      # own — that was the bug behind the pause→auto-unpause loop reported
      # in issue #15. Explicit resume drains the operator queue so both
      # the restored "abc" and the newly-enqueued "def" land as turns.
      send(task.pid, {:resume_agent, 99})

      assert {:ok, :ok} = Task.yield(task, 15_000)

      turn_texts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 4
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "abc"
      assert Enum.at(turn_texts, 2) == "abc"
      assert Enum.at(turn_texts, 3) == "def"
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-max-turns")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      after_run_started = Path.join(test_root, "after-run.started")
      after_run_release = Path.join(test_root, "after-run.release")
      after_run_done = Path.join(test_root, "after-run.done")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN %s\\n' "$PWD" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-max-2","status":"completed"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        hook_after_run: "touch #{after_run_started}; while [ ! -f #{after_run_release} ]; do sleep 0.01; done; touch #{after_run_done}",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      test_pid = self()

      task =
        Task.async(fn ->
          AgentRunner.run(issue, test_pid, issue_state_fetcher: state_fetcher)
        end)

      assert wait_for_path(after_run_started, 15_000)
      refute_receive {:worker_control_state, "issue-max-turns", :completed}, 100

      File.touch!(after_run_release)

      assert_receive {:worker_control_state, "issue-max-turns", :completed}, 2_000
      assert File.exists?(after_run_done)
      assert :ok = Task.await(task, 2_000)

      trace = File.read!(trace_file)

      run_workspaces =
        trace
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "RUN "))
        |> Enum.map(&String.replace_prefix(&1, "RUN ", ""))

      agent_workspace = Path.join([workspace_root, "project", "MT-248"])
      assert Enum.count(run_workspaces, &(&1 == agent_workspace)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end
end
