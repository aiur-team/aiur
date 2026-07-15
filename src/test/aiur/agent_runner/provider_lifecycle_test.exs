defmodule Aiur.AgentRunner.ProviderLifecycleTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.OperatorMessages

  test "response-only terminal operator success completes the real runner" do
    paths = prepare_case("terminal-response", terminal_response_script())
    orchestrator_name = Module.concat(__MODULE__, :TerminalResponseOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    :sys.replace_state(orchestrator_pid, fn state ->
      {queue_store, _item} =
        Aiur.AgentQueue.operator_message("MT-TERMINAL", "finish from the checkpoint")
        |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

      %{state | queue_store: queue_store}
    end)

    issue = issue("MT-TERMINAL")

    assert :ok =
             AgentRunner.run(issue, nil,
               orchestrator: orchestrator_name,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
             )

    assert :empty == OperatorMessages.claim_next_queue_item(orchestrator_name, issue.identifier)
    assert turn_start_count(paths.trace) == 2
  end

  test "late prior turn start cannot wedge the next real runner turn" do
    paths = prepare_case("late-start", late_start_script())
    issue = issue("MT-LATE-START")

    assert :ok = AgentRunner.run(issue, nil, two_turn_opts(issue))
    assert turn_start_count(paths.trace) == 2
  end

  test "duplicate anonymous completion cannot finish the next real runner turn" do
    {marker, release} = lifecycle_barrier("anonymous-seen")
    paths = prepare_case("anonymous", anonymous_script(marker, release))
    issue = issue("MT-ANONYMOUS")
    opts = two_turn_opts(issue)

    task = Task.async(fn -> AgentRunner.run(issue, nil, opts) end)

    assert wait_for_path(marker)
    assert Task.yield(task, 100) == nil

    File.touch!(release)
    assert Task.await(task, 15_000) == :ok
    assert turn_start_count(paths.trace) == 2
  end

  test "idle completion consumes the anonymous fallback before the next real turn" do
    {marker, release} = lifecycle_barrier("idle-boundary")
    paths = prepare_case("idle-boundary", idle_boundary_script(marker, release))
    issue = issue("MT-IDLE-BOUNDARY")
    opts = two_turn_opts(issue)

    task = Task.async(fn -> AgentRunner.run(issue, nil, opts) end)

    assert wait_for_path(marker)
    assert Task.yield(task, 100) == nil

    File.touch!(release)
    assert Task.await(task, 15_000) == :ok
    assert turn_start_count(paths.trace) == 2
  end

  test "cancelled pause retires the old provider turn before the resumed real turn" do
    pause_marker = Path.join(System.tmp_dir!(), "aiur-cancelled-pause-#{System.unique_integer([:positive])}")
    {late_marker, release} = lifecycle_barrier("cancelled-pause-late")
    paths = prepare_case("cancelled-pause", cancelled_pause_script(pause_marker, late_marker, release))
    issue = issue("MT-CANCELLED-PAUSE")
    issue_id = issue.id
    parent = self()
    opts = two_turn_opts(issue)

    on_exit(fn -> File.rm(pause_marker) end)

    task = Task.async(fn -> AgentRunner.run(issue, parent, opts) end)

    assert wait_for_path(pause_marker)
    send(task.pid, {:pause_agent, 71})
    assert_receive {:worker_control_state, ^issue_id, :paused, %{request_id: 71}}, 5_000

    send(task.pid, {:resume_agent, 72})
    assert wait_for_path(late_marker)
    assert Task.yield(task, 100) == nil

    File.touch!(release)
    assert Task.await(task, 15_000) == :ok
    assert turn_start_count(paths.trace) == 2
  end

  test "quota pause retires the failed provider turn before the resumed real turn" do
    pause_marker = Path.join(System.tmp_dir!(), "aiur-quota-pause-#{System.unique_integer([:positive])}")
    {late_marker, release} = lifecycle_barrier("quota-pause-late")
    paths = prepare_case("quota-pause", quota_pause_script(pause_marker, late_marker, release))
    issue = issue("MT-QUOTA-PAUSE")
    issue_id = issue.id
    parent = self()
    opts = two_turn_opts(issue)

    on_exit(fn -> File.rm(pause_marker) end)

    task = Task.async(fn -> AgentRunner.run(issue, parent, opts) end)

    assert wait_for_path(pause_marker)
    assert_receive {:worker_control_state, ^issue_id, :paused, %{kind: :usage_limit_exhausted}}, 5_000

    send(task.pid, {:resume_agent, 81})
    assert wait_for_path(late_marker)
    assert Task.yield(task, 100) == nil

    File.touch!(release)
    assert Task.await(task, 15_000) == :ok
    assert turn_start_count(paths.trace) == 2
  end

  test "operator interrupt consumes the anonymous fallback before its queued turn" do
    ready = Path.join(System.tmp_dir!(), "aiur-operator-interrupt-#{System.unique_integer([:positive])}")
    {late_marker, release} = lifecycle_barrier("operator-interrupt-late")
    paths = prepare_case("operator-interrupt", operator_interrupt_script(ready, late_marker, release))
    orchestrator_name = Module.concat(__MODULE__, :OperatorInterruptOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    issue = issue("MT-OPERATOR-INTERRUPT")

    on_exit(fn ->
      File.rm(ready)
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    task =
      Task.async(fn ->
        AgentRunner.run(issue, nil,
          orchestrator: orchestrator_name,
          max_turns: 1,
          issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
        )
      end)

    assert wait_for_path(ready)

    parent = self()

    :sys.replace_state(orchestrator_pid, fn state ->
      {queue_store, item} =
        Aiur.AgentQueue.operator_message(issue.identifier, "rework after interrupt")
        |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

      send(parent, {:queued_interrupt_item, item})
      %{state | queue_store: queue_store}
    end)

    assert_receive {:queued_interrupt_item, item}

    send(task.pid, {:agent_queue_updated, issue.identifier, item.id, true})
    assert wait_for_path(late_marker)

    case Task.yield(task, 100) do
      nil ->
        :ok

      task_result ->
        queue_status = queue_item_status(orchestrator_pid, item.id)

        flunk(
          "queued turn completed early with result #{inspect(task_result)} " <>
            "and queue status #{inspect(queue_status)}"
        )
    end

    File.touch!(release)
    assert Task.await(task, 15_000) == :ok
    assert :empty == OperatorMessages.claim_next_queue_item(orchestrator_name, issue.identifier)
    assert turn_start_count(paths.trace) == 2
  end

  defp prepare_case(name, script) do
    root = Path.join(System.tmp_dir!(), "aiur-provider-lifecycle-#{name}-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    workspace_root = Path.join(root, "workspaces")
    codex = Path.join(root, "fake-codex")
    trace = Path.join(root, "codex.trace")

    File.mkdir_p!(source)
    File.write!(Path.join(source, "README.md"), "# test")
    File.write!(codex, script)
    File.chmod!(codex, 0o755)
    System.put_env("AIUR_PROVIDER_LIFECYCLE_TRACE", trace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "cp #{Path.join(source, "README.md")} README.md",
      codex_command: "#{codex} app-server",
      max_turns: 2
    )

    on_exit(fn ->
      System.delete_env("AIUR_PROVIDER_LIFECYCLE_TRACE")
      File.rm_rf(root)
    end)

    %{root: root, trace: trace}
  end

  defp issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Provider lifecycle regression",
      description: "Exercise one reused Codex app-server session",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: [],
      selected_backend: "codex"
    }
  end

  defp two_turn_opts(issue) do
    counter = start_supervised!({Agent, fn -> 0 end})

    [
      max_turns: 2,
      issue_state_fetcher: fn [_issue_id] ->
        turn = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
        state = if turn == 1, do: issue.state, else: "Done"
        {:ok, [%{issue | state: state}]}
      end
    ]
  end

  defp terminal_response_script do
    shell_script("""
          *'\"method\":\"turn/start\"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(request_id "$line")
            if [ "$turn_start_count" -eq 1 ]; then
              printf '{"id":%s,"result":{"turn":{"id":"turn-main","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"checkpoint"}]}}'
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-main","status":"completed"}}}\n' "$request_id"
            fi
            ;;
    """)
  end

  defp late_start_script do
    shell_script("""
          *'\"method\":\"turn/start\"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(request_id "$line")
            if [ "$turn_start_count" -eq 1 ]; then
              printf '{"id":%s,"result":{"turn":{"id":"turn-old","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-old","status":"completed"}}}'
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-new","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/started","params":{"turn":{"id":"turn-old","status":"inProgress"}}}'
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-new","status":"completed"}}}'
            fi
            ;;
    """)
  end

  defp anonymous_script(marker, release) do
    shell_script("""
          *'\"method\":\"turn/start\"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(request_id "$line")
            if [ "$turn_start_count" -eq 1 ]; then
              printf '{"id":%s,"result":{"turn":{"id":"turn-old","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-new","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
              touch "#{marker}"
              while [ ! -f "#{release}" ]; do sleep 0.01; done
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-new","status":"completed"}}}'
            fi
            ;;
    """)
  end

  defp idle_boundary_script(marker, release) do
    shell_script("""
          *'\"method\":\"turn/start\"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(request_id "$line")
            if [ "$turn_start_count" -eq 1 ]; then
              printf '{"id":%s,"result":{"turn":{"id":"turn-old","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/started","params":{"turn":{"id":"turn-old","status":"inProgress"}}}'
              printf '%s\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-new","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
              touch "#{marker}"
              while [ ! -f "#{release}" ]; do sleep 0.01; done
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-new","status":"completed"}}}'
            fi
            ;;
    """)
  end

  defp cancelled_pause_script(pause_marker, late_marker, release) do
    shell_script("""
          *'\"method\":\"turn/start\"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(request_id "$line")
            if [ "$turn_start_count" -eq 1 ]; then
              printf '{"id":%s,"result":{"turn":{"id":"turn-old","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/started","params":{"turn":{"id":"turn-old","status":"inProgress"}}}'
              touch "#{pause_marker}"
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-new","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/started","params":{"turn":{"id":"turn-old","status":"inProgress"}}}'
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
              touch "#{late_marker}"
              while [ ! -f "#{release}" ]; do sleep 0.01; done
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-new","status":"completed"}}}'
            fi
            ;;
          *'\"method\":\"turn/interrupt\"'*)
            printf '%s\n' '{"method":"turn/cancelled","params":{"reason":"operator pause"}}'
            ;;
    """)
  end

  defp quota_pause_script(pause_marker, late_marker, release) do
    shell_script("""
          *'\"method\":\"turn/start\"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(request_id "$line")
            if [ "$turn_start_count" -eq 1 ]; then
              printf '{"id":%s,"result":{"turn":{"id":"turn-old","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"error","params":{"willRetry":false,"codexErrorInfo":"usageLimitExceeded","message":"You have hit your usage limit."}}'
              touch "#{pause_marker}"
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-new","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/started","params":{"turn":{"id":"turn-old","status":"inProgress"}}}'
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
              touch "#{late_marker}"
              while [ ! -f "#{release}" ]; do sleep 0.01; done
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-new","status":"completed"}}}'
            fi
            ;;
    """)
  end

  defp operator_interrupt_script(ready, late_marker, release) do
    shell_script("""
          *'\"method\":\"turn/start\"'*)
            turn_start_count=$((turn_start_count + 1))
            request_id=$(request_id "$line")
            if [ "$turn_start_count" -eq 1 ]; then
              printf '{"id":%s,"result":{"turn":{"id":"turn-old","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/started","params":{"turn":{"id":"turn-old","status":"inProgress"}}}'
              touch "#{ready}"
            else
              printf '{"id":%s,"result":{"turn":{"id":"turn-new","status":"inProgress"}}}\n' "$request_id"
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
              touch "#{late_marker}"
              while [ ! -f "#{release}" ]; do sleep 0.01; done
              printf '%s\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-new","status":"completed"}}}'
            fi
            ;;
          *'\"method\":\"turn/interrupt\"'*)
            request_id=$(request_id "$line")
            printf '{"id":%s,"result":{}}\n' "$request_id"
            printf '%s\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
            ;;
    """)
  end

  defp shell_script(turn_start_case) do
    """
    #!/bin/sh
    trace_file="$AIUR_PROVIDER_LIFECYCLE_TRACE"
    turn_start_count=0

    request_id() {
      printf '%s' "$1" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p'
    }

    while IFS= read -r line; do
      printf 'JSON:%s\n' "$line" >> "$trace_file"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-lifecycle"}}}'
          ;;
    #{turn_start_case}
      esac
    done
    """
  end

  defp turn_start_count(trace) do
    trace
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.count(&String.contains?(&1, ~s("method":"turn/start")))
  end

  defp wait_for_path(path, attempts \\ 200)
  defp wait_for_path(_path, 0), do: false

  defp wait_for_path(path, attempts) do
    if File.exists?(path) do
      true
    else
      Process.sleep(25)
      wait_for_path(path, attempts - 1)
    end
  end

  defp lifecycle_barrier(name) do
    root = Path.join(System.tmp_dir!(), "aiur-#{name}-#{System.unique_integer([:positive])}")
    marker = Path.join(root, "reached")
    release = Path.join(root, "release")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    {marker, release}
  end

  defp queue_item_status(orchestrator_pid, item_id) do
    item =
      orchestrator_pid
      |> :sys.get_state()
      |> Map.fetch!(:queue_store)
      |> Aiur.AgentQueueStore.get(item_id)

    if is_nil(item), do: :missing, else: item.status
  end
end
