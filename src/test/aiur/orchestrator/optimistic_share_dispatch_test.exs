defmodule Aiur.Orchestrator.OptimisticShareDispatchTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.Hints
  alias Aiur.Orchestrator.{DispatchCandidates, Dispatcher, DispatchPolicy, IssueSync, OptimisticLedger, OptimisticSlots, PauseResume, Slots, State, StatusReport, TrackerTasks}
  alias Aiur.StartTrigger.ProgressStore

  setup do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OptimisticLedger)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OptimisticLedger) end)
    ledger_root = Aiur.TestSupport.tmp_root!("optimistic-dispatch-ledger")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(ledger_root) end)
    start_supervised!({OptimisticLedger, path: Path.join(ledger_root, "starts.json")})
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    set_share(0.5)
    :ets.new(Hints.table_name(), [:named_table, :set])
    on_exit(fn -> File.write!(path, original) end)
    :ok
  end

  test "ready work precedes priority-one optimistic work, then depth and downstream count break ties" do
    ready = issue("ready", 4)
    shallow = optimistic("shallow", 1)
    deep = optimistic("deep", 4)
    wide = optimistic("wide", 4)
    held = %{issue("held", 1) | blocked_by: [%{id: "unready", state: "in-progress"}]}
    graph = [dependent("a", deep), dependent("b", issue("a")), dependent("c", wide), dependent("d", wide)]
    ordered = DispatchCandidates.order([shallow, wide, deep, held, ready], DispatchPolicy.terminal_state_set(), graph)
    assert Enum.map(ordered, & &1.id) == ~w(ready deep wide shallow held)
    :ets.insert(Hints.table_name(), {shallow.id, {-5, 0}, false, :pr_opened, 4})
    assert Enum.map(DispatchCandidates.order([shallow, deep, ready], DispatchPolicy.terminal_state_set(), graph), & &1.id) == ~w(ready shallow deep)
  end

  test "four free slots start three ready and the deepest optimistic, then decline the share" do
    parent = self()
    ready = Enum.map(1..3, &issue("ready-#{&1}", 4))
    optimistic = Enum.map(1..5, &optimistic("opt-#{&1}", 1))
    graph = [dependent("child", Enum.at(optimistic, 4)), dependent("grandchild", issue("child"))]
    existing = Enum.map(1..3, &optimistic("running-#{&1}")) ++ [issue("running-ready")]

    state = %State{
      snapshot_key: self(),
      max_concurrent_agents: 8,
      effective_concurrent_agents: 8,
      running: Map.new(existing, &{&1.id, %{issue: &1, start_mode: if(&1.blocked_by == [], do: :ready, else: :optimistic)}}),
      last_polled_issues: Map.new(existing ++ graph, &{&1.id, &1})
    }

    pending =
      Dispatcher.choose_issues(state, optimistic ++ ready,
        issue_fetcher: fn [id] -> {:ok, [Enum.find(optimistic ++ ready, &(&1.id == id))]} end,
        blocked_by_hydrator: fn issue -> {:ok, issue} end,
        blocker_subscriber: fn _, _ -> :ok end,
        blocker_ref_lookup: &blocker_head/1,
        runner: fn issue, _, _ ->
          send(parent, {:started, issue.id})
          :ok
        end
      )

    final = Enum.reduce(1..4, pending, fn _, state -> apply_result(state) end)
    assert map_size(final.running) == 8
    assert Map.keys(final.running) |> Enum.filter(&String.starts_with?(&1, "opt-")) == ["opt-5"]
    assert final.running["opt-5"].start_mode == :optimistic
    for candidate <- ready, do: assert(final.running[candidate.id].start_mode == :ready)
    for candidate <- Enum.take(optimistic, 4), do: assert(final.dispatch_declines[candidate.id] == :optimistic_share)
    for id <- ~w(ready-1 ready-2 ready-3 opt-5), do: receive_barrier({:started, ^id})
    refute_received {:started, _}
  end

  test "zero share disables optimistic dispatch and effective one still grants one slot" do
    set_share(0)
    candidate = optimistic("opt")
    state = %State{max_concurrent_agents: 8, effective_concurrent_agents: 1}
    assert DispatchPolicy.dispatch_decision(candidate, state) == {:skip, :optimistic_share}
    assert DispatchPolicy.manual_resume_decision(candidate, state) == {:skip, :optimistic_share}
    assert DispatchPolicy.dispatch_decision(issue("ready"), state) == :dispatch
    assert Slots.max_concurrent_agent_status(state).optimistic == %{running: 0, cap: 0, share: 0.0}
    set_share(0.5)
    assert Slots.max_concurrent_agent_status(state).optimistic == %{running: 0, cap: 1, share: 0.5}
    assert DispatchPolicy.dispatch_decision(candidate, state) == :dispatch
  end

  test "dispatch-time hydration cannot bypass zero share on a cold dependency cache" do
    set_share(0)
    hydrated = optimistic("cold")
    candidate = %{hydrated | blocked_by: nil}

    pending =
      Dispatcher.dispatch_issue(%State{snapshot_key: self(), max_concurrent_agents: 8}, candidate, nil, nil,
        issue_fetcher: fn _ -> {:ok, [candidate]} end,
        blocked_by_hydrator: fn _ -> {:ok, hydrated} end,
        runner: fn _, _, _ -> flunk("optimistic runner must not start with zero share") end
      )

    final = apply_result(pending)
    assert final.running == %{}
    assert final.dispatch_declines[candidate.id] == :optimistic_share
  end

  test "a blocker merge frees optimistic occupancy and a redispatch stamps ready" do
    candidate = optimistic("opt")

    state = %State{
      snapshot_key: self(),
      max_concurrent_agents: 2,
      effective_concurrent_agents: 2,
      running: %{candidate.id => %{issue: candidate, start_mode: :optimistic}},
      last_polled_issues: %{candidate.id => candidate}
    }

    assert OptimisticSlots.status(state).running == 1
    assert DispatchPolicy.dispatch_decision(optimistic("next"), state) == {:skip, :optimistic_share}
    ProgressStore.record(hd(candidate.blocked_by).id, %{stage: :pr_merged, source: :test})
    :sys.get_state(ProgressStore)
    assert OptimisticSlots.status(state).running == 0
    assert DispatchPolicy.dispatch_decision(optimistic("next"), state) == :dispatch

    pending =
      Dispatcher.dispatch_issue(%{state | running: %{}}, candidate, nil, nil,
        issue_fetcher: fn _ -> {:ok, [candidate]} end,
        blocked_by_hydrator: fn issue -> {:ok, issue} end,
        blocker_subscriber: fn _, _ -> :ok end,
        blocker_ref_lookup: &blocker_head/1,
        runner: fn _, _, _ -> :ok end
      )

    assert apply_result(pending).running[candidate.id].start_mode == :ready
  end

  test "a GitHub cache miss retains runner dependencies until merged evidence releases share" do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "owner/repo", max_concurrent_agents: 8)
    candidate = optimistic("cache-miss")
    :ets.insert(Hints.table_name(), {candidate.id, {0, 0}, false, :pr_opened})
    polled = %{candidate | blocked_by: []}
    state = %State{max_concurrent_agents: 8, running: %{candidate.id => %{issue: candidate, start_mode: :optimistic}}, last_polled_issues: %{candidate.id => polled}}
    assert OptimisticSlots.status(state).running == 1
    ProgressStore.record(hd(candidate.blocked_by).id, %{stage: :pr_merged, source: :test})
    :sys.get_state(ProgressStore)
    assert OptimisticSlots.status(state).running == 0
  end

  test "reserved pauses count, CI pauses release, and missing snapshots preserve start mode" do
    candidate = optimistic("opt")
    entry = %{issue: candidate, start_mode: :optimistic, control: %{status: :paused}, paused_reason: :input_required}
    state = %State{max_concurrent_agents: 4, running: %{candidate.id => entry}}
    assert OptimisticSlots.status(state).running == 1
    assert OptimisticSlots.status(%{state | running: %{candidate.id => %{entry | paused_reason: :ci_wait}}}).running == 0
    assert OptimisticSlots.status(%{state | running: %{candidate.id => %{entry | control: %{status: :completed}}}}).running == 0
  end

  test "status and resume name the share cap without a capacity-starvation alert" do
    candidate = optimistic("opt")
    set_share(0)

    state = %State{
      snapshot_key: self(),
      max_concurrent_agents: 8,
      effective_concurrent_agents: 8,
      last_polled_issues: %{candidate.id => candidate},
      dispatch_declines: %{candidate.id => :optimistic_share}
    }

    assert :optimistic_share in DispatchPolicy.dispatch_decline_reasons()
    assert PauseResume.resume_decline_reason(:optimistic_share, candidate, state) == {:optimistic_share, %{running: 0, cap: 0, share: 0.0}}
    assert OptimisticSlots.label(Slots.max_concurrent_agent_status(state)) == "; optimistic 0/0"
    {:reply, rows, _} = StatusReport.status(state)
    row = Enum.find(rows, &(&1.identifier == candidate.identifier))
    assert row.waiting_reason == :optimistic_share
    assert row.reason == "waiting: optimistic share full (0/0)"
    refute IssueSync.sync_capacity_starvation_alert(state, [candidate]).capacity_starvation.alert_active
    refute IssueSync.sync_fleet_capacity_starved_alert(state, [candidate]).fleet_capacity_starvation.alert_active
  end

  defp issue(id, priority \\ 2), do: %Issue{id: id, identifier: "repo##{id}", title: id, state: "todo", priority: priority, blocked_by: []}

  defp optimistic(id, priority \\ 2) do
    blocker = to_string(System.unique_integer([:positive]))
    %{issue(id, priority) | blocked_by: [%{id: blocker, identifier: blocker, state: "ci-wait"}]}
  end

  defp blocker_head(id), do: %{ref: "refs/heads/aiur/#{id}-work", sha: String.duplicate("a", 40)}

  defp dependent(id, blocker), do: %{issue(id) | blocked_by: [%{id: blocker.id, state: "todo"}]}

  defp set_share(share) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, max_concurrent_agents: 8)
    File.write!(path, File.read!(path) <> "\nbuild_queue:\n  optimistic_slot_share: #{share}\n  start_trigger: pr_opened\n")
    Aiur.WorkflowStore.force_reload()
  end

  defp apply_result(state) do
    [ref] = Map.keys(state.tracker_tasks)
    receive_barrier({^ref, result})
    {:handled, next} = TrackerTasks.result(state, ref, result)
    next
  end
end
