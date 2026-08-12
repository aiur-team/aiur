defmodule Aiur.AnalyticsCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.AnalyticsCLI

  @start ~U[2026-08-09 10:00:00Z]
  @finish ~U[2026-08-09 11:00:00Z]

  test "renders a stable snapshot with the default page window" do
    assert {:ok, envelope} =
             AnalyticsCLI.build(
               now: @finish,
               presenter_load: fn opts ->
                 assert opts[:range] == :run
                 assert opts[:session] == :current
                 {:ok, model()}
               end
             )

    assert envelope["schema_version"] == 1
    assert envelope["page"] == "analytics"
    assert envelope["snapshot"]["captured_at"] == DateTime.to_iso8601(@finish)
    assert envelope["request"] == %{"range" => "run"}
    assert envelope["sources"]["telemetry"]["state"] == "available"
    assert envelope["data"]["range"]["start"] == DateTime.to_unix(@start, :millisecond)
    assert envelope["data"]["range"]["end"] == DateTime.to_unix(@finish, :millisecond)
    assert envelope["data"]["range"]["applies_to"] == "time_charts"
    assert envelope["data"]["model"]["window"]["start_ms"] == DateTime.to_unix(@start, :millisecond)
    refute Map.has_key?(envelope["data"], "view")
    assert envelope["auxiliary"]["provider_spend"]["source"]["state"] == "unavailable"
  end

  test "keeps an unobserved telemetry source explicitly unknown" do
    assert {:ok, envelope} =
             AnalyticsCLI.build(
               now: @finish,
               presenter_load: fn _opts -> {:ok, Map.delete(model(), :source_observed_at)} end
             )

    assert envelope["sources"]["telemetry"] == %{
             "age_ms" => nil,
             "freshness" => "unknown",
             "observed_at" => nil,
             "partial" => false,
             "reasons" => [],
             "state" => "available"
           }
  end

  test "reports stale telemetry separately from an unknown observation time" do
    assert {:ok, envelope} =
             AnalyticsCLI.build(
               now: DateTime.add(@finish, 31, :second),
               presenter_load: fn _opts -> {:ok, model()} end
             )

    assert envelope["sources"]["telemetry"]["freshness"] == "stale"
    assert envelope["sources"]["telemetry"]["age_ms"] == 31_000
  end

  test "honors an explicit ISO-8601 brush window and emits JSON" do
    since = DateTime.add(@start, 10 * 60, :second)
    until = DateTime.add(@start, 20 * 60, :second)

    output =
      capture_io(fn ->
        assert 0 ==
                 AnalyticsCLI.run(
                   json: true,
                   now: @finish,
                   since: DateTime.to_iso8601(since),
                   until: DateTime.to_iso8601(until),
                   presenter_load: fn _opts -> {:ok, model()} end
                 )
      end)

    json = Jason.decode!(output)
    assert json["request"]["since"] == DateTime.to_iso8601(since)
    assert json["request"]["until"] == DateTime.to_iso8601(until)
    assert json["data"]["range"]["start"] == DateTime.to_unix(since, :millisecond)
    assert json["data"]["range"]["end"] == DateTime.to_unix(until, :millisecond)
    assert json["data"]["model"]["window"]["start_ms"] == DateTime.to_unix(since, :millisecond)
    assert {:ok, observed_at, _offset} = DateTime.from_iso8601(json["sources"]["telemetry"]["observed_at"])
    assert DateTime.to_unix(observed_at, :millisecond) == DateTime.to_unix(@finish, :millisecond)
  end

  test "keeps an empty requested window distinct from zero telemetry" do
    assert {:ok, envelope} =
             AnalyticsCLI.build(
               since: "2026-08-10T10:00:00Z",
               until: "2026-08-10T11:00:00Z",
               presenter_load: fn _opts -> {:ok, model()} end
             )

    assert envelope["sources"]["telemetry"]["state"] == "empty"
    assert envelope["sources"]["telemetry"]["reasons"] == ["empty_window"]
    assert envelope["data"]["model"] == nil
    assert envelope["data"]["range"]["state"] == "empty"
    refute Map.has_key?(envelope["data"], "view")
  end

  test "labels an empty requested interval as empty in human output" do
    output =
      capture_io(fn ->
        assert 0 ==
                 AnalyticsCLI.run(
                   since: "2026-08-10T10:00:00Z",
                   until: "2026-08-10T11:00:00Z",
                   presenter_load: fn _opts -> {:ok, model()} end
                 )
      end)

    assert output =~ "Window: no telemetry in requested interval 2026-08-10T10:00:00.000Z to 2026-08-10T11:00:00.000Z (run)"
    refute output =~ "Chart window:"
  end

  test "does not widen a narrow explicit window to the brush's visual minimum" do
    since = DateTime.add(@start, 1, :second)
    until = DateTime.add(since, 1, :second)

    assert {:ok, envelope} =
             AnalyticsCLI.build(
               since: DateTime.to_iso8601(since),
               until: DateTime.to_iso8601(until),
               presenter_load: fn _opts -> {:ok, model()} end
             )

    assert envelope["data"]["range"]["start"] == DateTime.to_unix(since, :millisecond)
    assert envelope["data"]["model"]["window"]["end_ms"] == DateTime.to_unix(until, :millisecond)
  end

  test "rejects malformed and reversed timestamps" do
    assert {:error, message} = AnalyticsCLI.build(since: "tomorrow")
    assert message =~ "ISO-8601"

    assert {:error, message} = AnalyticsCLI.build(since: "2026-08-09T11:00:00Z", until: "2026-08-09T10:00:00Z")
    assert message =~ "before"
  end

  test "keeps the requested window visible when telemetry is unavailable" do
    output =
      capture_io(fn ->
        assert 0 ==
                 AnalyticsCLI.run(
                   since: "2026-08-09T10:00:00Z",
                   until: "2026-08-09T11:00:00Z",
                   presenter_load: fn _opts -> {:unavailable, :no_telemetry} end
                 )
      end)

    assert output =~ "Window: unavailable; requested 2026-08-09T10:00:00Z to 2026-08-09T11:00:00Z (run)"
  end

  test "does not claim an unavailable Build Order graph is available" do
    assert {:ok, envelope} =
             AnalyticsCLI.build(
               build_order: "1595",
               scope_resolver: fn "1595" -> :unavailable end
             )

    assert envelope["sources"]["planning_graph"]["state"] == "unavailable"
    assert envelope["sources"]["planning_graph"]["reasons"] == ["build_order_unavailable"]
    refute Map.has_key?(envelope["data"], "view")
  end

  test "renders every dashboard KPI in human output" do
    output =
      capture_io(fn ->
        assert 0 == AnalyticsCLI.run(now: @finish, presenter_load: fn _opts -> {:ok, model()} end)
      end)

    assert output =~ "Memory headroom:"
    assert output =~ "PRs merged:"
    assert output =~ "Wasted capacity:"
    assert output =~ "telemetry: available; freshness current; observed 2026-08-09T11:00:00Z; age 0ms"
    assert output =~ "provider_spend: unavailable; freshness unknown; observed unknown; age unknown"
    assert output =~ "Chart window: 2026-08-09T10:00:00.000Z to 2026-08-09T11:00:00.000Z (run)"
    assert output =~ "Page metrics for selected scope (run-scoped, as on /analytics):"
    assert output =~ "tier 1: 1 tickets; average wall-clock 1m"
  end

  test "passes the resolved Build Order ticket set to the dashboard presenter" do
    scope = %{kind: :build_order, root_number: "1595", tickets: MapSet.new(["10", "11"]), total: 2, usage_scope: :unused}

    assert {:ok, envelope} =
             AnalyticsCLI.build(
               build_order: "1595",
               scope_resolver: fn "1595" -> scope end,
               presenter_load: fn opts ->
                 assert Enum.sort(opts[:tickets]) == ["10", "11"]
                 assert opts[:scope_total] == 2
                 {:ok, model()}
               end
             )

    assert envelope["data"]["scope"]["root_number"] == "1595"
  end

  defp model do
    start_ms = DateTime.to_unix(@start, :millisecond)
    end_ms = DateTime.to_unix(@finish, :millisecond)

    %{
      window: %{start_ms: start_ms, end_ms: end_ms, buckets: 2},
      source_observed_at: DateTime.to_iso8601(@finish),
      series: [%{t_ms: start_ms}, %{t_ms: end_ms}],
      kpis: %{
        peak_conc: 2,
        mean_util_pct: 40.0,
        mem_headroom_pct: 68.0,
        mem_now_bytes: 10_000,
        host_mem_bytes: 20_000,
        done: 1,
        total: 2,
        merged: 1,
        wasted_slot_hours: 1.5
      },
      complexity_breakdown: [%{tier: 1, count: 1, average_wall_clock_ms: 60_000}]
    }
  end
end
