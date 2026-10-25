defmodule Aiur.Experiments.Sources.EventCountTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Metric, Sources.EventCount}

  @window %{start: ~U[2026-01-01 10:00:00Z], end: ~U[2026-01-01 13:00:00Z]}
  @metric %Metric{requires: [], source: %{"match" => "executor.app.request.*", "per" => "hour"}}

  test "captured hours include empty buckets; partial windows never invent zero buckets" do
    events = Enum.map(["2026-01-01T10:20:00Z", "2026-01-01T12:20:00Z"], &%{"metric_ref" => "app/requests", "topic" => "executor.app.request.finished", "unit" => "r1", "at" => &1, "attrs" => %{}})
    ctx = %{events: events, capture_started_at: @window.start}
    result = EventCount.observations(@metric, "app/requests", @window, ctx)
    assert result.coverage.state == :captured
    assert Enum.map(result.observations, & &1.value) == [1, 0, 1]
    assert Enum.map(result.observations, & &1.at) == [~U[2026-01-01 10:00:00Z], ~U[2026-01-01 11:00:00Z], ~U[2026-01-01 12:00:00Z]]
    partial = EventCount.observations(@metric, "app/requests", @window, %{ctx | capture_started_at: ~U[2026-01-01 10:01:00Z]})
    assert partial.coverage.state == :partial
    assert Enum.map(partial.observations, & &1.value) == [1, 1]
  end

  test "captured empty hours are zero, uncaptured hours have no observations" do
    captured = EventCount.observations(@metric, "app/requests", @window, %{events: [], capture_started_at: @window.start})
    assert captured.coverage.state == :captured
    assert Enum.map(captured.observations, & &1.value) == [0, 0, 0]
    missing = EventCount.observations(@metric, "app/requests", @window, %{events: [], capture_started_at: nil})
    assert missing.coverage.state == :not_captured
    assert missing.observations == []
  end

  test "missing required facts never get captured zero buckets" do
    result = EventCount.observations(%{@metric | requires: ["cohort"]}, "app/requests", @window, %{events: [], capture_started_at: @window.start})
    assert %{state: :not_captured, missing: ["cohort"]} = result.coverage
    assert result.observations == []
  end
end
