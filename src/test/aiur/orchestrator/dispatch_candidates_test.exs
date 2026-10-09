defmodule Aiur.Orchestrator.DispatchCandidatesTest do
  use Aiur.TestSupport

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

  test "a blocker closed in the current store stops lowering its dependent's priority" do
    held = candidate(1, 1)
    ready = candidate(2, 2)
    cache_holds([held])
    assert order([ready, held]) == [ready, held]
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "100"), %{"number" => 100, "state" => "closed", "labels" => []})
    assert order([ready, held]) == [held, ready]
  end

  defp order(issues), do: DispatchCandidates.order(issues, DispatchPolicy.terminal_state_set())

  defp cache_holds(issues) do
    blocker = %{"number" => 100, "state" => "open", "labels" => [%{"name" => "sym:todo"}]}
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "100"), blocker)
    for issue <- issues, do: ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", issue.id), [blocker])
  end

  defp candidate(number, priority), do: %Issue{id: to_string(3_691_000 + number), identifier: "repo##{3_691_000 + number}", title: "ticket #{number}", state: "todo", priority: priority}

  defp apply_result(state) do
    [ref] = Map.keys(state.tracker_tasks)
    receive_barrier({^ref, result})
    {:handled, next} = TrackerTasks.result(state, ref, result)
    next
  end
end
