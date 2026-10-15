defmodule AiurWeb.OperatorControlCenter.Analytics.OptimisticTest do
  use Aiur.TestSupport
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias Aiur.RunTelemetry.Dataset
  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Presenter}
  alias AiurWeb.OperatorControlCenter.BuildOrderAnalytics

  test "lifecycle reduction feeds optimistic totals and the discarded tile" do
    fixture = Path.expand("../../../../../analytics/tests/fixtures/optimistic/telemetry.ndjson", __DIR__)
    assert {:ok, dataset} = Dataset.build(fixture)
    model = Presenter.model(dataset, cap: 4, cores: 4, buckets: 4)
    assert model.kpis.optimistic == %{starts: 3, redone: 1, discarded: 1, head_start_ms: 15_000}
    html = render(model)
    assert html =~ ~r/an-kpi block.*?Optimistic starts.*?an-kpi-val">3</s
    assert html =~ "1 redone · 1 discarded · 0.0h head start"
  end

  # Compatibility guard: builds without optimistic events retain the existing KPI strip.
  test "the tile is absent without optimistic starts" do
    model = model([event("1", "dispatch", 0)])
    assert model.kpis.optimistic.starts == 0
    refute render(model) =~ "Optimistic starts"
  end

  test "unmeasured merged head start stays unknown in the model and tile" do
    model = model([event("1", "optimistic_start", 0), event("1", "optimistic_outcome", 1, %{outcome: "merged"})])
    assert model.kpis.optimistic.head_start_ms == nil
    assert render(model) =~ "unknown head start"
  end

  test "an open optimistic start reports unknown head start until a merged outcome exists" do
    model = model([event("1", "optimistic_start", 0)])
    assert model.kpis.optimistic == %{starts: 1, redone: 0, discarded: 0, head_start_ms: nil}
    assert render(model) =~ "unknown head start"
  end

  test "a parked member remains parked until its optimistic resume" do
    records = [event("1", "optimistic_start", 0), event("1", "optimistic_park", 1)]
    parked = model(records)
    assert [%{status: :optimistic_parked}] = parked.tickets
    assert Charts.gantt(parked) =~ "var(--faint)"
    assert [%{status: :active}] = model(records ++ [event("1", "optimistic_resume", 2)]).tickets
  end

  test "normalized events retain integration and outcome evidence" do
    record = event("1", "blocker_integrate", 1, %{blocker: "9", outcome: "conflict", non_ff: true, start_trigger: "ready", head_start_ms: 100, waste_ms: 200})
    {_actors, tickets, _findings} = Dataset.reduce([record])
    assert [%{blocker: "9", outcome: "conflict", non_ff: true, start_trigger: "ready", head_start_ms: 100, waste_ms: 200}] = tickets["1"].events
  end

  defp render(model), do: render_component(&BuildOrderAnalytics.build_order_analytics/1, scope: %{total: 3, state: :ok}, model: model)

  defp model(records) do
    {actors, tickets, findings} = Dataset.reduce(records)
    dataset = %{actors: actors, tickets: tickets, findings: findings, records: records, provenance: %{time_range: %{start: "2026-10-09T00:00:00Z", end: "2026-10-09T00:01:00Z"}}}
    Presenter.model(dataset, cap: 4, cores: 4, buckets: 4)
  end

  defp event(ticket, name, seconds, fields \\ %{}) do
    timestamp = DateTime.add(~U[2026-10-09 00:00:00Z], seconds)

    %{
      kind: "lifecycle",
      attributes: Map.merge(%{"ticket" => ticket, "event" => name, "boundary" => "point"}, Map.new(fields, fn {key, value} -> {to_string(key), value} end)),
      timestamp: timestamp,
      timestamp_iso: DateTime.to_iso8601(timestamp),
      timestamp_ms: DateTime.to_unix(timestamp, :millisecond),
      recorded_at: nil,
      boot_id: "optimistic-test",
      sequence: seconds,
      record_id: "#{ticket}:#{name}:#{seconds}",
      source_path: "fixture",
      source_line: seconds
    }
  end
end
