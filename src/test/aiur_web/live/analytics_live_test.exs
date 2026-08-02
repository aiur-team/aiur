defmodule AiurWeb.AnalyticsLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.RunTelemetry
  alias Aiur.UsageAggregate.Projection
  alias AiurWeb.Endpoint

  import Aiur.TestSupport.UsageAggregate, only: [envelope: 0, record: 3]

  @endpoint Endpoint
  @fixtures Path.expand("../../fixtures/run_telemetry", __DIR__)

  defmodule UsageAggregateSourceStub do
    @moduledoc false

    def cells_snapshot,
      do: Application.fetch_env!(:aiur, :analytics_usage_aggregate_source_snapshot)

    def snapshot, do: cells_snapshot().metadata
  end

  setup do
    previous_telemetry = Application.get_env(:aiur, :analytics_telemetry_file)
    previous_endpoint = Application.get_env(:aiur, Endpoint)

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false
      )

    Application.put_env(:aiur, Endpoint, endpoint_config)
    start_supervised!({Endpoint, []})

    on_exit(fn ->
      reset_env(Endpoint, previous_endpoint)
      reset_env(:analytics_telemetry_file, previous_telemetry)
    end)

    :ok
  end

  test "shows the empty state when no run telemetry is available" do
    Application.put_env(:aiur, :analytics_telemetry_file, "/nonexistent/telemetry.ndjson")

    {:ok, view, html} = live(build_conn(), "/analytics")

    assert html =~ "Run analytics"
    assert html =~ "No run telemetry to analyze yet"
    refute html =~ "Peak concurrency"
    refute render_hook(view, "time-domain", %{"t0" => 1, "t1" => 2}) =~ ~s(class="an-zoombar")
  end

  test "renders the KPI strip and inline SVG charts from telemetry" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "Peak concurrency"
    assert html =~ "Wasted capacity"
    assert html =~ "Provider spend"
    assert html =~ "Locked"
    assert html =~ "Per-unit CPU"
    assert html =~ "Cost per ticket"
    assert html =~ "Complexity breakdown"
    assert html =~ "—"
    assert html =~ "<svg"
    refute html =~ "No run telemetry to analyze yet"
  end

  test "renders current-session completion KPIs and protected UsageAggregate provider spend" do
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "analytics-spend-secret")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
      Application.delete_env(:aiur, :analytics_usage_aggregate_source)
      Application.delete_env(:aiur, :analytics_usage_aggregate_source_snapshot)
    end)

    Application.put_env(:aiur, :analytics_telemetry_file, route_fixture!(RunTelemetry.boot_id()))
    Application.put_env(:aiur, :analytics_usage_aggregate_source, UsageAggregateSourceStub)

    Application.put_env(
      :aiur,
      :analytics_usage_aggregate_source_snapshot,
      provider_spend_snapshot()
    )

    conn =
      build_conn()
      |> Plug.Conn.put_req_header(
        "authorization",
        "Basic " <> Base.encode64("operator:analytics-spend-secret")
      )

    {:ok, _view, html} = live(conn, "/analytics")

    assert html =~ "PRs merged"
    assert html =~ ~r/PRs merged<\/span>\s*<span class="an-kpi-val">1</
    assert html =~ "Tickets done"
    assert html =~ "1 / 1"
    assert html =~ "100% complete"
    assert html =~ ">#941<"
    refute html =~ ">#940<"
    assert html =~ "Provider spend"
    assert html =~ "3.50 USD"
    assert html =~ "provider-reported estimate"
  end

  test "renders populated complexity tiers from dispatch telemetry" do
    path = complexity_fixture!()
    Application.put_env(:aiur, :analytics_telemetry_file, path)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "Complexity breakdown"
    assert html =~ "Complexity 1: 1 tickets"
    assert html =~ "1m"
  end

  test "range and sort toggles re-render without crashing" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, _html} = live(build_conn(), "/analytics")

    assert render_click(view, "range", %{"range" => "full"}) =~ "Run analytics"
    assert render_click(view, "sort", %{"by" => "mem"}) =~ "Cost per ticket"
    assert render_click(view, "select_none", %{}) =~ "Units"
    assert render_click(view, "select_all", %{}) =~ "Units"
    assert render_click(view, "toggle_unit", %{"key" => "ticket:404"}) =~ "Run analytics"
  end

  test "a time-domain hook event zooms every time chart and reset restores the full range" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, html} = live(build_conn(), "/analytics")

    [_, full_start] = Regex.run(~r/data-time-start="(\d+)"/, html)
    [_, full_end] = Regex.run(~r/data-time-end="(\d+)"/, html)

    refute html =~ ~s(class="an-zoombar")

    zoomed =
      render_hook(view, "time-domain", %{"t0" => 1_783_728_061_000, "t1" => 1_783_728_065_000})

    assert zoomed =~ ~s(class="an-zoombar")
    assert length(Regex.scan(~r/data-time-start="1783728061000"/, zoomed)) == 5
    assert length(Regex.scan(~r/data-time-end="1783728065000"/, zoomed)) == 5
    assert zoomed =~ "phx-click=\"reset-time-domain\""

    patched = render_click(view, "sort", %{"by" => "mem"})
    assert patched =~ ~s(class="an-zoombar")
    assert length(Regex.scan(~r/data-time-start="1783728061000"/, patched)) == 5
    assert length(Regex.scan(~r/data-time-end="1783728065000"/, patched)) == 5

    nav_patched = render_click(view, "toggle-nav", %{})
    assert nav_patched =~ ~s(class="an-zoombar")

    restored = render_hook(view, "restore-nav", %{"collapsed" => false})
    assert restored =~ ~s(class="an-zoombar")

    reset = render_click(view, "reset-time-domain", %{})

    refute reset =~ ~s(class="an-zoombar")
    assert length(Regex.scan(~r/data-time-start="#{full_start}"/, reset)) == 5
    assert length(Regex.scan(~r/data-time-end="#{full_end}"/, reset)) == 5
  end

  test "a degenerate domain event leaves the full chart range intact" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, _html} = live(build_conn(), "/analytics")

    html =
      render_hook(view, "time-domain", %{"t0" => 1_783_728_061_000, "t1" => 1_783_728_061_001})

    refute html =~ ~s(class="an-zoombar")
  end

  test "changing the existing range control clears an active time zoom" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, _html} = live(build_conn(), "/analytics")

    assert render_hook(view, "time-domain", %{
             "t0" => 1_783_728_061_000,
             "t1" => 1_783_728_065_000
           }) =~
             ~s(class="an-zoombar")

    full_log = render_click(view, "range", %{"range" => "full"})

    refute full_log =~ ~s(class="an-zoombar")
    assert full_log =~ ~s(phx-value-range="full")
  end

  test "a full-range domain event leaves the charts unzoomed" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, html} = live(build_conn(), "/analytics")
    [_, start_ms] = Regex.run(~r/data-time-start="(\d+)"/, html)
    [_, end_ms] = Regex.run(~r/data-time-end="(\d+)"/, html)

    full_range = render_hook(view, "time-domain", %{"t0" => start_ms, "t1" => end_ms})

    refute full_range =~ ~s(class="an-zoombar")
  end

  defp reset_env(key, nil), do: Application.delete_env(:aiur, key)

  test "names its scope so it cannot be confused with the Build Order pane" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "this session"
    assert html =~ "Build Order page applies the same current-session boundary"
  end

  test "charts only the current session, not every session in the durable stream" do
    # The stream is append-only across daemon boots and is never rotated, so it
    # holds boot-a and boot-b. The live page is the current run only; ticket 931
    # ran in the earlier session and must not appear here.
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ ">#930<"
    refute html =~ ">#931<"
  end

  defp reset_env(key, value), do: Application.put_env(:aiur, key, value)

  defp complexity_fixture! do
    root =
      Path.join(
        System.tmp_dir!(),
        "aiur-analytics-complexity-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")

    records = [
      record(1, "restart", ~U[2026-07-11 00:00:00Z], %{}),
      record(2, "dispatch", ~U[2026-07-11 00:00:01Z], %{"complexity" => 1}),
      record(3, "pr_merged", ~U[2026-07-11 00:01:01Z], %{}),
      record(4, "dispatch", ~U[2026-07-11 00:02:01Z], %{"complexity" => 3}),
      record(5, "pr_merged", ~U[2026-07-11 00:04:01Z], %{})
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> File.rm_rf!(root) end)
    path
  end

  defp route_fixture!(current_boot_id) do
    root =
      Path.join(System.tmp_dir!(), "aiur-analytics-route-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")

    records = [
      route_record("prior-boot", 1, "restart", ~U[2026-07-11 00:00:00Z], nil),
      route_record("prior-boot", 2, "pr_merged", ~U[2026-07-11 00:00:01Z], "940"),
      route_record(current_boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], nil),
      route_record(current_boot_id, 2, "dispatch", ~U[2026-07-11 00:01:01Z], "941"),
      route_record(current_boot_id, 3, "pr_opened", ~U[2026-07-11 00:01:02Z], "941"),
      route_record(current_boot_id, 4, "pr_merged", ~U[2026-07-11 00:01:03Z], "941")
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> File.rm_rf!(root) end)
    path
  end

  defp route_record(boot_id, sequence, event, timestamp, ticket) do
    attributes =
      %{
        "event" => event,
        "boundary" => "point",
        "event_key" => "route-#{boot_id}-#{sequence}"
      }
      |> then(fn attributes ->
        if ticket, do: Map.put(attributes, "ticket", ticket), else: attributes
      end)

    %{
      schema_version: 2,
      kind: if(event == "restart", do: "restart", else: "lifecycle"),
      timestamp: DateTime.to_iso8601(timestamp),
      recorded_at: DateTime.to_iso8601(timestamp),
      boot_id: boot_id,
      sequence: sequence,
      record_id: "#{boot_id}:#{sequence}",
      attributes: attributes
    }
  end

  defp provider_spend_snapshot do
    usage_envelope = envelope()

    usage_envelope = %{
      usage_envelope
      | attribution: %{usage_envelope.attribution | run_id: RunTelemetry.boot_id()}
    }

    projection =
      Projection.apply_record(Projection.new(), record(1, usage_envelope, %{cost: "3.50"}))

    %{
      cells: projection.cells,
      metadata: %{
        generation: projection.generation,
        health: :healthy,
        freshness: %{status: :fresh},
        retained_interval: %{earliest: 1, latest: 1, status: :retained}
      }
    }
  end

  defp record(sequence, event, timestamp, extra) do
    %{
      schema_version: 2,
      kind: "lifecycle",
      timestamp: DateTime.to_iso8601(timestamp),
      recorded_at: DateTime.to_iso8601(timestamp),
      boot_id: "complexity-boot",
      sequence: sequence,
      record_id: "complexity-boot:#{sequence}",
      attributes:
        Map.merge(
          %{
            "ticket" => if(sequence in [2, 3], do: "1", else: "3"),
            "attempt_id" => "attempt-#{sequence}",
            "event" => event,
            "boundary" => "point",
            "event_key" => "complexity-#{sequence}"
          },
          extra
        )
    }
  end
end
