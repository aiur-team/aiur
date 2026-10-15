defmodule Aiur.Core.AgentRunnerPauseTest do
  use Aiur.TestSupport

  test "agent runner interrupts an active turn and waits for the next operator message before resuming" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-pause")

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
      first_turn_started=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-pause"}}}'
            ;;
          *'"method":"turn/start"'*)
            if [ "$first_turn_started" -eq 0 ]; then
              first_turn_started=1
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-main"}}}'
            else
              request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
              printf '{"id":%s,"result":{"turn":{"id":"turn-resume"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
              exit 0
            fi
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
        max_turns: 2
      )

      orchestrator_name = Module.concat(__MODULE__, :PauseResumeOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      issue = %Issue{
        id: "issue-pause-resume",
        identifier: "MT-251",
        title: "Pause and resume",
        description: "interrupt active work and wait for operator input",
        state: "In Progress",
        url: "https://example.org/issues/MT-251",
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

      assert_receive {:codex_worker_update, "issue-pause-resume", %{event: :session_started}}, 5_000

      send(task.pid, {:pause_agent, 91})

      assert_receive {:worker_control_state, "issue-pause-resume", :paused, %{request_id: 91, turn_id: "turn-main"}},
                     5_000

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, item} =
          Aiur.AgentQueue.operator_message("MT-251", "resume with the auth fix")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        send(test_pid, {:queued_request_id, item.id})
        %{state | queue_store: queue_store}
      end)

      assert_receive {:queued_request_id, request_id}, 1000

      send(task.pid, {:agent_queue_updated, "MT-251", request_id})

      assert {:ok, :ok} = Task.yield(task, 15_000)

      trace =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)

      assert Enum.any?(trace, &String.contains?(&1, ~s("method":"turn/interrupt")))

      turn_texts =
        trace
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "resume with the auth fix"

      workspace_log =
        Path.join([workspace_root, "project", "MT-251", "logs", "agent.md"])
        |> File.read!()

      assert workspace_log =~ "worker_paused"
      assert workspace_log =~ "Agent paused by Executor."
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner remains paused when idle precedes a no-active-turn interrupt response" do
    assert_agent_runner_pause_no_active_turn(:idle_first)
  end

  test "agent runner remains paused when a no-active-turn interrupt response precedes idle" do
    assert_agent_runner_pause_no_active_turn(:response_first)
  end

  test "agent runner remains paused when no idle follows a no-active-turn interrupt response" do
    assert_agent_runner_pause_no_active_turn(:response_only)
  end

  defp assert_agent_runner_pause_no_active_turn(event_order) do
    order_name = Atom.to_string(event_order)

    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-pause-no-active-turn-#{order_name}")

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

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-pause-no-active"}}}'
            ;;
          *'"method":"turn/start"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '{"id":%s,"result":{"turn":{"id":"turn-main"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/started","params":{"turn":{"id":"turn-main","status":"inProgress"}}}'
            ;;
          *'"method":"turn/interrupt"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      #{no_active_turn_interrupt_frames(event_order)}
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
        max_turns: 2
      )

      orchestrator_name =
        Module.concat(
          __MODULE__,
          "PauseNoActiveTurn#{Macro.camelize(order_name)}Orchestrator"
        )

      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      issue_id = "issue-pause-no-active-turn-#{order_name}"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-PAUSE-NO-ACTIVE-#{String.upcase(order_name)}",
        title: "Preserve pause at a completed turn boundary",
        description: "do not continue after Codex reports no active turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-PAUSE-NO-ACTIVE",
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

      assert_receive {:codex_worker_update, ^issue_id,
                      %{
                        event: :notification,
                        payload: %{"method" => "turn/started"}
                      }},
                     15_000

      send(task.pid, {:pause_agent, 93})

      assert_receive {:worker_control_state, ^issue_id, :paused, %{request_id: 93, turn_id: "turn-main"}},
                     5_000

      refute Task.yield(task, 100)

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1

      send(task.pid, {:resume_agent, 94})
      assert {:ok, :ok} = Task.yield(task, 5_000)

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  defp no_active_turn_interrupt_frames(:idle_first) do
    """
            printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
            printf '{"id":%s,"error":{"code":-32600,"message":"no active turn"}}\\n' "$request_id"
    """
  end

  defp no_active_turn_interrupt_frames(:response_first) do
    """
            printf '{"id":%s,"error":{"code":-32600,"message":"no active turn"}}\\n' "$request_id"
            printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
    """
  end

  defp no_active_turn_interrupt_frames(:response_only) do
    """
            printf '{"id":%s,"error":{"code":-32600,"message":"no active turn"}}\\n' "$request_id"
    """
  end
end
