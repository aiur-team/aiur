defmodule Aiur.RunTelemetry.DatasetPrTimingTest do
  use ExUnit.Case, async: true
  alias Aiur.RunTelemetry.Dataset

  @fixture Path.expand("../../../../analytics/tests/fixtures/pr-timing", __DIR__)

  # Parity guard for the already-correct Elixir reducer; Python needed the fix.
  test "shared PR fixture preserves first-open and merge times" do
    events = @fixture |> Path.join("github-events.json") |> File.read!() |> Jason.decode!()
    assert {:ok, dataset} = Dataset.build(Path.join(@fixture, "telemetry.ndjson"), github_events: events)

    for {ticket, opened, merged} <- [
          {"live", "00:01:00", "00:04:00"},
          {"enriched", "00:01:00", "00:04:00"},
          {"reconciled", "00:02:00", "00:05:00"},
          {"fallback", "00:02:00", "00:05:00"},
          {"event-only", nil, "00:06:00"},
          {"open", "00:03:00", nil}
        ],
        {phase, time} <- [{"pr_opened", opened}, {"pr_merged", merged}] do
      actual = dataset.tickets[ticket].intervals |> Enum.filter(&(&1.phase == phase)) |> Enum.map(& &1.start_ms) |> Enum.min(fn -> nil end)
      expected = if time, do: DateTime.from_iso8601("2026-10-09T" <> time <> "Z") |> elem(1) |> DateTime.to_unix(:millisecond)
      assert actual == expected, "#{ticket} #{phase}"
    end
  end
end
