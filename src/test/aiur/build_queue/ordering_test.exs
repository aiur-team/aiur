defmodule Aiur.BuildQueue.OrderingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.BuildQueue.Model.{Edge, Item}
  alias Aiur.BuildQueue.Ordering

  test "counts transitive dependents once across edge sources and includes isolated open items" do
    edges = [edge("1", "2"), edge("2", "3"), edge("1", "4"), edge("4", "3"), edge("1", "2", :native)]
    assert Ordering.downstream_open(edges, ~w(1 2 3 4 5)) == %{"1" => 3, "2" => 1, "3" => 0, "4" => 1, "5" => 0}
  end

  test "filters closed and removed members while walking through them" do
    edges = [edge("1", "2"), edge("2", "3"), edge("1", "4")]
    assert Ordering.downstream_open(edges, MapSet.new(~w(1 3))) == %{"1" => 1, "2" => 1, "3" => 0, "4" => 0}
  end

  test "cycles and self edges terminate and never count the starting node" do
    edges = [edge("1", "2"), edge("2", "1"), edge("1", "1"), edge("2", "3")]
    assert Ordering.downstream_open(edges, ~w(1 2 3)) == %{"1" => 2, "2" => 2, "3" => 0}
  end

  test "rank orders downstream, priority, position, microsecond age and numeric issue number" do
    old = ~U[2026-10-07 00:00:00.000001Z]
    new = ~U[2026-10-07 00:00:00.000002Z]

    candidates = [
      {item("10", 2), 1, 2, new},
      {item("2", 2), 1, 2, new},
      {item("3", 2), 1, 2, old},
      {item("4", 1), 1, 2, new},
      {item("5", 9), 1, 1, new},
      {item("6", 9), 2, 5, new}
    ]

    sorted = Enum.sort_by(candidates, fn {item, count, priority, time} -> Ordering.rank(item, count, priority, time) end)
    assert Enum.map(sorted, fn {item, _, _, _} -> item.issue_id end) == ~w(6 5 4 3 2 10)
  end

  test "build-order nil positions use zero and missing creation times sort last" do
    old = ~U[2026-10-07 00:00:00Z]
    assert Ordering.hint(item("12", nil), 3) == {-3, 0}
    assert Ordering.rank(item("12", nil), 3, 5, old) == {-3, 5, 0, DateTime.to_unix(old, :microsecond), 12}
    assert Ordering.rank(item("12", nil), 3, 5, nil) > Ordering.rank(item("12", nil), 3, 5, old)
  end

  property "hint supplies the first and third rank elements" do
    check all(count <- integer(0..100), position <- one_of([constant(nil), integer(0..100)]), priority <- integer(1..5)) do
      item = item("12", position)
      rank = Ordering.rank(item, count, priority, ~U[2026-10-07 00:00:00Z])
      assert Ordering.hint(item, count) == {-count, position || 0}
      assert Ordering.hint(item, count) == {elem(rank, 0), elem(rank, 2)}
    end
  end

  defp edge(from, to, source \\ :list), do: %Edge{prerequisite: from, dependent: to, source: source}

  defp item(id, position) do
    %Item{issue_id: id, queue_id: "q-ab12", position: position, hold: nil, override: nil, promoted_at: nil, added_at: ~U[2026-10-07 00:00:00Z]}
  end
end
