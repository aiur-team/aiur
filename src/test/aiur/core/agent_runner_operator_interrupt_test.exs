defmodule Aiur.Core.AgentRunnerOperatorInterruptTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.OperatorMessages

  import Aiur.CoreTestSupport

  test "agent runner drains an interrupting operator message after interrupted completion" do
    assert_agent_runner_interrupt_operator(:interrupted_completion)
  end

  test "agent runner drains an interrupting operator message after response-only no-active-turn" do
    assert_agent_runner_interrupt_operator(:no_active_turn)
  end

  defp assert_agent_runner_interrupt_operator(interrupt_outcome) do
    outcome_name = Atom.to_string(interrupt_outcome)

    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-agent-runner-interrupt-operator-#{outcome_name}")

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
      startup_marker="${SYMP_TEST_CODEX_STARTUP:-/tmp/codex-startup}"
      printf 'child_started %s\n' "$(date +%s)" > "$startup_marker"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-interrupt-operator"}}}'
            ;;
          *'"method":"turn/start"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')

            if [ "$first_turn_started" -eq 0 ]; then
              first_turn_started=1
              printf '{"id":%s,"result":{"turn":{"id":"turn-main"}}}\\n' "$request_id"
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-operator"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
              exit 0
            fi
            ;;
          *'"method":"turn/interrupt"'*)
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      #{operator_interrupt_frames(interrupt_outcome)}
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      System.put_env("SYMP_TEST_CODEX_STARTUP", Path.join(test_root, "codex-startup"))

      on_exit(fn ->
        System.delete_env("SYMP_TEST_CODEX_TRACE")
        System.delete_env("SYMP_TEST_CODEX_STARTUP")
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      orchestrator_name =
        Module.concat(
          __MODULE__,
          "InterruptOperator#{Macro.camelize(outcome_name)}Orchestrator"
        )

      {:ok, orchestrator_pid} =
        Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

      on_exit(fn ->
        stop_test_orchestrator(orchestrator_pid)
      end)

      assert %{
               next_poll_due_at_ms: nil,
               poll_check_in_progress: false,
               tick_timer_ref: nil
             } = :sys.get_state(orchestrator_pid)

      issue_id = "issue-interrupt-operator-#{outcome_name}"
      identifier = "MT-INTERRUPT-OPERATOR-#{String.upcase(outcome_name)}"

      issue = %Issue{
        id: issue_id,
        identifier: identifier,
        title: "Interrupt with operator message",
        description: "Stop the active turn and deliver the operator input next",
        state: "In Progress",
        url: "https://example.org/issues/MT-253",
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

      startup_started_at = System.monotonic_time(:millisecond)

      receive do
        {:codex_worker_update, ^issue_id, %{event: :session_started}} -> :ok
      after
        5_000 ->
          elapsed_ms = System.monotonic_time(:millisecond) - startup_started_at
          fake_child = File.read(Path.join(test_root, "codex-startup"))
          codex_trace = File.read(trace_file)

          flunk("session did not start within 5s; elapsed_ms=#{elapsed_ms}; fake_child_marker=#{inspect(fake_child)}; task=#{inspect(Task.yield(task, 0))}; codex trace=#{inspect(codex_trace)}")
      end

      startup_event_at = System.monotonic_time(:millisecond)
      startup_marker = Path.join(test_root, "codex-startup")
      assert File.exists?(startup_marker), "session_started must follow fake Codex child startup"
      assert ["child_started", _unix_seconds] = String.split(String.trim(File.read!(startup_marker)), " ")

      :sys.replace_state(orchestrator_pid, fn state ->
        {queue_store, item} =
          Aiur.AgentQueue.operator_message(identifier, "stop and answer this", delivery_policy: :interrupt)
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        send(test_pid, {:queued_request_id, item.id})
        %{state | queue_store: queue_store}
      end)

      assert_receive {:queued_request_id, request_id}, 1000
      send(task.pid, {:agent_queue_updated, identifier, request_id, true})

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
      assert Enum.at(turn_texts, 1) == "stop and answer this"
      assert :empty == OperatorMessages.claim_next_queue_item(orchestrator_name, identifier)
      assert startup_event_at - startup_started_at < 5_000
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      System.delete_env("SYMP_TEST_CODEX_STARTUP")
      Aiur.TestCleanup.rm_rf!(test_root)
    end
  end

  defp operator_interrupt_frames(:interrupted_completion) do
    """
            printf '{"id":%s,"result":{}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"interrupted"}}}'
    """
  end

  defp operator_interrupt_frames(:no_active_turn) do
    """
            printf '{"id":%s,"error":{"code":-32600,"message":"no active turn"}}\\n' "$request_id"
    """
  end
end
