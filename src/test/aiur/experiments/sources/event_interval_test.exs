defmodule Aiur.Experiments.Sources.EventIntervalTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Metric, Sources.EventInterval}

  @window %{start: ~U[2026-01-01 10:00:00Z], end: ~U[2026-01-01 13:00:00Z]}
  @metric %Metric{requires: [], source: %{"start" => "executor.app.deploy.started", "end" => "executor.app.deploy.finished"}}

  test "first start and first following end produce milliseconds; unmatched ends do not" do
    events = [
      event("a", "started", "2026-01-01T10:00:00Z"),
      event("a", "started", "2026-01-01T10:01:00Z"),
      event("a", "finished", "2026-01-01T10:05:00Z"),
      event("a", "finished", "2026-01-01T10:10:00Z"),
      event("b", "finished", "2026-01-01T10:20:00Z"),
      event("a", "finished", "2026-01-01T09:59:00Z")
    ]

    result = EventInterval.observations(@metric, "app/deploy_latency", @window, %{events: events, capture_started_at: @window.start})
    assert result.coverage.state == :captured
    assert [%{unit_id: "a", value: 300_000, at: ~U[2026-01-01 10:05:00Z]}] = result.observations
  end

  test "missing finish attributes preserve known values from the start" do
    events = [Map.put(event("a", "started", "2026-01-01T10:00:00Z"), "attrs", %{"branch" => "main"}), Map.put(event("a", "finished", "2026-01-01T10:05:00Z"), "attrs", %{"branch" => nil})]
    result = EventInterval.observations(@metric, "app/deploy_latency", @window, %{events: events, capture_started_at: @window.start})
    assert [%{attrs: %{"branch" => "main"}}] = result.observations
  end

  test "capture start classifies partial and missing registration is not captured" do
    at = ~U[2026-01-01 11:00:00Z]

    assert %{coverage: %{state: :partial, covered_from: ^at}, observations: []} =
             EventInterval.observations(@metric, "app/deploy_latency", @window, %{events: [], capture_started_at: at})

    assert %{coverage: %{state: :not_captured}, observations: []} =
             EventInterval.observations(@metric, "app/deploy_latency", @window, %{events: [], capture_started_at: nil})
  end

  defp event(unit, phase, at), do: %{"metric_ref" => "app/deploy_latency", "topic" => "executor.app.deploy.#{phase}", "unit" => unit, "at" => at, "attrs" => %{}}
end
