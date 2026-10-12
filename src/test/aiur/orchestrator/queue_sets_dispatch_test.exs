defmodule Aiur.Orchestrator.QueueSetsDispatchTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.{AgentControlCLI, Issue}
  alias Aiur.BuildQueue.{Hints, Model, Reconcile}
  alias Aiur.Orchestrator.{BuildQueueClaimProbe, DispatchCandidates, Dispatcher, DispatchPolicy, PauseResume, QueueSetSlots, Slots, State, StatusReport, TrackerTasks}

  setup do
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    configure()
    :ets.new(Hints.table_name(), [:named_table, :set])
    on_exit(fn -> File.write!(path, original) end)
    :ok
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
