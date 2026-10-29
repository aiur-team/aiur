defmodule AiurWeb.AnalyticsLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.AnalyticsLiveFixtures
  alias Aiur.RunTelemetry
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.AnalyticsLiveFixtures.{BuildOrderSourceStub, UsageAggregateSourceStub}
  alias AiurWeb.Endpoint
  @endpoint Endpoint
  @fixtures Path.expand("../../fixtures/run_telemetry", __DIR__)
  @summary_fixture Path.expand("../../fixtures/analytics/runs/boot-a/run-summary.json", __DIR__)
  setup :setup_analytics

  test "shows the empty state when no run telemetry is available" do
    Application.put_env(:aiur, :analytics_telemetry_file, "/nonexistent/telemetry.ndjson")

    {:ok, view, html} = loaded_live(build_conn(), "/analytics")

    assert html =~ "Run analytics"
    assert html =~ "No run telemetry to analyze yet"
    assert html =~ ~s(data-empty-reason="no_telemetry")
    refute html =~ "Start a run with telemetry enabled"
    refute html =~ "Retained run telemetry could not be read"
    refute html =~ "Peak concurrency"
    refute render_hook(view, "time-domain", %{"t0" => 1, "t1" => 2}) =~ ~s(class="an-zoombar")
  end

  test "renders the latest durable run after the daemon restarts into a new log root" do
    root = Aiur.TestSupport.tmp_root!("aiur-analytics-restart")
    summaries = Path.join(root, "aiur-team/aiur/analytics/runs")
    older = Path.join(summaries, "older/run-summary.json")
    newer = Path.join(summaries, "newer/run-summary.json")
    current = Path.join(root, "new-run/log/telemetry.ndjson")
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    previous_app_env = [
      repo_base_root: Application.fetch_env(:aiur, :repo_base_root),
      analytics_repo: Application.fetch_env(:aiur, :analytics_repo)
    ]

    previous_run_id = :persistent_term.get({Aiur.Boot, :run_id}, :unset)

    File.mkdir_p!(Path.dirname(older))
    File.cp!(@summary_fixture, older)
    write_newer_summary!(newer)
    File.mkdir_p!(Path.dirname(current))
    File.write!(current, Jason.encode!(route_record("boot-after-restart", 1, "restart", ~U[2026-07-12 00:01:00Z], nil)) <> "\n")
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "aiur-team/aiur")
    Application.put_env(:aiur, :analytics_telemetry_file, current)
    Application.put_env(:aiur, :analytics_usage_aggregate_source, UsageAggregateSourceStub)

    Application.put_env(
      :aiur,
      :analytics_usage_aggregate_source_snapshot,
      provider_spend_snapshot(identity(999, "NODE-999"), identity(941, "NODE-941"), nil, "boot-a")
    )

    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "analytics-spend-secret")
    :persistent_term.put({Aiur.Boot, :run_id}, "boot-after-restart")

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env(previous_app_env)
      restore_run_id(previous_run_id)
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
      Application.delete_env(:aiur, :analytics_usage_aggregate_source)
      Application.delete_env(:aiur, :analytics_usage_aggregate_source_snapshot)
      Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file])
    end)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:analytics-spend-secret"))

    {:ok, _view, html} = loaded_live(conn, "/analytics")

    assert html =~ "Scope:"
    assert html =~ "latest run"
    assert html =~ ">#999<"
    refute html =~ ">#930<"
    assert html =~ "3.50 USD"
    refute html =~ "9.99 USD"
    assert html =~ ~s(data-source-kind="retained")
    assert html =~ "retained run"
    # The retained source must render its elapsed age ("observed 43d 0h ago"),
    # never "just now" — the age is the only signal this is not the live boot.
    assert html =~ "ago"
    assert html =~ ~r/observed \d+[smhd]/
    # And the KPI strip must not speak in the present tense over a retained run:
    # the concurrency tail and the merged count belong to that run, not this one.
    assert html =~ ~r/an-kpi-sub">\d+ at run end \//
    assert html =~ ~r/an-kpi-sub">that run</
    refute html =~ "No run telemetry to analyze yet"
  end

  test "reports retained-but-unreadable telemetry instead of pretending the fleet is idle" do
    root = Aiur.TestSupport.tmp_root!("aiur-analytics-unreadable")
    summary = Path.join(root, "aiur-team/aiur/analytics/runs/boot-a/run-summary.json")
    current = Path.join(root, "new-run/log/telemetry.ndjson")

    previous_app_env = [
      repo_base_root: Application.fetch_env(:aiur, :repo_base_root),
      analytics_repo: Application.fetch_env(:aiur, :analytics_repo)
    ]

    previous_run_id = :persistent_term.get({Aiur.Boot, :run_id}, :unset)

    # A truncated summary is present (so the fleet did run) but cannot be decoded.
    File.mkdir_p!(Path.dirname(summary))
    File.write!(summary, "{\"schema_version\": 1, \"records\": [")
    File.mkdir_p!(Path.dirname(current))
    File.write!(current, Jason.encode!(route_record("boot-after-restart", 1, "restart", ~U[2026-07-12 00:01:00Z], nil)) <> "\n")
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "aiur-team/aiur")
    Application.put_env(:aiur, :analytics_telemetry_file, current)
    :persistent_term.put({Aiur.Boot, :run_id}, "boot-after-restart")

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env(previous_app_env)
      restore_run_id(previous_run_id)
      Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file])
    end)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    assert html =~ ~s(data-empty-reason="retained_unreadable")
    assert html =~ "Retained run telemetry could not be read"
    refute html =~ "No run telemetry to analyze yet"
    refute html =~ "Peak concurrency"
  end

  test "selects a prior run that is analyzable for the requested Build Order" do
    root = Aiur.TestSupport.tmp_root!("aiur-analytics-build-restart")
    summary = Path.join(root, "aiur-team/aiur/analytics/runs/newer/run-summary.json")
    current_boot = RunTelemetry.boot_id()
    member = identity(999, "NODE-999")
    build_root = identity(77, "ROOT-77")

    previous_app_env = [
      repo_base_root: Application.fetch_env(:aiur, :repo_base_root),
      analytics_repo: Application.fetch_env(:aiur, :analytics_repo),
      build_order_data_source: Application.fetch_env(:aiur, :build_order_data_source)
    ]

    write_newer_summary!(summary)
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "aiur-team/aiur")
    Application.put_env(:aiur, :analytics_telemetry_file, route_fixture!(current_boot))
    Application.put_env(:aiur, :build_order_data_source, {BuildOrderSourceStub, build_order_context(build_root, member)})

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env(previous_app_env)
      Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file])
    end)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics?build_order=77")

    assert html =~ "Build Order #77, latest run"
    assert html =~ ">#999<"
    refute html =~ ">#941<"
    assert html =~ ~s(data-source-kind="retained")
    assert html =~ "retained run"
    # Same age guard as the restart test: a retained Build Order source renders
    # its elapsed age, not the live-boot "just now".
    assert html =~ "ago"
    assert html =~ ~r/observed \d+[smhd]/
    refute html =~ "No run telemetry to analyze yet"
  end

  test "renders the KPI strip and inline SVG charts from telemetry" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    assert html =~ "Peak concurrency"
    assert html =~ ~r/\d+ at run end \/ unknown cap/
    assert html =~ "Wasted capacity"
    assert html =~ "Provider spend"
    assert html =~ "Per-unit CPU"
    assert html =~ "Cost per ticket"
    assert html =~ "Complexity breakdown"
    assert html =~ "Fleet-wide build pressure"
    assert html =~ "Accessible fleet pressure data"
    assert html =~ "stale fleet"
    assert html =~ ">empty<"
    assert html =~ "<svg"
    assert html =~ "Source:"
    refute html =~ "No run telemetry to analyze yet"
  end

  @tag analytics_capacity: %{effective: 3, max: 8, configured: 16, occupied: 3, available: 0, active: 3, reserved_paused: 0, queued_demand?: true}
  test "renders the runtime cap with every other ceiling the daemon reports" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    # The effective cap leads. The session ceiling is the figure `aiur status`
    # prints as `AGENTS n/8`, so omitting it is what let the two surfaces
    # contradict each other; the configured value is what #2241 saw alone.
    assert html =~ ~r/\d+ at run end \/ 3 cap \(binding: AIMD envelope, session 8, configured 16\)/
    refute html =~ ~r/\d+ at run end \/ 16 cap/
    refute html =~ ~r/\d+ at run end \/ 8 cap/
  end

  @tag analytics_capacity: %{
         effective: 8,
         max: 8,
         configured: 16,
         occupied: 4,
         active: 4,
         available: 0,
         reserved_paused: 4,
         queued_demand?: true,
         session_override?: true
       }
  test "names the binding constraint, which a bare cap figure cannot distinguish" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    # Same `8 cap` string as a plain session override; only the binding clause
    # tells the operator this fleet wants paused reservations reclaimed.
    assert html =~ "binding: paused reservations=4"
  end

  @tag analytics_capacity: %{effective: 3, max: 3, configured: 3, occupied: 0, available: 3, queued_demand?: true}
  @tag analytics_capacity_age_ms: 600_000
  test "marks a retained snapshot with its age instead of rendering it as current" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    # The stale snapshot still renders — that is the SnapshotStore contract —
    # but never unmarked. A ten-minute-old cap read as current is #1564.
    assert html =~ "3 cap (binding: awaiting dispatch, stale, 10m old)"
    refute html =~ "3 cap<"
  end

  test "unconfigured dashboard authentication refuses the analytics route with its cause" do
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    response = get(Phoenix.ConnTest.build_conn(), "/analytics")

    assert response.status == 503
    assert response.resp_body =~ "Dashboard authentication is not configured"
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

    {:ok, _view, html} = loaded_live(conn, "/analytics")

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
    assert html =~ ~s(data-source-kind="live")
    assert html =~ "live boot"
    # A live boot is the only source that may speak in the present tense.
    assert html =~ ~r/an-kpi-sub">no fleet-capacity or agent samples in this window; occupancy unavailable \/.*cap/
    assert html =~ ~r/an-kpi-sub">this run</
  end

  @tag analytics_capacity: %{effective: 3, max: 8, configured: 16, occupied: 0, available: 3, queued_demand?: true}
  test "scopes analytics and provider spend to typed selected Build Order members" do
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    previous_source = Application.get_env(:aiur, :build_order_data_source)
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "analytics-spend-secret")

    member = identity(941, "NODE-941")
    non_member = identity(942, "NODE-942")
    root = identity(77, "ROOT-77")

    Application.put_env(:aiur, :analytics_telemetry_file, build_order_route_fixture!(RunTelemetry.boot_id()))
    Application.put_env(:aiur, :analytics_usage_aggregate_source, UsageAggregateSourceStub)
    Application.put_env(:aiur, :analytics_usage_aggregate_source_snapshot, provider_spend_snapshot(member, non_member, member))
    Application.put_env(:aiur, :build_order_data_source, {BuildOrderSourceStub, build_order_context(root, member)})

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
      reset_env(:build_order_data_source, previous_source)
      Application.delete_env(:aiur, :analytics_usage_aggregate_source)
      Application.delete_env(:aiur, :analytics_usage_aggregate_source_snapshot)
    end)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:analytics-spend-secret"))

    {:ok, _view, html} = loaded_live(conn, "/analytics?build_order=77")

    assert html =~ "Build Order #77, latest run"
    # The Build Order strip renders the same effective cap as the run strip;
    # without this the whole Build Order cap path is uncovered.
    assert html =~ "now / 3 cap (binding: awaiting dispatch, session 8, configured 16)"
    refute html =~ "now / 16 cap"
    assert html =~ ">#941<"
    refute html =~ ">#942<"
    assert html =~ "PRs merged"
    assert html =~ ~r/PRs merged<\/span>\s*<span class="an-kpi-val">1</
    assert html =~ "3.50 USD"
    refute html =~ "9.99 USD"
    refute html =~ "11.00 USD"
  end

  test "renders populated complexity tiers from dispatch telemetry" do
    path = complexity_fixture!()
    Application.put_env(:aiur, :analytics_telemetry_file, path)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    assert html =~ "Complexity breakdown"
    assert html =~ "Complexity 1: 1 tickets"
    assert html =~ "1m"
  end

  test "range and sort toggles re-render without crashing" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, _html} = loaded_live(build_conn(), "/analytics")
    assert render_click(view, "range", %{"range" => "full"}) =~ "Run analytics"
    LiveViewAsync.render_when_complete(view)
    assert render_click(view, "sort", %{"by" => "mem"}) =~ "Cost per ticket"
    assert render_click(view, "select_none", %{}) =~ "Run analytics"
    assert render_click(view, "select_all", %{}) =~ "Run analytics"
    assert render_click(view, "toggle_unit", %{"key" => "ticket:404"}) =~ "Run analytics"
  end

  test "a time-domain hook event zooms every measured time chart and reset restores the full range" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, html} = loaded_live(build_conn(), "/analytics")

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

    {:ok, view, _html} = loaded_live(build_conn(), "/analytics")

    html =
      render_hook(view, "time-domain", %{"t0" => 1_783_728_061_000, "t1" => 1_783_728_061_001})

    refute html =~ ~s(class="an-zoombar")
  end

  test "changing the existing range control clears an active time zoom" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, _html} = loaded_live(build_conn(), "/analytics")

    assert render_hook(view, "time-domain", %{
             "t0" => 1_783_728_061_000,
             "t1" => 1_783_728_065_000
           }) =~
             ~s(class="an-zoombar")

    render_click(view, "range", %{"range" => "full"})
    full_log = LiveViewAsync.render_when_complete(view)

    refute full_log =~ ~s(class="an-zoombar")
    assert full_log =~ ~s(phx-value-range="full")
  end

  test "a full-range domain event leaves the charts unzoomed" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, html} = loaded_live(build_conn(), "/analytics")
    [_, start_ms] = Regex.run(~r/data-time-start="(\d+)"/, html)
    [_, end_ms] = Regex.run(~r/data-time-end="(\d+)"/, html)

    full_range = render_hook(view, "time-domain", %{"t0" => start_ms, "t1" => end_ms})

    refute full_range =~ ~s(class="an-zoombar")
  end

  test "names its default latest-run scope and Build Order selection" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    assert html =~ "latest run"
    assert html =~ "This is a 1-ticket window: only one ticket has telemetry in the latest run."
  end

  test "charts only the current session, not every session in the durable stream" do
    # The stream is append-only across daemon boots and is never rotated, so it
    # holds boot-a and boot-b. The live page is the current run only; ticket 931
    # ran in the earlier session and must not appear here.
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    assert html =~ ">#930<"
    refute html =~ ">#931<"
  end
end
