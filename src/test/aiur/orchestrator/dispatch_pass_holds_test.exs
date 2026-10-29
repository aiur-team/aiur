defmodule Aiur.Orchestrator.DispatchPassHoldsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{BoundedBlockedBy, BudgetBroker, CycleFetchCache, OpenIssueSnapshot, ResourceStore, Tracker}
  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchCandidates, Dispatcher, DispatchPolicy, State, TrackerTasks}

  @slots 12

  setup do
    test_pid = self()
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "sym", max_concurrent_agents: @slots)
    ResourceStore.reset()
    OpenIssueSnapshot.reset()
    on_exit(fn -> Aiur.TestSupport.stop_test_runners(test_pid) end)
    on_exit(fn -> File.write!(path, original) end)
    :ok
  end

  test "a pass over 200 cached holds validates none of them and starts every ready ticket, with slots to spare" do
    parent = self()
    held = Enum.map(1..200, &candidate(&1, 1))
    ready = Enum.map(201..208, &candidate(&1, 2))
    ready_ids = Enum.map(ready, & &1.id)
    cache_holds(held)

    pending =
      Dispatcher.choose_issues(%State{snapshot_key: self(), max_concurrent_agents: @slots, effective_concurrent_agents: @slots}, held ++ ready,
        issue_fetcher: fn [id] -> {:ok, [Enum.find(ready, &(&1.id == id))]} end,
        blocked_by_hydrator: fn issue ->
          send(parent, {:hydrated, issue.id})
          {:ok, issue}
        end,
        runner: fn _issue, _, _ -> :ok end
      )

    # Every hold is declined before the first validation task is awaited.
    assert pending.dispatch_declines == Map.new(held, &{&1.id, :dependency})
    assert Map.keys(pending.tracker_tasks) |> length() == 1

    final = Enum.reduce(ready, pending, fn _, state -> apply_result(state) end)

    assert Map.keys(final.running) |> Enum.sort() == ready_ids
    assert final.tracker_tasks == %{}
    assert final.dispatch_declines == Map.new(held, &{&1.id, :dependency})

    hydrated = collect_hydrated([])
    assert Enum.uniq(hydrated) |> Enum.sort() == ready_ids
  end

  test "a paused fleet leaves a cached hold's recorded decline untouched, as the paused chain does" do
    [%Issue{id: id}] = held = [candidate(1, 1)]
    cache_holds(held)
    recorded = %{id => :tracker_revalidation_failed}

    paused =
      Dispatcher.choose_issues(%State{snapshot_key: self(), globally_paused: true, dispatch_declines: recorded, max_concurrent_agents: @slots, effective_concurrent_agents: @slots}, held, [])

    assert paused.dispatch_declines == recorded
  end

  test "a blocker closing in the store moves its dependent from held to the chain on the next pass" do
    [dependent] = held = [candidate(1, 1)]
    cache_holds(held)
    assert {[], [%Issue{id: id, blocked_by: [%{identifier: "100", state: "todo"}]}]} = partition(held)
    assert id == dependent.id

    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "100"), %{"number" => 100, "state" => "closed", "labels" => []})
    assert partition(held) == {[dependent], []}
  end

  test "evidence too old to decide on orders its ticket after the others without holding it" do
    stale = candidate(1, 1)
    ready = candidate(2, 2)
    cache_holds([stale])
    age(ResourceStore.key(:issue_blocked_by, "owner", "repo", stale.id))

    assert BoundedBlockedBy.fetch(stale.id, cache_only: true) == {:error, :cache_miss}
    assert partition([ready, stale]) == {[ready, stale], []}
  end

  test "last-known evidence is never served to the dispatch gate's own read" do
    stale = candidate(1, 1)
    cache_holds([stale])
    age(ResourceStore.key(:issue_blocked_by, "owner", "repo", stale.id))
    CycleFetchCache.start_cycle()

    assert {:ok, %Issue{blocked_by: [%{identifier: "100"}]}} = Tracker.last_known_blocked_by(stale)
    assert Tracker.cached_blocked_by(stale) == {:error, :cache_miss}
    CycleFetchCache.end_cycle()
  end

  test "a broker timeout still dispatches with fresh cached dependency evidence" do
    [ready] = tickets = [candidate(1, 1)]
    ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", ready.id), [])
    root = Aiur.TestSupport.tmp_root!("dispatch-broker-stall")
    File.mkdir_p!(root)
    broker = Path.join(root, "stalling-broker.py")

    File.write!(broker, """
    import json, os, sys, time
    request = json.loads(sys.stdin.readline())
    time.sleep(1)
    try:
        print(json.dumps({"id": request["id"], "output": "late", "status": 0}), flush=True)
    except BrokenPipeError:
        sys.stdout = open(os.devnull, "w")
    for line in sys.stdin:
        pass
    """)

    server = start_supervised!({BudgetBroker, name: :dispatch_stall_broker})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    pending =
      Dispatcher.choose_issues(%State{snapshot_key: self(), max_concurrent_agents: 1, effective_concurrent_agents: 1}, tickets,
        issue_fetcher: fn [_id] ->
          assert :timeout = BudgetBroker.command(server, broker, [], System.monotonic_time(:millisecond) + 100)
          {:error, {:github, :local_hold, %{reason: :github_budget_broker_timeout}}}
        end,
        runner: fn _issue, _, _ -> :ok end
      )

    final = apply_result(pending)
    assert Map.has_key?(final.running, ready.id)
    refute Map.has_key?(final.dispatch_declines, ready.id)
  end

  test "a broker timeout with stale dependency cache remains fail-closed" do
    [candidate_issue] = tickets = [candidate(1, 1)]
    cache_holds(tickets)
    age(ResourceStore.key(:issue_blocked_by, "owner", "repo", candidate_issue.id))

    pending =
      Dispatcher.choose_issues(%State{snapshot_key: self(), max_concurrent_agents: 1, effective_concurrent_agents: 1}, tickets,
        issue_fetcher: fn [_id] -> {:error, :github_budget_broker_timeout} end,
        blocked_by_hydrator: fn _issue -> {:error, :cache_miss} end,
        runner: fn _issue, _, _ -> :ok end
      )

    final = apply_result(pending)
    refute Map.has_key?(final.running, candidate_issue.id)
    assert final.dispatch_declines[candidate_issue.id] == :tracker_revalidation_failed
  end

  defp partition(issues), do: DispatchCandidates.partition(issues, DispatchPolicy.terminal_state_set())

  defp age(key) do
    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
    :ets.insert(ResourceStore.Table, {key, %{entry | fetched_at_ms: System.system_time(:millisecond) - BoundedBlockedBy.max_age_ms() - 1_000}})
  end

  defp cache_holds(issues) do
    blocker = %{"number" => 100, "state" => "open", "labels" => [%{"name" => "sym:todo"}]}
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "100"), blocker)
    for issue <- issues, do: ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", issue.id), [blocker])
  end

  defp candidate(number, priority), do: %Issue{id: to_string(4_174_000 + number), identifier: "repo##{4_174_000 + number}", title: "ticket #{number}", state: "todo", priority: priority}

  defp collect_hydrated(acc) do
    receive do
      {:hydrated, id} -> collect_hydrated([id | acc])
    after
      0 -> acc
    end
  end

  defp apply_result(state) do
    [ref] = Map.keys(state.tracker_tasks)
    receive_barrier({^ref, result})
    {:handled, next} = TrackerTasks.result(state, ref, result)
    next
  end
end
