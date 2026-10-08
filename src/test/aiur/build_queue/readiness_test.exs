defmodule Aiur.BuildQueue.ReadinessTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.Model.{Edge, Observation}
  alias Aiur.BuildQueue.Readiness
  @opts [now_ms: 10_000, max_age_ms: 1_000, label_prefix: "worker"]

  test "only completed closure satisfies a fresh prerequisite" do
    assert verdict(open?: false, state_reason: "completed") == :satisfied
    assert verdict(open?: false, state_reason: "not_planned") == {:failed, :not_planned}
    assert Readiness.edge_verdict(observation(open?: false, state_reason: "not_planned"), Keyword.put(@opts, :not_planned, :satisfy)) == :satisfied
    for reason <- ["duplicate", nil, "other"], do: assert(verdict(open?: false, state_reason: reason) == {:unknown, :closed_reason})
  end

  test "open prerequisites preserve failures and use the configured prefix" do
    assert verdict(labels: ["worker:error"]) == {:failed, :agent_error}
    assert verdict(labels: ["agent:error"]) == :pending
    assert verdict(pr: :closed_unmerged) == {:failed, :pr_closed_unmerged}
    assert verdict(labels: ["worker:error"], pr: :closed_unmerged) == {:failed, :agent_error}
    for pr <- [nil, :open, :merged], do: assert(verdict(pr: pr) == :pending)
  end

  test "missing, unknown, and stale evidence never clears a prerequisite" do
    assert Readiness.edge_verdict(nil, @opts) == {:unknown, :stale}
    assert verdict(open?: :unknown) == {:unknown, :stale}
    assert verdict(open?: false, state_reason: "completed", observed_at_ms: 8_999) == {:unknown, :stale}
    assert verdict(labels: ["worker:error"], observed_at_ms: 8_999) == {:unknown, :stale}
    assert verdict(open?: false, state_reason: "completed", observed_at_ms: 9_000) == :satisfied
  end

  test "cycle evidence overrides completed observations" do
    assert Readiness.edge_verdict(observation(open?: false, state_reason: "completed"), Keyword.put(@opts, :cyclic, true)) == {:unknown, :cyclic}
  end

  test "item precedence collects all causes from the winning class" do
    assert Readiness.item_verdict([]) == :ready
    assert Readiness.item_verdict([:satisfied, :satisfied]) == :ready
    assert Readiness.item_verdict([:satisfied, :pending]) == :waiting
    assert Readiness.item_verdict([{:failed, :agent_error}, :pending]) == {:failed, [:agent_error]}
    assert Readiness.item_verdict([{:failed, :agent_error}, {:failed, :not_planned}]) == {:failed, [:agent_error, :not_planned]}
    assert Readiness.item_verdict([{:failed, :agent_error}, {:unknown, :stale}, {:unknown, :cyclic}, :pending]) == {:unknown, [:stale, :cyclic]}
  end

  test "ready requires every verdict to be satisfied for all combinations" do
    values = [:satisfied, :pending, {:failed, :agent_error}, {:unknown, :stale}]

    for a <- values, b <- values, c <- values do
      assert Readiness.item_verdict([a, b, c]) == :ready == Enum.all?([a, b, c], &(&1 == :satisfied))
    end
  end

  test "three-cycle and self-loop hold their members but exclude downstream tails" do
    edges = [edge("1", "2"), edge("2", "3"), edge("3", "1"), edge("3", "4"), edge("5", "5")]
    cyclic = Readiness.cyclic_items(edges)
    assert cyclic == MapSet.new(["1", "2", "3", "5"])

    for id <- ["1", "2", "3"] do
      opts = Keyword.put(@opts, :cyclic, MapSet.member?(cyclic, id))
      assert Readiness.item_verdict([Readiness.edge_verdict(observation([]), opts)]) == {:unknown, [:cyclic]}
    end

    assert Readiness.cyclic_items(Enum.reverse(edges) ++ edges) == cyclic
  end

  test "empty, disconnected, and diamond graphs have no cycles" do
    assert Readiness.cyclic_items([]) == MapSet.new()
    assert Readiness.cyclic_items([edge("1", "2"), edge("1", "3"), edge("2", "4"), edge("3", "4"), edge("5", "6")]) == MapSet.new()
  end

  test "the node bound accepts 1000 and refuses 1001 without pretending acyclic" do
    edges = for id <- 1..999, do: edge(to_string(id), to_string(id + 1))
    assert Readiness.cyclic_items(edges) == MapSet.new()
    assert Readiness.cyclic_items(edges ++ [edge("1000", "1")]) == MapSet.new(Enum.map(1..1000, &to_string/1))
    assert Readiness.cyclic_items(edges ++ [edge("1000", "1001")]) == {:unknown, :graph_too_large}
    assert Readiness.item_verdict([{:unknown, :graph_too_large}]) == {:unknown, [:graph_too_large]}
  end

  defp verdict(fields), do: Readiness.edge_verdict(observation(fields), @opts)
  defp observation(fields), do: struct!(Observation, Keyword.merge([issue_id: "1", open?: true, labels: [], state_reason: nil, pr: nil, observed_at_ms: 10_000], fields))
  defp edge(from, to), do: %Edge{prerequisite: from, dependent: to, source: :native}
end
