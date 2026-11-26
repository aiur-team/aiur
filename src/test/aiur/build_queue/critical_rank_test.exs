defmodule Aiur.BuildQueue.CriticalRankTest do
  use Aiur.TestSupport
  alias Aiur.BuildQueue.{Hints, Ordering, Reconcile}
  alias Aiur.BuildQueue.Model.Edge
  alias Aiur.Orchestrator.{DependencyGate, DispatchCandidates, DispatchPolicy}

  test "critical ranks distinguish chains, fanout, diamonds, closed nodes and cycles" do
    edges = for {a, b} <- [{"1", "2"}, {"2", "3"}, {"1", "4"}, {"4", "3"}, {"1", "5"}], do: %Edge{prerequisite: a, dependent: b, source: :native}
    assert Ordering.critical_ranks(edges, ~w(1 2 3 4 5)) == %{"1" => {2, 4}, "2" => {1, 1}, "3" => {0, 0}, "4" => {1, 1}, "5" => {0, 0}}
    assert Ordering.critical_ranks(edges, ~w(1 3)) == %{"1" => {0, 1}, "2" => {1, 1}, "3" => {0, 0}, "4" => {1, 1}, "5" => {0, 0}}
    cycle = [%Edge{prerequisite: "1", dependent: "2", source: :native}, %Edge{prerequisite: "2", dependent: "1", source: :native}]
    assert Ordering.critical_ranks(cycle, ~w(1 2)) == %{"1" => {1, 1}, "2" => {1, 1}}
  end

  test "ranked sets retain optimistic depth ahead of distinct list positions" do
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    on_exit(fn -> File.write!(path, original) end)
    File.write!(path, original <> "\nbuild_queue:\n  set_order: ranked\n  start_trigger: pr_opened\n")
    Aiur.WorkflowStore.force_reload()
    :ets.new(Hints.table_name(), [:named_table, :set])
    now = System.system_time(:millisecond)
    set = %{id: "q", rank: 0, unfinished: true, held: false, active: false, unknown: false, observed_at_ms: now}
    Hints.publish_sets(%{sets: [set], members: %{"shallow" => %{set_id: "q", position: 0}, "deep" => %{set_id: "q", position: 1}}, max_age_ms: 60_000})
    :ets.insert(Hints.table_name(), [{"shallow", {0, 0}, false, :pr_opened, 0}, {"deep", {-2, 1}, false, :pr_opened, 2}])

    issues =
      for id <- ~w(shallow deep),
          do: %Issue{
            id: id,
            identifier: id,
            title: id,
            state: "todo",
            blocked_by: [%{id: "blocker", state: "ci-wait"}]
          }

    assert Enum.all?(issues, &(DependencyGate.classify(&1, DispatchPolicy.terminal_state_set()) == :optimistic))
    assert Enum.map(DispatchCandidates.order(issues, DispatchPolicy.terminal_state_set()), & &1.id) == ~w(deep shallow)
  end

  test "reconciliation publishes queue depth while old hints retain zero depth" do
    :ets.new(Hints.table_name(), [:named_table, :set])
    ids = ~w(1 2 3)

    document = %{
      queues: [%{id: "q", rank: 0, held: false, start_trigger: :pr_opened}],
      items: for({id, position} <- Enum.with_index(Enum.reverse(ids)), do: %{issue_id: id, queue_id: "q", position: position, hold: nil}),
      edges: [%Edge{prerequisite: "1", dependent: "2", source: :native}, %Edge{prerequisite: "2", dependent: "3", source: :native}]
    }

    projections = Enum.map(ids, &%{issue_id: &1, state: :waiting, rank: {-2, 0, 3, 0, &1}})
    Reconcile.write_hints(projections, MapSet.new(), document)
    assert Hints.critical_rank("1") == {2, 2}
    assert Hints.critical_rank("2") == {1, 2}
    assert Hints.trigger_for("1") == :pr_opened
    assert Hints.sort_key("1") == {-2, 3}
    refute Hints.held?("1")
    :ets.insert(Hints.table_name(), {"old", {-3, 2}, false, :pr_merged})
    assert Hints.critical_rank("old") == {0, 3}
    assert Hints.critical_rank("missing") == nil
  end
end
