Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.OptimisticPlannerTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.Model.Latch
  alias Aiur.BuildQueue.{Planner, PlannerFixture}

  test "optimistic claimed starts suppress new and retained dependency-change attentions" do
    input = PlannerFixture.input() |> PlannerFixture.waiting() |> PlannerFixture.promoted()
    input = %{input | claims: %{"1" => :claimed}}
    assert {[%{state: :claimed}], [{:attention_open, {:dependency_changed_after_start, "1"}}]} = Planner.plan(input)
    optimistic = %{input | opts: Keyword.put(input.opts, :optimistic_dependents, MapSet.new(["1"]))}
    assert {[%{state: :claimed}], []} = Planner.plan(optimistic)
    existing = %Latch{key: {:dependency_changed_after_start, "1"}, opened_at_ms: 9_000, emitted?: true}
    assert {[%{state: :claimed}], [{:attention_resolve, {:dependency_changed_after_start, "1"}}]} = Planner.plan(%{optimistic | latches: [existing]})
  end

  test "future regression: planner leaves guard-owned latches alone" do
    input = PlannerFixture.input()
    guard = %Latch{key: {:optimistic_blocker_failed, "1"}, opened_at_ms: 9_000, emitted?: true}
    assert {[%{state: :ready}], [{:promote, "1"}]} = Planner.plan(%{input | latches: [guard]})
  end
end
