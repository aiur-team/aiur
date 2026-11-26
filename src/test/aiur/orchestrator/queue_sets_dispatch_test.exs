defmodule Aiur.Orchestrator.QueueSetsDispatchTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.{AgentControlCLI, Issue}
  alias Aiur.BuildQueue.{Hints, Model, Reconcile}
  alias Aiur.Orchestrator.{BuildQueueClaimProbe, DispatchCandidates, Dispatcher, DispatchPolicy, PauseResume, QueueSetSlots, Slots, State, StatusReport, TrackerTasks}

  setup do
    test_pid = self()
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    configure()
    :ets.new(Hints.table_name(), [:named_table, :set])
    on_exit(fn -> File.write!(path, original) end)
    on_exit(fn -> Aiur.TestSupport.stop_test_runners(test_pid) end)
    :ok
  end

  defmodule QueueBoundary do
    alias Aiur.Issue
    alias Aiur.Orchestrator.{BuildQueueClaimProbe, State}
    def load, do: Agent.get(__MODULE__, &{:ok, &1})
    def save(document), do: Agent.update(__MODULE__, fn _ -> document end)
    def open_issue_labels(_), do: {:ok, Map.new(1..12, &{to_string(&1), %{labels: ~w(agent:queued agent:todo)}}), System.system_time(:millisecond)}
    def blocked_by(_), do: {:ok, []}
    def ticket_pull_request(_), do: {:ok, nil}
    def status(ids), do: Map.new(ids, &{&1, :unclaimed})

    def next_set do
      document = Agent.get(__MODULE__, & &1)
      issues = Map.new(document.items, fn item -> {item.issue_id, %Issue{id: item.issue_id, identifier: "repo##{item.issue_id}", title: "ticket", state: "todo", blocked_by: []}} end)
      BuildQueueClaimProbe.next_set(%State{max_concurrent_agents: 6, effective_concurrent_agents: 6, last_polled_issues: issues})
    end

    def add_label(_, _), do: raise("ordering must not write GitHub labels")
    def remove_label(_, _), do: raise("ordering must not write GitHub labels")
    def notify_demand(_), do: :ok
  end

  test "CLI reorders three persisted sets and real reconciliation and dispatch follow the new ranks" do
    {document, issues, _} = fixture()
    start_supervised!({Agent, fn -> document end}, id: :rank_store) |> Process.register(QueueBoundary)
    owner = self()
    :ets.delete(Hints.table_name())

    pid =
      start_supervised!(
        {Aiur.BuildQueue.Server,
         name: nil,
         store: QueueBoundary,
         tracker: QueueBoundary,
         claim_probe: QueueBoundary,
         settings: {:ok, Config.settings!()},
         exchange: :absent_rank_exchange,
         schedule: fn target, message, _ ->
           send(owner, {target, message})
           make_ref()
         end}
      )

    assert_received {^pid, {:reconcile, token}}
    send(pid, {:reconcile, token})
    assert GenServer.call(pid, :status) == :running
    assert Enum.all?(Aiur.BuildQueue.show(pid).queues, &(&1.counts.ready > 0))

    for {name, rank} <- [{"set 2", 0}, {"set 0", 2}, {"set 1", 1}] do
      capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :order, queue: name, to: rank, server: pid) == 0 end)
    end

    assert Enum.map(Agent.get(QueueBoundary, & &1.queues), &{&1.name, &1.rank}) == [{"set 2", 0}, {"set 1", 1}, {"set 0", 2}]
    assert Enum.sort(Map.keys(dispatch(issues).running)) == ~w(10 11 12 3 8 9)
    output = capture_io(fn -> assert Aiur.BuildQueueCLI.run(verb: :order, server: pid, caller_agent_workspace: "/caller") == 0 end)
    assert output =~ "queue order  actual set 2 > set 1 > set 0  declared unavailable"
    assert output =~ "0  set 2\n1  set 1\n2  set 0\n"
    output = capture_io(fn -> Aiur.BuildQueueCLI.run(server: pid, claim_probe: QueueBoundary) end)
    assert output =~ "NEXT  set 2  rank 0"
    json = capture_io(fn -> Aiur.BuildQueueCLI.run(server: pid, json: true, claim_probe: QueueBoundary) end) |> Jason.decode!()
    assert Enum.map(json["queues"], &{&1["set_rank"], &1["state"]}) == [{0, "next"}, {1, "waiting"}, {2, "waiting"}]
  end

  test "six slots dispatch two A and four B members by set rank then position" do
    {document, issues, projections} = fixture()
    publish(document, projections)
    final = dispatch(issues)
    assert Enum.sort(Map.keys(final.running)) == ~w(1 2 3 4 5 6)
    assert Slots.available_slots(final) == 0
    ordered = DispatchCandidates.order(Enum.reverse(issues), DispatchPolicy.terminal_state_set())
    assert Enum.map(ordered, & &1.id) == Enum.map(issues, & &1.id)
  end

  test "an unprioritized flake ticket waits behind every startable build-order list member" do
    {document, issues, projections} = fixture()
    queues = Enum.with_index(document.queues) |> Enum.map(fn {queue, rank} -> %{queue | kind: :build_order, root: 1600 + rank} end)
    items = Enum.map(document.items, &%{&1 | position: nil})
    document = %{document | queues: queues, items: items}
    publish(document, projections)
    flake = %Issue{id: "flake", identifier: "repo#flake", title: "Flaky test: example", state: "todo", priority: nil, blocked_by: []}

    ordered = DispatchCandidates.order(issues ++ [flake], DispatchPolicy.terminal_state_set())

    # Future regression guard: unlisted/default-priority tickets remain after all ranked queue members.
    assert MapSet.new(Enum.map(Enum.take(ordered, length(issues)), & &1.id)) == MapSet.new(Enum.map(issues, & &1.id))
    assert List.last(ordered).id == "flake"
  end

  test "max one active set starts only A and reports B waiting with four slots free" do
    configure(max_active_sets: 1)
    {document, issues, projections} = fixture()
    publish(document, projections)
    final = dispatch(issues)
    assert Enum.sort(Map.keys(final.running)) == ~w(1 2)
    assert Slots.available_slots(final) == 4
    for issue <- Enum.drop(issues, 2), do: assert(final.dispatch_declines[issue.id] == :queue_set_order)
    assert DispatchPolicy.manual_resume_decision(Enum.at(issues, 2), final) == {:skip, :queue_set_order}
    assert PauseResume.resume_decline_reason(:queue_set_order, Enum.at(issues, 2), final) =~ "max_active_sets 1"
    assert {:declined, {:queue_set_order, reason}} = BuildQueueClaimProbe.classify(final, "3")
    assert reason == "queue_set_order: set 2 waits for set 1 (max_active_sets 1)"
    rows = StatusReport.agent_statuses(final)
    row = Enum.find(rows, &(&1.issue_id == "3"))
    assert row.waiting.reason == :queue_set_order
    assert row.waiting.owner == "DispatchPolicy"
    assert row.waiting.cause == reason
    output = capture_io(fn -> AgentControlCLI.agents(fleet_view: {:ok, StatusReport.snapshot_payload(final), %{status: :current, age_seconds: 0}}) end)
    assert output =~ reason
  end

  test "none preserves existing ordinary ordering instead of preferring A" do
    configure(set_order: "none")
    {document, issues, projections} = fixture()
    publish(document, projections)
    expected = DispatchCandidates.order(issues, DispatchPolicy.terminal_state_set())
    assert Enum.map(Enum.take(expected, 6), & &1.id) == ~w(3 8 4 9 10 5)
    final = dispatch(issues)
    assert MapSet.new(Map.keys(final.running)) == MapSet.new(Enum.take(expected, 6), & &1.id)
  end

  test "absent set config preserves ordinary dispatch order for the same queue store" do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "agent", max_concurrent_agents: 6)
    Aiur.WorkflowStore.force_reload()
    {document, issues, projections} = fixture()
    publish(document, projections)
    ordered = DispatchCandidates.order(issues, DispatchPolicy.terminal_state_set())
    assert Enum.map(Enum.take(ordered, 6), & &1.id) == ~w(3 8 4 9 10 5)
    assert Enum.sort(Map.keys(dispatch(issues).running)) == ~w(10 3 4 5 8 9)
  end

  test "unlimited ranked spill admits later sets despite unknown earlier readiness" do
    {document, issues, projections} = fixture()
    projections = Enum.map(projections, &if(&1.issue_id in ~w(1 2), do: %{&1 | state: :unknown}, else: &1))
    publish(document, projections)
    final = dispatch(Enum.drop(issues, 2))
    assert Enum.sort(Map.keys(final.running)) == ~w(3 4 5 6 7 8)
    assert Slots.available_slots(final) == 0
  end

  test "members of a missing set use ordinary ordering without crashing dispatch" do
    {document, issues, projections} = fixture()
    publish(document, projections)
    snapshot = Hints.sets()
    Hints.publish_sets(%{snapshot | sets: Enum.reject(snapshot.sets, &(&1.rank == 0))})
    assert QueueSetSlots.sort_key("1", QueueSetSlots.ordering()) == {1, 0, 0}
    assert Enum.sort(Map.keys(dispatch(issues).running)) == ~w(3 4 5 6 7 8)
  end

  test "review waits keep a started unfinished set active after all its runners exit" do
    configure(max_active_sets: 1)
    {document, issues, projections} = fixture()
    projections = Enum.map(projections, &if(&1.issue_id in ~w(1 2), do: %{&1 | state: :claimed}, else: &1))
    publish(document, projections)
    final = dispatch(Enum.drop(issues, 2))
    assert final.running == %{}
    assert Slots.available_slots(final) == 6
    assert {:declined, {:queue_set_order, reason}} = BuildQueueClaimProbe.classify(final, "3")
    assert reason =~ "max_active_sets 1"
  end

  test "one reserved slot remains free while earliest set is in review" do
    configure(spill_reserve_slots: 1)
    {document, issues, projections} = fixture()
    projections = Enum.map(projections, &if(&1.issue_id in ~w(1 2), do: %{&1 | state: :claimed}, else: &1))
    publish(document, projections)
    final = dispatch(Enum.drop(issues, 2))
    assert Enum.sort(Map.keys(final.running)) == ~w(3 4 5 6 7)
    assert Slots.available_slots(final) == 1
    assert final.dispatch_declines["8"] == :queue_set_order
    assert {:declined, {:queue_set_order, reason}} = BuildQueueClaimProbe.classify(final, "8")
    assert reason =~ "spill reserve 1 slots"
  end

  test "unknown earlier readiness blocks limited spill and says it may have ready work" do
    configure(max_active_sets: 1)
    {document, issues, projections} = fixture()
    projections = Enum.map(projections, &if(&1.issue_id == "1", do: %{&1 | state: :unknown}, else: &1))
    publish(document, projections)
    final = dispatch(Enum.drop(issues, 2))
    assert final.running == %{}
    assert Slots.available_slots(final) == 6
    assert {:declined, {:queue_set_order, reason}} = BuildQueueClaimProbe.classify(final, "3")
    assert reason =~ "readiness unknown; may have ready work"
  end

  test "aged observations block spill and held sets neither block spill nor consume the cap" do
    configure(max_active_sets: 1)
    {document, issues, projections} = fixture()
    old = System.system_time(:millisecond) - 1_000_000
    observations = Map.new(issues, &{&1.id, %{observed_at_ms: if(&1.id in ~w(1 2), do: old, else: System.system_time(:millisecond))}})
    Reconcile.write_hints(projections, MapSet.new(), document, Config.settings!(), observations)
    assert dispatch(Enum.drop(issues, 2)).running == %{}
    held = %{document | queues: Enum.map(document.queues, &if(&1.rank == 0, do: %{&1 | held: true}, else: &1))}
    projections = Enum.map(projections, &if(&1.issue_id in ~w(1 2), do: %{&1 | state: :claimed}, else: &1))
    publish(held, projections)
    final = dispatch(issues)
    assert Enum.sort(Map.keys(final.running)) == ~w(3 4 5 6 7)
    assert Slots.available_slots(final) == 1
  end

  defp configure(opts \\ []) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "agent", max_concurrent_agents: 6)
    config = %{set_order: "ranked", max_active_sets: nil, spill_reserve_slots: 0} |> Map.merge(Map.new(opts))
    File.write!(path, File.read!(path) <> "\nbuild_queue:\n" <> Enum.map_join(config, "", fn {key, value} -> "  #{key}: #{if is_nil(value), do: "null", else: value}\n" end))
    Aiur.WorkflowStore.force_reload()
    assert {:ok, _} = Workflow.current()
  end

  defp fixture do
    now = DateTime.utc_now()
    queues = for rank <- 0..2, do: %Model.Queue{id: "q-000#{rank}", name: "set #{rank}", rank: rank, kind: :list, root: nil, held: false, generation: 0, created_at: now}
    groups = [Enum.to_list(1..2), Enum.to_list(3..7), Enum.to_list(8..12)]

    items =
      for {group, rank} <- Enum.with_index(groups),
          {number, position} <- Enum.with_index(group),
          do: %Model.Item{issue_id: to_string(number), queue_id: "q-000#{rank}", position: position, hold: nil, override: nil, promoted_at: now, added_at: now}

    issues = for n <- 1..12, do: %Issue{id: to_string(n), identifier: "repo##{n}", title: "ticket #{n}", state: "todo", priority: if(n <= 2, do: 4, else: 1), blocked_by: []}
    projections = for item <- items, do: %{issue_id: item.issue_id, state: :promoted, verdict: :ready, reason: nil, rank: {0, 1, item.position, 0, item.issue_id}}
    {%{queues: queues, items: items, edges: [], intents: [], latches: []}, issues, projections}
  end

  defp publish(document, projections), do: Reconcile.write_hints(projections, MapSet.new(), document)

  defp dispatch(issues) do
    state = %State{snapshot_key: self(), max_concurrent_agents: 6, effective_concurrent_agents: 6, last_polled_issues: Map.new(issues, &{&1.id, &1})}

    pending =
      Dispatcher.choose_issues(state, issues,
        issue_fetcher: fn [id] -> {:ok, [Enum.find(issues, &(&1.id == id))]} end,
        blocked_by_hydrator: fn issue -> {:ok, issue} end,
        runner: fn _, _, _ -> :ok end
      )

    drain(pending)
  end

  defp drain(state) do
    case Map.keys(state.tracker_tasks) do
      [] ->
        state

      [ref] ->
        receive_barrier({^ref, result})
        {:handled, next} = TrackerTasks.result(state, ref, result)
        drain(next)
    end
  end
end
