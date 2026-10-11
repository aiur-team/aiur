defmodule Aiur.Orchestrator.Status.PausedChatAndStallTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  alias Aiur.AgentPubSub
  alias Aiur.Orchestrator.OperatorMessages

  test "chat-send to a paused agent auto-resumes it when a slot is free" do
    orchestrator_name = Module.concat(__MODULE__, :ChatPausedAutoResumeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    # max=2, no active agents, 1 paused — there's a free slot, so chatting
    # with the paused agent auto-resumes and enqueues the message instead
    # of erroring. Mirrors the behavior of pressing space on the paused
    # row from the agent list.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 2,
          running: %{
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, parent)
          }
      }
    end)

    assert {:ok, request_id} =
             Orchestrator.send_operator_message(
               orchestrator_name,
               "MT-PAUSED",
               %{kind: :text, body: "hi"}
             )

    assert is_integer(request_id)
    assert_receive {:agent_queue_updated, "MT-PAUSED", ^request_id, _delivery}, 500
    assert_receive {:resume_agent, resume_request_id, generation}, 500

    status = Orchestrator.max_concurrent_agents(orchestrator_name)
    assert status.active == 0
    assert status.paused == 1

    send(pid, {:worker_control_state, "issue-paused", :working, %{request_id: resume_request_id, generation: generation}})

    status = Orchestrator.max_concurrent_agents(orchestrator_name)
    assert status.active == 1
    assert status.paused == 0
  end

  test "a Decision answer is queued before its paused agent is resumed" do
    orchestrator_name = Module.concat(__MODULE__, :DecisionPausedQueueFirstOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 2,
          running: %{
            "issue-paused-decision" => running_entry("issue-paused-decision", "MT-DECISION", :paused, parent)
          }
      }
    end)

    payload = %{
      kind: :text,
      body: "Durable Executor answer for ticket MT-DECISION",
      action_id: "act_queue_first",
      correlation: %{
        decision_id: "dec_queue_first",
        decision_version: 1,
        action_id: "act_queue_first",
        actor: %{kind: :operator, id: "operator-1"}
      },
      delivery_policy: :interrupt,
      fallback: :queue_next
    }

    assert {:ok, %{status: :accepted, item: item}} =
             Orchestrator.send_correlated_operator_message(
               orchestrator_name,
               "MT-DECISION",
               payload
             )

    # Both signals come from the orchestrator process. Mailbox ordering proves
    # the durable input is visible before any worker wake can start a turn.
    # The queue notice does not ask a paused worker to deliver now: the
    # correlated resume is its only wake (#2730).
    assert_receive {:agent_queue_updated, "MT-DECISION", item_id, false}, 500
    assert item_id == item.id
    assert_receive {:resume_agent, _request_id, _generation}, 500

    assert %{id: ^item_id, action_id: "act_queue_first"} =
             :sys.get_state(pid).queue_store.items[item_id]
  end

  test "chat-send to a paused agent errors when no slot is free" do
    orchestrator_name = Module.concat(__MODULE__, :ChatPausedNoCapacityOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    # max=1, 1 active, 1 paused — no free slot. Chat-send to the paused
    # agent must refuse rather than silently flip it to :working and push
    # active over max. The operator must explicitly free capacity first.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{
            "issue-active" => running_entry("issue-active", "MT-ACTIVE", :working, parent),
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused, parent)
          }
      }
    end)

    assert {:error, :max_concurrent_agents_reached} =
             Orchestrator.send_operator_message(
               orchestrator_name,
               "MT-PAUSED",
               %{kind: :text, body: "hi"}
             )

    refute_receive {:resume_agent, _request_id}, 100

    status = Orchestrator.max_concurrent_agents(orchestrator_name)
    assert status.active == 1
    assert status.paused == 1
  end

  test "orchestrator can claim only operator queue items without consuming coordination events" do
    orchestrator_name = Module.concat(__MODULE__, :OperatorOnlyClaimOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      {queue_store, _event_item} =
        Aiur.AgentQueue.coordination_event("MT-QUEUE", :blocker_update, %{summary: "still blocked"})
        |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

      {queue_store, _operator_item} =
        Aiur.AgentQueue.operator_message("MT-QUEUE", "resume now")
        |> then(&Aiur.AgentQueueStore.enqueue(queue_store, &1))

      %{state | queue_store: queue_store}
    end)

    assert {:ok, %{category: :operator_message, body: %{text: "resume now"}}} =
             Orchestrator.claim_next_operator_queue_item(orchestrator_name, "MT-QUEUE")

    assert {:ok, %{category: :coordination_event, body: %{summary: "still blocked"}}} =
             OperatorMessages.claim_next_queue_item(orchestrator_name, "MT-QUEUE")
  end

  test "orchestrator restarts stalled workers with retry backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      agent_stall_timeout_ms: 1_000
    )

    issue_id = "issue-stall"
    orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL",
      issue: %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"},
      session_id: "thread-stall-turn-stall",
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    tick_at_ms = System.monotonic_time(:millisecond)
    send(pid, :tick)

    assert eventually?(fn ->
             state = :sys.get_state(pid)
             not Process.alive?(worker_pid) and not Map.has_key?(state.running, issue_id)
           end)

    state = :sys.get_state(pid)
    observed_at_ms = System.monotonic_time(:millisecond)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-STALL",
             error: "stalled for " <> _
           } = state.retry_attempts[issue_id]

    assert is_integer(due_at_ms)
    # Attempt 1 schedules a fixed 10s base backoff (@failure_retry_base_ms).
    # `due_at_ms` was set to (monotonic_at_schedule + 10_000) at some instant
    # between the tick send and our state read, so it is bounded by those two
    # monotonic readings. Asserting that window is load-independent: a slow
    # scheduler shifts both endpoints together and cannot push `due_at_ms`
    # outside it, unlike the previous `remaining >= 9_500` slack budget that a
    # ~600ms scheduling stall was enough to blow.
    assert due_at_ms >= tick_at_ms + 10_000
    assert due_at_ms <= observed_at_ms + 10_000
  end

  test "orchestrator emits blocker coordination events from poll transitions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Cancelled"]
    )

    blocker = fn state ->
      %Issue{id: "blocker-1", identifier: "MT-1", title: "Blocker", state: state, blocked_by: []}
    end

    blocked_issue = fn blocker_state ->
      %Issue{
        id: "blocked-1",
        identifier: "MT-2",
        title: "Blocked issue",
        state: "Todo",
        blocked_by: [%{id: "blocker-1", identifier: "MT-1", state: blocker_state}]
      }
    end

    Application.put_env(:aiur, :memory_tracker_issues, [
      blocker.("In Progress"),
      blocked_issue.("In Progress")
    ])

    orchestrator_name = Module.concat(__MODULE__, :DependencyEventOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      Application.delete_env(:aiur, :memory_tracker_issues)

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :ok = AgentPubSub.subscribe_poll_state()
    send(pid, :run_poll_cycle)
    await_polled_blocker_state(pid, "blocked-1", "In Progress")

    assert eventually?(fn ->
             Orchestrator.claim_next_queue_item(orchestrator_name, "MT-2") == :empty
           end)

    Application.put_env(:aiur, :memory_tracker_issues, [
      blocker.("Done"),
      blocked_issue.("Done")
    ])

    send(pid, :run_poll_cycle)

    assert eventually?(fn ->
             match?(
               {:ok,
                %{
                  category: :coordination_event,
                  event_type: :blocker_became_terminal,
                  body: %{
                    blocker_issue_identifier: "MT-1",
                    blocked_issue_identifier: "MT-2"
                  }
                }},
               Orchestrator.claim_next_queue_item(orchestrator_name, "MT-2")
             )
           end)
  end

  test "application configures a single-file logger handler when AIUR_DEBUG=1" do
    # The file handler is now gated on AIUR_DEBUG so the default
    # quiet `aiur` invocation doesn't write aiur.log. Set the env
    # and re-configure to verify the handler still installs cleanly
    # in debug mode.
    original = System.get_env("AIUR_DEBUG")
    System.put_env("AIUR_DEBUG", "1")
    Aiur.LogFile.configure()

    on_exit(fn ->
      case original do
        nil -> System.delete_env("AIUR_DEBUG")
        v -> System.put_env("AIUR_DEBUG", v)
      end

      Aiur.LogFile.configure()
    end)

    assert {:ok, handler_config} = :logger.get_handler_config(:aiur_file_log)
    assert handler_config.module == :logger_std_h

    file_config = handler_config.config
    assert file_config.type == :file
    assert is_list(file_config.file)
  end
end
