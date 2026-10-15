defmodule Aiur.Core.AgentRunnerCheckpointQueueTest do
  use Aiur.TestSupport
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.OperatorMessages

  defmodule CheckpointNoPollClient do
    def fetch_issues_by_states(_states, _opts \\ []), do: {:ok, []}
    def fetch_candidate_issues, do: raise("queue-only checkpoint fixture must not poll the tracker")
  end

  test "agent runner delivers queued operator messages at the turn boundary after a deferred checkpoint" do
    test_root =
      Path.join(
        "/tmp",
        "aiur-elixir-agent-runner-checkpoint-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    isolate_ownership_store!(test_root)

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
      first_turn_started=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-checkpoint"}}}'
            ;;
          *'"method":"turn/start"'*)
            if [ "$first_turn_started" -eq 0 ]; then
              first_turn_started=1
              request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
              printf '{"id":%s,"result":{"turn":{"id":"turn-checkpoint-main"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"keep going"}]}}'
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-checkpoint-main","status":"completed"}}}'
            else
              request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
              printf '{"id":%s,"result":{"turn":{"id":"turn-accepted-steering","status":"inProgress"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-accepted-steering","status":"completed"}}}'
              exit 0
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

      previous_client = Application.fetch_env(:aiur, :linear_client_module)
      Application.put_env(:aiur, :linear_client_module, CheckpointNoPollClient)

      on_exit(fn ->
        case previous_client do
          {:ok, client} -> Application.put_env(:aiur, :linear_client_module, client)
          :error -> Application.delete_env(:aiur, :linear_client_module)
        end
      end)

      orchestrator_name = Module.concat(__MODULE__, :CheckpointOperatorOrchestrator)
      # Keep this checkpoint fixture independent of live tracker polling.
      orchestrator_pid = start_supervised!({Orchestrator, name: orchestrator_name, initial_poll?: false})

      test_pid = self()

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, item} =
          Aiur.AgentQueue.operator_message("MT-250", "focus on auth first")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        send(test_pid, {:checkpoint_queue_item, item.id})
        %{state | queue_store: queue_store}
      end)

      assert_received {:checkpoint_queue_item, request_id}

      issue = %Issue{
        id: "issue-checkpoint-queue",
        identifier: "MT-250",
        title: "Deliver queued operator message from checkpoint",
        description: "Deliver follow-up before the original turn returns",
        state: "In Progress",
        url: "https://example.org/issues/MT-250",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 orchestrator: orchestrator_name,
                 run_turn: fn session, prompt, turn_issue, opts ->
                   on_message = Keyword.fetch!(opts, :on_message)

                   observe_completion = fn event ->
                     if event.event == :turn_completed and get_in(event, [:payload, "params", "turn", "id"]) == "turn-checkpoint-main" do
                       assert {:ok, :pending} = OperatorMessages.operator_message_status(orchestrator_name, request_id)
                       send(test_pid, :checkpoint_deferred_until_completion)
                     end

                     on_message.(event)
                   end

                   Aiur.CodingAgent.run_turn(session, prompt, turn_issue, Keyword.put(opts, :on_message, observe_completion))
                 end,
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

      assert_received :checkpoint_deferred_until_completion
      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) == "focus on auth first"
      assert {:ok, :consumed} = OperatorMessages.operator_message_status(orchestrator_name, request_id)
      assert :empty == OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-250")

      assert Exchange.bindings_for(orchestrator_pid) != []
      assert :ok = stop_supervised(Orchestrator)
      assert Process.whereis(orchestrator_name) == nil
      :sys.get_state(Exchange)
      assert Exchange.bindings_for(orchestrator_pid) == []
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner requeues drained operator message when parent turn completes before delivery acknowledgement" do
    test_root =
      Path.join(
        "/tmp",
        "aiur-elixir-agent-runner-checkpoint-completion-race-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    isolate_ownership_store!(test_root)

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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-completion-race"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')

            case "$turn_start_count" in
              1)
                printf '{"id":%s,"result":{"turn":{"id":"turn-main"}}}\\n' "$request_id"
                printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
                ;;
              2)
                # Simulate the completion-boundary race: the app-server accepts
                # bytes for the drained follow-up but never acknowledges this
                # turn/start request after the parent turn completed.
                ;;
            esac
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

      orchestrator_name = Module.concat(__MODULE__, :CheckpointCompletionRaceOrchestrator)
      orchestrator_pid = start_supervised!({Orchestrator, name: orchestrator_name, initial_poll?: false})

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, _item} =
          Aiur.AgentQueue.operator_message("MT-254", "finish with this guardrail")
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        %{state | queue_store: queue_store}
      end)

      issue = %Issue{
        id: "issue-checkpoint-completion-race",
        identifier: "MT-254",
        title: "Requeue operator input after completion race",
        description: "Do not fail completed parent turn when checkpoint follow-up loses race",
        state: "In Progress",
        url: "https://example.org/issues/MT-254",
        labels: []
      }

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok =
                   AgentRunner.run(
                     issue,
                     nil,
                     orchestrator: orchestrator_name,
                     issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
                   )
        end)

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
      assert Enum.at(turn_texts, 1) == "finish with this guardrail"

      assert {:ok, %{category: :operator_message, body: %{text: "finish with this guardrail"}}} =
               OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-254")

      assert :sys.get_state(orchestrator_pid).retry_attempts == %{}

      matching_log =
        log
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "issue_id=issue-checkpoint-completion-race"))
        |> Enum.join("\n")

      assert matching_log =~ "Queued item delivery lost completion race"
      assert matching_log =~ "request_id="
      assert matching_log =~ "decision=requeue_after_parent_turn_completed"
      refute matching_log =~ "Agent run failed"
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  defp isolate_ownership_store!(test_root) do
    previous = Application.get_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, Path.join(test_root, "decisions"))

    :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Workspace.Ownership.Store)
    {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, Aiur.Workspace.Ownership.Store)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :decision_state_dir, previous),
        else: Application.delete_env(:aiur, :decision_state_dir)

      :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Workspace.Ownership.Store)
      {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, Aiur.Workspace.Ownership.Store)
    end)
  end
end
