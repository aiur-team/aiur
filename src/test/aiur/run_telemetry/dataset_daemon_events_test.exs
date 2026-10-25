defmodule Aiur.RunTelemetry.DatasetDaemonEventsTest do
  use ExUnit.Case, async: true
  alias Aiur.RunTelemetry.Dataset

  @fixture Path.expand("../../../../analytics/tests/fixtures/daemon-events/telemetry.ndjson", __DIR__)

  # Mirrors analytics/tests/test_reduce.py (same fixture, same expectations).
  test "shared fixture keeps every daemon-side event field and the binding kind" do
    assert {:ok, dataset} = Dataset.build(@fixture)
    events = Map.new(dataset.tickets["42"].events, &{&1.event, &1})

    assert %{from_state: "in-progress", to_state: "ci-wait", cause: "observed"} = events["state_change"]
    assert %{outcome: "failed", pr_number: 77, head_sha: "0123456789ab"} = events["ci_result"]
    assert %{pr_number: 77} = events["pr_ready"]
    assert %{blocker: "11", cause: "terminal"} = events["dependency_cleared"]

    assert %{input_tokens: 120_000, output_tokens: 30_000, cached_tokens: 5, cost_amount: "1.50", cost_currency: "USD", coverage: "complete"} =
             events["ticket_usage"]

    sample = hd(dataset.actors["_daemon"].samples)
    assert sample.fleet_binding_kind == "config_cap"
  end
end
