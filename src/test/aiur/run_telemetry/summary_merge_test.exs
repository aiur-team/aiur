defmodule Aiur.RunTelemetry.SummaryMergeTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.{Summaries, SummaryMerge}

  @fixture Path.expand("../../fixtures/analytics/runs/boot-a/run-summary.json", __DIR__)

  test "full-log merge preserves original CPU totals and peaks despite chart sampling" do
    {:ok, dataset} = @fixture |> File.read!() |> Summaries.decode_summary()
    key = dataset.actors |> Map.keys() |> Enum.find(&String.starts_with?(&1, "ticket:"))
    actor = dataset.actors[key]
    stats = %{count: 10_000, mean: 20.0, min: 0.0, max: 150.0, median: 10, p95: 90}
    dataset = put_in(dataset, [:actors, key], %{actor | samples: Enum.take(actor.samples, 1), profile: %{"cpu_percent" => stats}})

    merged = SummaryMerge.merge([dataset])
    assert merged.actors[key].profile["cpu_percent"].count == 10_000
    assert merged.actors[key].profile["cpu_percent"].mean == 20.0
    assert merged.actors[key].profile["cpu_percent"].max == 150.0
    assert Map.keys(merged.tickets) == Map.keys(dataset.tickets)

    assert Enum.map(merged.tickets["930"].intervals, &{&1.phase, &1.start_ms, &1.end_ms}) ==
             Enum.map(dataset.tickets["930"].intervals, &{&1.phase, &1.start_ms, &1.end_ms})
  end
end
