defmodule Aiur.Regression.OrchestratorTrackerIoTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, DispatchBudgetStore, Issue, Orchestrator}
  alias Aiur.Orchestrator.{OperatorMessages, PauseResume, SnapshotStore, StatusReport}

  defmodule SlowTracker do
    def fetch_candidate_issues do
      {owner, token} = Application.fetch_env!(:aiur, :tracker_io_test_barrier)
      send(owner, {:poll_started, token, self()})

      receive do
        {:release_poll, ^token} -> {:error, :controlled_poll_failure}
      after
        10_000 -> {:error, :test_barrier_expired}
      end
    end

    def fetch_issue_states_by_ids(_ids),
      do: {:ok, [Application.fetch_env!(:aiur, :tracker_io_test_issue)]}

    def fetch_issues_by_states(_states, _opts), do: {:ok, []}
  end

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "linear", max_concurrent_agents: 4)
    put_test_env(:linear_client_module, SlowTracker)
    put_test_env(:control_api_call_timeout_ms, 200)
    put_test_env(:operator_message_call_timeout_ms, 200)

    token = make_ref()
    put_test_env(:tracker_io_test_barrier, {self(), token})
    issue = %Issue{id: "tracker-io-3213", identifier: "IO-3213", title: "Tracker I/O regression", state: "In Progress"}
    put_test_env(:tracker_io_test_issue, issue)
    put_test_env(:dispatch_budget_store_path, Path.join(System.tmp_dir!(), "tracker-io-budget-#{System.unique_integer([:positive])}.json"))
    budget_path = DispatchBudgetStore.path_for()
    on_exit(fn -> File.rm(budget_path) end)
    :ok = DispatchBudgetStore.put_lifetime(issue.id, 3)

    server = start_supervised!({Orchestrator, initial_poll?: false})
    worker = spawn(fn -> receive do: (:stop -> :ok) end)

    :sys.replace_state(server, fn state ->
      entry = %{
        issue: issue,
        identifier: issue.identifier,
        pid: worker,
        ref: make_ref(),
        started_at: DateTime.utc_now(),
        control: %{status: :working, generation: 1, version: 1, can_interrupt: true, safe_checkpoints: [:notification]}
      }

      %{state | running: %{issue.id => entry}, last_polled_issues: %{issue.id => issue}, claimed: MapSet.new([issue.id]), snapshot_ready?: true}
    end)

    on_exit(fn ->
      send(worker, :stop)

      if Process.alive?(server) do
        :sys.replace_state(server, fn state -> %{state | running: %{}} end)
      end
    end)

    {:ok, server: server, issue: issue, token: token}
  end

  test "candidate tracker work runs outside the orchestrator", %{server: server, token: token} do
    patterns = [
      {Aiur.Tracker, :fetch_candidate_issues, :_},
      {Aiur.Tracker, :fetch_issues_by_states, :_},
      {Aiur.Tracker, :fetch_issue_states_by_ids, :_},
      {Aiur.Tracker, :fetch_issue_states_by_ids_conditional, :_},
      {Aiur.Tracker, :update_issue_state, :_},
      {Aiur.Tracker, :add_label, :_},
      {Aiur.Tracker, :remove_label, :_},
      {Aiur.GitHub.Tracker, :fetch_candidate_issues_conditional, :_},
      {Aiur.GitHub.Tracker, :hydrate_blocked_by, :_},
      {Aiur.Events.GithubFirehose, :poll, :_},
      {Aiur.Events.GithubCIPoller, :poll, :_}
    ]

    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(server, true, [:call, {:tracer, self()}])
    send(server, :run_poll_cycle)
    assert_receive {:poll_started, ^token, tracker_pid}, 2_000

    try do
      refute tracker_pid == server, "the tracker is executing in the orchestrator handler"
    after
      send(tracker_pid, {:release_poll, token})
      await_poll_finished(server)
      delivery = :erlang.trace_delivered(server)
      assert_receive {:trace_delivered, ^server, ^delivery}, 1_000
      :erlang.trace(server, false, [:call])
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
      refute_receive {:trace, ^server, :call, _remote_call}, 0, "an orchestrator handler performed remote work"
    end
  end

  test "public controls, enqueue and runner claim finish while the poll is held", %{server: server, issue: issue, token: token} do
    assert {:ok, seeded_id} = OperatorMessages.send_operator_message(server, issue.identifier, %{kind: :text, body: "seeded before poll"})
    state = :sys.get_state(server)
    :ok = SnapshotStore.publish(server, StatusReport.snapshot_payload(state), state)
    send(server, :run_poll_cycle)
    assert_receive {:poll_started, ^token, tracker_pid}, 2_000

    calls = [
      status: fn -> Orchestrator.fleet_view(server, 200, fleet_rows?: true) end,
      resume: fn -> PauseResume.resume_agent(server, issue.identifier) end,
      reset: fn -> PauseResume.reset_dispatch_budget(server, issue.identifier) end,
      message: fn -> OperatorMessages.send_operator_message(server, issue.identifier, %{kind: :text, body: "sent during poll", message_id: "during-poll-3213"}) end,
      claim: fn -> Orchestrator.claim_next_queue_item(server, issue.identifier) end
    ]

    tasks = Enum.map(calls, fn {name, fun} -> {name, Task.async(fun)} end)

    try do
      results =
        tasks
        |> Enum.map(&elem(&1, 1))
        |> Task.yield_many(1_000)
        |> Enum.map(fn {task, result} -> {task.ref, result} end)
        |> Map.new()

      replies = Map.new(tasks, fn {name, task} -> {name, Map.fetch!(results, task.ref)} end)
      assert {:ok, {:ok, snapshot, _freshness}} = replies.status
      assert Enum.any?(snapshot.statuses, &(&1.identifier == issue.identifier))
      assert replies.resume == {:ok, {:ok, :already_running}}
      assert replies.reset == {:ok, {:ok, :reset}}
      assert {:ok, {:ok, sent_id}} = replies.message
      assert {:ok, {:ok, %{id: ^seeded_id, body: %{text: "seeded before poll"}}}} = replies.claim
      assert DispatchBudgetStore.lifetime(issue.id) == {:ok, 0}

      # Completion must not replace the queue with the state captured before these calls.
      send(tracker_pid, {:release_poll, token})
      state = await_poll_finished(server)
      assert AgentQueueStore.get(state.queue_store, seeded_id).status == :delivered
      assert %{body: %{text: "sent during poll"}, status: :pending} = AgentQueueStore.get(state.queue_store, sent_id)
    after
      Enum.each(tasks, fn {_name, task} -> Task.shutdown(task, :brutal_kill) end)
      send(tracker_pid, {:release_poll, token})
      await_poll_finished(server)
    end
  end

  defp await_poll_finished(server, attempts \\ 200)
  defp await_poll_finished(_server, 0), do: flunk("poll did not finish")

  defp await_poll_finished(server, attempts) do
    state = :sys.get_state(server)

    if state.poll_cycles_completed > 0 and state.tracker_tasks == %{} do
      state
    else
      Process.sleep(10)
      await_poll_finished(server, attempts - 1)
    end
  end

  defp put_test_env(key, value) do
    previous = Application.fetch_env(:aiur, key)
    Application.put_env(:aiur, key, value)

    on_exit(fn ->
      case previous do
        {:ok, original} -> Application.put_env(:aiur, key, original)
        :error -> Application.delete_env(:aiur, key)
      end
    end)
  end
end
