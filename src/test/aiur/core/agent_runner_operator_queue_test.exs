defmodule Aiur.Core.AgentRunnerOperatorQueueTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.OperatorMessages

  import Aiur.CoreTestSupport

  test "agent runner drains queued operator messages at the turn boundary" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-queued-operator")

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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-queue"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-queue-1"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-queue-1","status":"completed"}}}'
            ;;
          *)
            if printf '%s' "$line" | grep -q '"method":"turn/start"'; then
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-queue-2"}}}'
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-queue-2","status":"completed"}}}'
            fi
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

      orchestrator_name = Module.concat(__MODULE__, :QueuedOperatorOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      end)

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, _item} =
          Aiur.AgentQueue.operator_message("MT-249", "focus on auth first")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        %{state | queue_store: queue_store}
      end)

      issue = %Issue{
        id: "issue-queue",
        identifier: "MT-249",
        title: "Drain queued operator message",
        description: "Deliver follow-up after the first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-249",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 orchestrator: orchestrator_name,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

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

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "focus on auth first"
      assert :empty == OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-249")
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "closed Codex port after completion replays queued rework once on replacement" do
    # The memory tracker fixture is process-global. Suspend the supervised
    # orchestrator from independently dispatching it beside this named one.
    default_orchestrator = Process.whereis(Orchestrator)

    if is_pid(default_orchestrator) do
      :ok = :sys.suspend(default_orchestrator, 30_000)

      on_exit(fn ->
        if Process.alive?(default_orchestrator), do: :ok = :sys.resume(default_orchestrator)
      end)
    end

    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-completed-codex-replacement")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      port_closed_once = Path.join(test_root, "port-closed.once")
      port_closed_after_completion = Path.join(test_root, "port-closed.after-completion")
      rework_replayed = Path.join(test_root, "rework.replayed")
      rework_release = Path.join(test_root, "rework.release")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_CODEX_TRACE"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-replacement"}}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-replacement"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')

            if printf '%s' "$line" | grep -q 'repair from replacement'; then
              printf '{"id":%s,"result":{"turn":{"id":"turn-replacement-rework","status":"inProgress"}}}\\n' "$request_id"
              touch "#{rework_replayed}"
              while [ ! -f "#{rework_release}" ]; do sleep 0.01; done
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-replacement-rework","status":"completed"}}}'
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-replacement-main","status":"inProgress"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-replacement-main","status":"completed"}}}'

              if [ ! -f "#{port_closed_once}" ]; then
                touch "#{port_closed_once}"
                touch "#{port_closed_after_completion}"
                exec 0<&-; sleep 1; exit 0 # stdin closes first, so the queued write hits EPIPE (#4017)
              fi
            fi
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      issue = %Issue{
        id: "issue-completed-codex-replacement",
        identifier: "MT-CODEX-REPLACEMENT",
        title: "Drain rework on replacement",
        description: "The completed Codex worker must be replaceable",
        state: "rework",
        url: "https://example.org/issues/MT-CODEX-REPLACEMENT",
        labels: [],
        selected_backend: "codex"
      }

      Application.put_env(:aiur, :memory_tracker_issues, [issue])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["in-progress", "rework"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      orchestrator_name = Module.concat(__MODULE__, :CompletedCodexReplacementOrchestrator)
      {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
      initial_state = :sys.get_state(orchestrator_pid)

      assert is_nil(initial_state.tick_timer_ref)
      assert is_nil(initial_state.tick_token)
      assert is_nil(initial_state.next_poll_due_at_ms)

      {:ok, old_worker} = Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> Process.sleep(:infinity) end)
      old_ref = Process.monitor(old_worker)

      on_exit(fn ->
        File.touch(rework_release)
        System.delete_env("SYMP_TEST_CODEX_TRACE")
        if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
        if Process.alive?(old_worker), do: Process.exit(old_worker, :kill)
      end)

      :sys.replace_state(orchestrator_pid, fn state ->
        if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

        old_entry = %{
          pid: old_worker,
          ref: old_ref,
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          workspace_path: nil,
          session_id: "old-generation",
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_app_server_pid: nil,
          codex_process_group_id: nil,
          repl_pane_id: nil,
          repl_os_pid: nil,
          headless_os_pid: nil,
          agent_input_tokens: 0,
          agent_output_tokens: 0,
          agent_total_tokens: 0,
          agent_last_reported_input_tokens: 0,
          agent_last_reported_output_tokens: 0,
          agent_last_reported_total_tokens: 0,
          turn_count: 1,
          control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
          retry_attempt: 0,
          started_at: DateTime.utc_now()
        }

        %{
          state
          | session_max_concurrent_agents: 1,
            running: %{issue.id => old_entry},
            claimed: MapSet.put(state.claimed, issue.id),
            tick_timer_ref: nil,
            tick_token: make_ref(),
            next_poll_due_at_ms: nil,
            poll_check_in_progress: false
        }
      end)

      send(orchestrator_pid, {:worker_control_state, issue.id, :completed})

      assert %{active: 0} = Orchestrator.max_concurrent_agents(orchestrator_name)

      assert {:ok, item_id} =
               Orchestrator.send_operator_message(orchestrator_name, issue.identifier, %{
                 kind: :text,
                 body: "repair from replacement"
               })

      assert_receive {:DOWN, ^old_ref, :process, ^old_worker, _reason}, 15_000
      refute Process.alive?(old_worker)

      state =
        await_orchestrator_state(orchestrator_pid, fn state ->
          case state.running[issue.id] do
            %{pid: pid} when is_pid(pid) -> pid != old_worker
            _ -> false
          end
        end)

      replacement = state.running[issue.id]
      assert is_pid(replacement.pid)
      assert Process.alive?(replacement.pid)
      assert replacement.pid != old_worker
      assert is_reference(replacement.ref)
      assert replacement.ref != old_ref
      replacement_pid = replacement.pid
      completion_ref = Process.monitor(replacement_pid)

      send(orchestrator_pid, {:DOWN, old_ref, :process, old_worker, :normal})
      assert :sys.get_state(orchestrator_pid).running[issue.id].pid == replacement.pid

      assert wait_for_path(port_closed_after_completion, 15_000)

      assert_receive {:DOWN, ^completion_ref, :process, ^replacement_pid, :normal},
                     15_000

      assert wait_for_path(rework_replayed, 15_000)

      replay_generation = :sys.get_state(orchestrator_pid).running[issue.id]
      assert is_pid(replay_generation.pid)
      assert Process.alive?(replay_generation.pid)
      assert replay_generation.pid != replacement_pid
      replay_pid = replay_generation.pid
      replay_ref = Process.monitor(replay_pid)

      replay_in_flight = :sys.get_state(orchestrator_pid)
      assert replay_in_flight.queue_store.items[item_id].status == :delivered
      assert replay_in_flight.queue_store.items[item_id].delivery_attempts == 2

      File.touch!(rework_release)

      assert_receive {:DOWN, ^replay_ref, :process, ^replay_pid, :normal},
                     15_000

      finished = :sys.get_state(orchestrator_pid)
      assert finished.queue_store.items[item_id].status == :consumed
      assert finished.queue_store.items[item_id].delivery_attempts == 2
      assert Map.get(finished.queue_store.pending_ids_by_target, issue.identifier, []) == []

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

      assert length(turn_texts) == 3
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance"
      assert Enum.at(turn_texts, 2) == "repair from replacement"
    after
      File.touch(Path.join(test_root, "rework.release"))
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      Application.delete_env(:aiur, :memory_tracker_issues)
      File.rm_rf(test_root)
    end
  end
end
