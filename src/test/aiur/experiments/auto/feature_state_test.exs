defmodule Aiur.Experiments.Auto.FeatureStateTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema.Experiments.Auto, as: Config
  alias Aiur.Experiments.Auto.FeatureState
  @now ~U[2026-10-10 00:00:00Z]
  defp member(n, state \\ "open"), do: %{"number" => n, "state" => state, "state_reason" => nil}
  defp observe(members, extra \\ %{}), do: Map.merge(%{"labelled" => true, "members" => members, "merges" => []}, extra)

  test "arming and first merge freeze once each, and new membership resets quiet time" do
    config = %Config{}
    observation = observe([member(1), member(2)])
    {armed, [:arm]} = FeatureState.transition(nil, observation, config, @now)
    assert armed["phase"] == "armed"
    assert armed["before_end"] == "2026-10-10T00:00:00Z"
    assert {^armed, []} = FeatureState.transition(armed, observation, config, @now)
    merge = %{"number" => 1, "at" => "2026-10-13T00:00:00Z", "sha" => "a"}
    observation = observe([member(1, "closed"), member(2)], %{"merges" => [merge]})
    {merging, [:freeze]} = FeatureState.transition(armed, observation, config, ~U[2026-10-13 00:00:00Z])
    assert merging["before_end"] == merge["at"]
    assert {^merging, []} = FeatureState.transition(merging, observation, config, ~U[2026-10-13 01:00:00Z])
    closed = put_in(observation, ["members"], [member(1, "closed"), member(2, "closed")])
    {settling, []} = FeatureState.transition(merging, closed, config, ~U[2026-10-13 02:00:00Z])
    {waiting, []} = FeatureState.transition(settling, closed, config, ~U[2026-10-13 07:00:00Z])
    assert waiting["phase"] == "merging"
    expanded = put_in(closed, ["members"], [member(1, "closed"), member(2, "closed"), member(3, "closed")])
    {reset, []} = FeatureState.transition(waiting, expanded, config, ~U[2026-10-13 07:00:00Z])
    {still, []} = FeatureState.transition(reset, expanded, config, ~U[2026-10-13 12:00:00Z])
    assert still["phase"] == "merging"
    {ready, [:resolve_live]} = FeatureState.transition(still, expanded, config, ~U[2026-10-13 13:00:00Z])
    assert ready["phase"] == "awaiting_live"
  end

  test "leaf issues never arm and late tagging records partial baseline coverage" do
    assert {%{"phase" => "not_an_epic"}, []} = FeatureState.transition(nil, observe([]), %Config{}, @now)
    merge = %{"number" => 1, "at" => "2026-10-09T00:00:00Z", "sha" => "a"}
    {state, [:arm]} = FeatureState.transition(nil, observe([member(1, "closed")], %{"merges" => [merge]}), %Config{}, @now)
    assert state["baseline_coverage"] == "partial"
    assert state["before_end"] == merge["at"]
  end

  test "cancellation latches on removal or all excluded, while a line stays fixed" do
    observation = observe([member(1)])
    {armed, [:arm]} = FeatureState.transition(nil, observation, %Config{}, @now)
    removed = Map.put(observation, "labelled", false)
    {cancelled, [:cancel]} = FeatureState.transition(armed, removed, %Config{}, @now)
    assert cancelled["phase"] == "cancelled"
    assert {^cancelled, []} = FeatureState.transition(cancelled, removed, %Config{}, @now)
    excluded = observe([%{member(1, "closed") | "state_reason" => "not_planned"}])
    assert {%{"phase" => "cancelled"}, [:cancel]} = FeatureState.transition(armed, excluded, %Config{}, @now)
    lined = Map.put(armed, "phase", "line_set")
    assert {^lined, []} = FeatureState.transition(lined, removed, %Config{}, @now)
  end
end
