defmodule Aiur.BuildQueue.CriticalRankTest do
  use Aiur.TestSupport
  alias Aiur.BuildQueue.{Hints, Ordering, Reconcile}
  alias Aiur.BuildQueue.Model.Edge

  test "critical ranks distinguish chains, fanout, diamonds, closed nodes and cycles" do
    edges = for {a, b} <- [{"1", "2"}, {"2", "3"}, {"1", "4"}, {"4", "3"}, {"1", "5"}], do: %Edge{prerequisite: a, dependent: b, source: :native}
    assert Ordering.critical_ranks(edges, ~w(1 2 3 4 5)) == %{"1" => {2, 4}, "2" => {1, 1}, "3" => {0, 0}, "4" => {1, 1}, "5" => {0, 0}}
    assert Ordering.critical_ranks(edges, ~w(1 3)) == %{"1" => {0, 1}, "2" => {1, 1}, "3" => {0, 0}, "4" => {1, 1}, "5" => {0, 0}}
    cycle = [%Edge{prerequisite: "1", dependent: "2", source: :native}, %Edge{prerequisite: "2", dependent: "1", source: :native}]
    assert Ordering.critical_ranks(cycle, ~w(1 2)) == %{"1" => {1, 1}, "2" => {1, 1}}
  end

  test "reconciliation publishes queue depth while old hints retain zero depth" do
    :ets.new(Hints.table_name(), [:named_table, :set])
    ids = ~w(1 2 3)

    document = %{
      queues: [%{id: "q", held: false, start_trigger: :pr_opened}],
      items: Enum.map(ids, &%{issue_id: &1, queue_id: "q", hold: nil}),
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
