defmodule Aiur.Orchestrator.DispatchCandidatesTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.{Hints, Model, Sets}
  alias Aiur.GitHub.{BoundedBlockedBy, OpenIssueSnapshot, ResourceStore}
  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchCandidates, Dispatcher, DispatchPolicy, State, TrackerTasks}

  setup do
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "sym", max_concurrent_agents: 3)
    ResourceStore.reset()
    OpenIssueSnapshot.reset()
    on_exit(fn -> File.write!(path, original) end)
    :ok
  end

  test "three eligible tickets dispatch before validating any of sixty cached dependency holds" do
    parent = self()
    held = Enum.map(1..60, &candidate(&1, 1))
    ready = [candidate(63, 4), candidate(61, 2), candidate(62, 3)]
    cache_holds(held)

    pending =
      Dispatcher.choose_issues(%State{snapshot_key: self(), max_concurrent_agents: 3, effective_concurrent_agents: 3}, held ++ ready,
        issue_fetcher: fn [id] ->
          send(parent, {:validated, id})
          {:ok, [Enum.find(ready, &(&1.id == id))]}
        end,
        blocked_by_hydrator: fn issue ->
          send(parent, {:hydrated, issue.id})
          assert issue.id in ["3691061", "3691062", "3691063"]
          {:ok, issue}
        end,
        runner: fn issue, _, _ ->
          send(parent, {:started, issue.id})
          :ok
        end
      )

    assert TrackerTasks.running?(pending, {:dispatch, "3691061"})
    final = Enum.reduce(1..3, pending, fn _, state -> apply_result(state) end)
    assert Map.keys(final.running) |> Enum.sort() == ["3691061", "3691062", "3691063"]
    assert final.tracker_tasks == %{}

    assert Enum.map(1..3, fn _ ->
             receive_barrier({:validated, id})
             id
           end) == ["3691061", "3691062", "3691063"]

    for id <- ["3691061", "3691062", "3691063"], do: receive_barrier({:started, ^id})
    refute_received {:validated, _}

    for id <- ["3691061", "3691062", "3691063"] do
      assert_received {:hydrated, ^id}
      assert_received {:hydrated, ^id}
    end

    refute_received {:hydrated, _}
  end

  test "missing or stale evidence keeps priority order and performs no HTTP reads" do
    held = candidate(1, 1)
    ready = candidate(2, 2)
    assert BoundedBlockedBy.fetch(held.id, cache_only: true, request_fun: fn _ -> flunk("cache misses must not fetch") end) == {:error, :cache_miss}
    assert order([ready, held]) == [held, ready]
    cache_holds([held])
    assert order([ready, held]) == [ready, held]

    key = ResourceStore.key(:issue_blocked_by, "owner", "repo", held.id)
    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
    :ets.insert(ResourceStore.Table, {key, %{entry | fetched_at_ms: 0}})
    assert order([ready, held]) == [held, ready]
  end

  test "future regression guard: ready p1 without a queue hint precedes p3 and unprioritized tickets" do
    p1 = candidate(701, 1)
    p3 = candidate(702, 3)
    unprioritized = candidate(703, nil)

    assert Enum.map(DispatchCandidates.order([p3, unprioritized, p1], DispatchPolicy.terminal_state_set()), & &1.id) ==
             [p1.id, p3.id, unprioritized.id]
  end

  test "ready features precede higher-priority maintenance while main-fix remains first" do
    configure_ordering()
    fixer = %{candidate(711, 4) | labels: ["main-fix"]}
    feature = %{candidate(712, 2) | labels: ["feature:dispatch"]}
    bug = %{candidate(713, 1) | labels: ["bug"]}
    flake = %{candidate(714, 3) | labels: ["flake"]}
    tooling = %{candidate(715, nil) | title: "Update tooling"}

    assert order([flake, tooling, bug, feature, fixer]) == [fixer, feature, bug, flake, tooling]
    assert order([tooling, flake, bug]) == [bug, flake, tooling]
  end

  test "queue membership precedes work kind, which precedes queue rank and position" do
    configure_ordering()
    fixer = %{candidate(721, 4) | labels: ["main-fix"]}
    maintenance = %{candidate(722, 1) | labels: ["bug"]}
    first_feature = %{candidate(723, 2) | labels: ["feature:dispatch"]}
    later_feature = %{candidate(724, 2) | labels: ["build-order"]}
    unqueued_feature = %{candidate(725, 1) | labels: ["build-lane:dispatch"]}
    publish_queue_sets([[maintenance, first_feature], [later_feature]])

    assert order([unqueued_feature, maintenance, later_feature, first_feature, fixer]) ==
             [fixer, first_feature, later_feature, maintenance, unqueued_feature]
  end

  test "a blocker closed in the current store stops lowering its dependent's priority" do
    held = candidate(1, 1)
    ready = candidate(2, 2)
    cache_holds([held])
    assert order([ready, held]) == [ready, held]
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "100"), %{"number" => 100, "state" => "closed", "labels" => []})
    assert order([ready, held]) == [held, ready]
  end

  defp order(issues) do
    {chain, held} = DispatchCandidates.partition(issues, DispatchPolicy.terminal_state_set())
    Enum.map(chain ++ held, & &1.id) |> Enum.map(fn id -> Enum.find(issues, &(&1.id == id)) end)
  end

  defp cache_holds(issues) do
    blocker = %{"number" => 100, "state" => "open", "labels" => [%{"name" => "sym:todo"}]}
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "100"), blocker)
    for issue <- issues, do: ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", issue.id), [blocker])
  end

  defp candidate(number, priority), do: %Issue{id: to_string(3_691_000 + number), identifier: "repo##{3_691_000 + number}", title: "ticket #{number}", state: "todo", priority: priority}

  defp configure_ordering do
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nmerge_policy:\n  main_watch:\n    on_red: dispatch_fixer\nbuild_queue:\n  set_order: ranked\n")
    :ok = Aiur.WorkflowStore.force_reload()
  end

  defp publish_queue_sets(groups) do
    now = DateTime.utc_now()

    queues =
      for {_group, rank} <- Enum.with_index(groups), do: %Model.Queue{id: "dispatch-#{rank}", name: "set #{rank}", rank: rank, kind: :list, root: nil, held: false, generation: 0, created_at: now}

    items =
      for {group, rank} <- Enum.with_index(groups),
          {issue, position} <- Enum.with_index(group),
          do: %Model.Item{issue_id: issue.id, queue_id: "dispatch-#{rank}", position: position, hold: nil, override: nil, promoted_at: now, added_at: now}

    projections = for item <- items, do: %{issue_id: item.issue_id, state: :promoted}
    Hints.publish_sets(Sets.snapshot(%{queues: queues, items: items}, projections, Config.settings!(), nil))
  end

  defp apply_result(state) do
    [ref] = Map.keys(state.tracker_tasks)
    receive_barrier({^ref, result})
    {:handled, next} = TrackerTasks.result(state, ref, result)
    next
  end
end
