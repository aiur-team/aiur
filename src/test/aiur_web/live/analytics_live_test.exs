defmodule AiurWeb.AnalyticsLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.BuildOrder.{Catalog, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.{RunTelemetry, TrackerIdentity}
  alias Aiur.TestSupport.AwaitingCommands
  alias Aiur.UsageAggregate.Projection
  alias AiurWeb.Endpoint

  import Aiur.TestSupport.UsageAggregate, only: [envelope: 0, record: 3]

  @endpoint Endpoint
  @fixtures Path.expand("../../fixtures/run_telemetry", __DIR__)
  @summary_fixture Path.expand("../../fixtures/analytics/runs/boot-a/run-summary.json", __DIR__)

  defmodule UsageAggregateSourceStub do
    @moduledoc false

    def cells_snapshot,
      do: Application.fetch_env!(:aiur, :analytics_usage_aggregate_source_snapshot)

    def snapshot, do: cells_snapshot().metadata
  end

  defmodule BuildOrderSourceStub do
    @moduledoc false

    def catalog(context), do: context.catalog

    def demand(context, identity) do
      case Map.fetch(context.selected, identity.identifier) do
        {:ok, snapshot} -> {:ok, snapshot}
        :error -> {:error, :unavailable}
      end
    end
  end

  setup context do
    previous_telemetry = Application.get_env(:aiur, :analytics_telemetry_file)
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    orchestrator = {:global, {__MODULE__, context.test}}

    if capacity = Map.get(context, :analytics_capacity) do
      # A publisher has to be alive under the orchestrator's registered name, or
      # every read is `:orchestrator_unavailable` — a retained-cache state, not
      # the live one these tests are about.
      publisher = start_supervised!({Agent, fn -> :ok end})
      :yes = :global.register_name({__MODULE__, context.test}, publisher)

      SnapshotStore.publish(orchestrator, %{capacity: capacity})

      if age_ms = Map.get(context, :analytics_capacity_age_ms) do
        # Pin the ceiling: it otherwise derives from the effective poll cadence,
        # so a test that asked the code for its own ceiling would pass against
        # one wide enough that staleness is never reported at all.
        previous_ceiling = Application.get_env(:aiur, :snapshot_stale_age_ceiling_ms)
        Application.put_env(:aiur, :snapshot_stale_age_ceiling_ms, 120_000)
        on_exit(fn -> reset_env(:snapshot_stale_age_ceiling_ms, previous_ceiling) end)

        age_published_snapshot(orchestrator, age_ms)
      end
    end

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        orchestrator: orchestrator
      )
      |> Keyword.merge(awaiting_commands_config(context))

    Application.put_env(:aiur, Endpoint, endpoint_config)
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      SnapshotStore.forget(orchestrator)
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
      File.rm_rf!(root)
      Aiur.TestSupport.restore_app_env(previous_app_env)
      restore_run_id(previous_run_id)
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
      Application.delete_env(:aiur, :analytics_usage_aggregate_source)
      Application.delete_env(:aiur, :analytics_usage_aggregate_source_snapshot)
    end)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:analytics-spend-secret"))

    {:ok, _view, html} = live(conn, "/analytics")

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
      File.rm_rf!(root)
      Aiur.TestSupport.restore_app_env(previous_app_env)
      restore_run_id(previous_run_id)
    end)

    {:ok, _view, html} = live(build_conn(), "/analytics")

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
      File.rm_rf!(root)
      Aiur.TestSupport.restore_app_env(previous_app_env)
    end)

    {:ok, _view, html} = live(build_conn(), "/analytics?build_order=77")

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

  defp write_newer_summary!(path) do
    summary = @summary_fixture |> File.read!() |> String.replace("930", "999") |> Jason.decode!()

    newer =
      summary
      |> put_in(["provenance", "time_range", "end"], "2026-07-12T00:00:16Z")

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(newer))
  end

  test "renders the KPI strip and inline SVG charts from telemetry" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "Peak concurrency"
    assert html =~ ~r/\d+ at run end \/ unknown cap</
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

  test "renders exact source-gated values in the keyboard-reachable pressure table" do
    Application.put_env(:aiur, :analytics_telemetry_file, pressure_fixture!(RunTelemetry.boot_id()))

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ ~s(<table id="analytics-pressure-table">)
    assert html =~ "13"
    assert html =~ "16 / 16 / 12"
    assert html =~ ">2<"
    assert html =~ "2 / 8"
    assert html =~ "189s"
    assert html =~ "2026-07-11T00:00:40.000Z"
    assert html =~ "2026-07-11T00:00:55.000Z"
    assert html =~ ">current<"
    assert html =~ ">measured<"
  end

  test "renders unavailable pressure evidence as em-dash, never a confident zero" do
    boot_id = RunTelemetry.boot_id()
    Application.put_env(:aiur, :analytics_telemetry_file, pressure_fixture_with_gap!(boot_id))

    {:ok, _view, html} = live(build_conn(), "/analytics")

    # The gap row's degraded build must render its missing wait as "—", and a
    # missing fleet figure must never be coerced into a confident "0".
    assert html =~ "—"
    assert html =~ ">degraded<"
    refute html =~ ">0s<"
    # The measured row still carries its exact values (not blurred by the gap).
    assert html =~ "13"
    assert html =~ "189s"
  end

  @tag analytics_capacity: %{effective: 3, max: 8, configured: 16, occupied: 3, available: 0, active: 3, reserved_paused: 0, queued_demand?: true}
  test "renders the runtime cap with every other ceiling the daemon reports" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

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

    {:ok, _view, html} = live(build_conn(), "/analytics")

    # Same `8 cap` string as a plain session override; only the binding clause
    # tells the operator this fleet wants paused reservations reclaimed.
    assert html =~ "binding: paused reservations=4"
  end

  @tag analytics_capacity: %{effective: 3, max: 3, configured: 3, occupied: 0, available: 3, queued_demand?: true}
  @tag analytics_capacity_age_ms: 600_000
  test "marks a retained snapshot with its age instead of rendering it as current" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    # The stale snapshot still renders — that is the SnapshotStore contract —
    # but never unmarked. A ten-minute-old cap read as current is #1564.
    assert html =~ "3 cap (stale, 10m old)"
    refute html =~ "3 cap<"
  end

  test "reports no wasted-capacity figure when no effective cap is known" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    # Idle slot-hours are a subtraction from the cap. With no cap reported the
    # page must not substitute the local config file and print a precise hour
    # count under a ceiling it just called unknown.
    assert html =~ ~r/\d+ at run end \/ unknown cap</
    refute html =~ "unknown cap (configured"
    assert html =~ ~r/Wasted capacity<\/span>\s*<span class="an-kpi-val">—/
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
    assert html =~ ~s(data-source-kind="live")
    assert html =~ "live boot"
    # A live boot is the only source that may speak in the present tense.
    assert html =~ ~r/an-kpi-sub">\d+ now \//
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

    {:ok, _view, html} = live(conn, "/analytics?build_order=77")

    assert html =~ "Build Order #77, latest run"
    # The Build Order strip renders the same effective cap as the run strip;
    # without this the whole Build Order cap path is uncovered.
    assert html =~ "now / 3 cap (session 8, configured 16)"
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
    assert length(Regex.scan(~r/data-time-start="1783728061000"/, zoomed)) == 6
    assert length(Regex.scan(~r/data-time-end="1783728065000"/, zoomed)) == 6
    assert zoomed =~ "phx-click=\"reset-time-domain\""

    patched = render_click(view, "sort", %{"by" => "mem"})
    assert patched =~ ~s(class="an-zoombar")
    assert length(Regex.scan(~r/data-time-start="1783728061000"/, patched)) == 6
    assert length(Regex.scan(~r/data-time-end="1783728065000"/, patched)) == 6

    nav_patched = render_click(view, "toggle-nav", %{})
    assert nav_patched =~ ~s(class="an-zoombar")

    restored = render_hook(view, "restore-nav", %{"collapsed" => false})
    assert restored =~ ~s(class="an-zoombar")

    reset = render_click(view, "reset-time-domain", %{})

    refute reset =~ ~s(class="an-zoombar")
    assert length(Regex.scan(~r/data-time-start="#{full_start}"/, reset)) == 6
    assert length(Regex.scan(~r/data-time-end="#{full_end}"/, reset)) == 6
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

  # Dashboard routes are behind the FinancialDataAccess plug, which challenges
  # any request once credentials are configured (regardless of `dashboard_auth_required`).
  # test_helper configures credentials globally, so every analytics render test must
  # present them. Tests that exercise the missing-configuration path build their own
  # unauthenticated conn explicitly.
  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <> Base.encode64("operator:test-dashboard-secret")
    )
  end

  defp reset_env(key, nil), do: Application.delete_env(:aiur, key)

  test "names its default latest-run scope and Build Order selection" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "latest run"
    assert html =~ "Add a Build Order selection to scope this page to its members"
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

  defp restore_run_id(:unset), do: :persistent_term.erase({Aiur.Boot, :run_id})
  defp restore_run_id(value), do: :persistent_term.put({Aiur.Boot, :run_id}, value)

  defp complexity_fixture! do
    root = Aiur.TestSupport.tmp_root!("aiur-analytics-complexity")

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
      Aiur.TestSupport.tmp_root!("aiur-analytics-route")

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

  defp pressure_fixture_with_gap!(boot_id) do
    root = Path.join(System.tmp_dir!(), "aiur-analytics-pressure-gap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")
    timestamp = ~U[2026-07-11 00:01:01Z]
    gap_timestamp = ~U[2026-07-11 00:11:01Z]

    records = [
      route_record(boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], nil),
      %{
        schema_version: 2,
        kind: "resource",
        timestamp: DateTime.to_iso8601(timestamp),
        recorded_at: DateTime.to_iso8601(timestamp),
        boot_id: boot_id,
        sequence: 2,
        record_id: "#{boot_id}:2",
        attributes: %{
          "actor" => "_daemon",
          "actor_type" => "daemon",
          "availability" => "unavailable",
          "fleet_capacity_status" => "current",
          "fleet_agents_occupied" => 13,
          "fleet_agents_configured" => 16,
          "fleet_agents_max" => 16,
          "fleet_agents_effective" => 12,
          "fleet_capacity_observed_at_ms" => DateTime.to_unix(~U[2026-07-11 00:00:40Z], :millisecond),
          "build_gate_status" => "measured",
          "build_gate_capacity" => 2,
          "build_gate_observed_at_ms" => DateTime.to_unix(~U[2026-07-11 00:00:55Z], :millisecond),
          "build_gate_active" => 2,
          "build_gate_queued" => 8,
          "build_queue_oldest_wait_seconds" => 189
        }
      },
      %{
        schema_version: 2,
        kind: "resource",
        timestamp: DateTime.to_iso8601(gap_timestamp),
        recorded_at: DateTime.to_iso8601(gap_timestamp),
        boot_id: boot_id,
        sequence: 3,
        record_id: "#{boot_id}:3",
        attributes: %{
          "actor" => "_daemon",
          "actor_type" => "daemon",
          "availability" => "unavailable",
          "fleet_capacity_status" => "stale",
          "fleet_agents_occupied" => nil,
          "fleet_agents_configured" => nil,
          "fleet_agents_max" => nil,
          "fleet_agents_effective" => nil,
          "build_gate_status" => "degraded",
          "build_gate_capacity" => nil,
          "build_gate_active" => nil,
          "build_gate_queued" => nil,
          "build_queue_oldest_wait_seconds" => nil
        }
      },
      route_record(boot_id, 4, "dispatch", ~U[2026-07-11 00:01:02Z], "941")
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> File.rm_rf!(root) end)
    path
  end

  defp pressure_fixture!(boot_id) do
    root = Path.join(System.tmp_dir!(), "aiur-analytics-pressure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")
    timestamp = ~U[2026-07-11 00:01:01Z]

    records = [
      route_record(boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], nil),
      %{
        schema_version: 2,
        kind: "resource",
        timestamp: DateTime.to_iso8601(timestamp),
        recorded_at: DateTime.to_iso8601(timestamp),
        boot_id: boot_id,
        sequence: 2,
        record_id: "#{boot_id}:2",
        attributes: %{
          "actor" => "_daemon",
          "actor_type" => "daemon",
          "availability" => "unavailable",
          "fleet_capacity_status" => "current",
          "fleet_agents_occupied" => 13,
          "fleet_agents_configured" => 16,
          "fleet_agents_max" => 16,
          "fleet_agents_effective" => 12,
          "fleet_capacity_observed_at_ms" => DateTime.to_unix(~U[2026-07-11 00:00:40Z], :millisecond),
          "build_gate_status" => "measured",
          "build_gate_capacity" => 2,
          "build_gate_observed_at_ms" => DateTime.to_unix(~U[2026-07-11 00:00:55Z], :millisecond),
          "build_gate_active" => 2,
          "build_gate_queued" => 8,
          "build_queue_oldest_wait_seconds" => 189
        }
      },
      route_record(boot_id, 3, "dispatch", ~U[2026-07-11 00:01:02Z], "941")
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

  defp provider_spend_snapshot(member \\ nil, non_member \\ nil, prior_session_member \\ nil, member_run_id \\ nil) do
    member = member || identity(941, "NODE-941")

    member_envelope =
      envelope()
      |> Map.put(:attribution, attribution(member, member_run_id || RunTelemetry.boot_id()))

    projection = Projection.apply_record(Projection.new(), record(1, member_envelope, %{cost: "3.50"}))

    projection =
      if non_member do
        non_member_envelope = envelope() |> Map.put(:attribution, attribution(non_member))
        Projection.apply_record(projection, record(2, non_member_envelope, %{cost: "9.99"}))
      else
        projection
      end

    projection =
      if prior_session_member do
        prior_session_envelope = envelope() |> Map.put(:attribution, attribution(prior_session_member, "earlier-run"))
        Projection.apply_record(projection, record(3, prior_session_envelope, %{cost: "11.00"}))
      else
        projection
      end

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

  defp attribution(identity, run_id \\ RunTelemetry.boot_id()) do
    %{
      run_id: run_id,
      tracker_identity: identity,
      attempt_id: "attempt-1",
      session_id: "session-1",
      thread_id: "thread-1",
      turn_id: "turn-1",
      request_id: "request-1"
    }
  end

  # `publish/2` stamps the current monotonic clock, so restating the observation
  # time is the only way to read a ten-minute-old snapshot without waiting.
  defp age_published_snapshot(orchestrator, age_ms) do
    cached = :persistent_term.get({SnapshotStore, orchestrator})

    :persistent_term.put(
      {SnapshotStore, orchestrator},
      %{
        cached
        | observed_at_ms: System.monotonic_time(:millisecond) - age_ms,
          observed_at: DateTime.add(DateTime.utc_now(), -age_ms, :millisecond),
          recent_gaps_ms: []
      }
    )

    :ok
  end

  defp build_order_context(root, member) do
    health = ProviderHealth.new(1, :healthy, true)

    root_summary =
      RootSummary.new(%{
        identity: root,
        title: "Analytics Build",
        url: "https://github.com/owner/repo/issues/#{root.identifier}"
      })

    selected =
      %Snapshot{
        scope: {:selected, root},
        repository: {"owner", "repo"},
        authority_epoch: 1,
        generation: 1,
        data:
          SelectedRoot.new(
            root_summary,
            [
              Member.new(%{
                identity: member,
                title: "Selected member",
                url: "https://github.com/owner/repo/issues/#{member.identifier}"
              })
            ],
            health
          ),
        health: health
      }

    %{
      catalog: %Snapshot{
        scope: :catalog,
        repository: {"owner", "repo"},
        authority_epoch: 1,
        generation: 1,
        data: Catalog.new([root_summary], health),
        health: health
      },
      selected: %{root.identifier => selected}
    }
  end

  defp identity(number, provider_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "database_id" => number, "number" => number},
        {"owner", "repo"},
        {"owner", "repo"}
      )

    identity
  end

  defp build_order_route_fixture!(current_boot_id) do
    root = Aiur.TestSupport.tmp_root!("aiur-analytics-build-order")
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")

    records = [
      route_record(current_boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], nil),
      route_record(current_boot_id, 2, "dispatch", ~U[2026-07-11 00:01:01Z], "941"),
      route_record(current_boot_id, 3, "pr_opened", ~U[2026-07-11 00:01:02Z], "941"),
      route_record(current_boot_id, 4, "pr_merged", ~U[2026-07-11 00:01:03Z], "941"),
      route_record(current_boot_id, 5, "dispatch", ~U[2026-07-11 00:01:04Z], "942"),
      route_record(current_boot_id, 6, "pr_opened", ~U[2026-07-11 00:01:05Z], "942"),
      route_record(current_boot_id, 7, "pr_merged", ~U[2026-07-11 00:01:06Z], "942")
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> File.rm_rf!(root) end)
    path
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

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "carries the awaiting-Commands banner into Analytics" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "2 units awaiting commands"
    assert html =~ "decisions-banner"
    assert html =~ ~s(href="/commands")
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "re-reads the awaiting count on a Command signal and on its own tick" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)
    store = Endpoint.config(:decision_store)

    {:ok, view, html} = live(build_conn(), "/analytics")
    assert html =~ "2 units awaiting commands"

    # A best-effort broadcast is the fast path.
    :ok = AwaitingCommands.put_counts(store, open: 1, awaiting: 1, blocking: 0, awaiting_blocking: 0)
    send(view.pid, {:decision_changed, "dec-1", 2})
    assert render(view) =~ "1 unit awaiting commands"

    # The tick is the safety net for a broadcast that never arrives: without it
    # this page would keep showing a count the Commands page has moved past.
    :ok = AwaitingCommands.put_counts(store, open: 0, awaiting: 0)
    send(view.pid, :awaiting_commands_tick)
    refute render(view) =~ "units awaiting commands"
  end

  @tag awaiting_commands: %{total: 4, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0}
  test "omits the awaiting-Commands banner when nothing is waiting" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    refute html =~ "units awaiting commands"
    refute html =~ "decisions-banner"
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "survives every message the Command topic carries" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, html} = live(build_conn(), "/analytics")
    assert html =~ "2 units awaiting commands"

    assert AwaitingCommands.render_after_command_topic(view) =~ "2 units awaiting commands"
  end

  # --- rtk output-compression panel -----------------------------------------

  describe "agent output compression panel" do
    setup do
      Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)
      previous = Application.get_env(:aiur, :analytics_rtk_opts)
      on_exit(fn -> reset_env(:analytics_rtk_opts, previous) end)
      :ok
    end

    defp render_rtk_panel(rtk_opts) do
      Application.put_env(:aiur, :analytics_rtk_opts, rtk_opts)
      {:ok, _view, html} = live(build_conn(), "/analytics")
      html
    end

    defp rtk_runner(responses), do: fn _rtk, args -> Map.fetch!(responses, args) end

    defp admitted_rtk(gain_response) do
      [
        enabled?: true,
        rtk_path: "/usr/bin/rtk",
        runner:
          rtk_runner(%{
            ["--version"] => {"rtk 0.47.0\n", 0},
            ["hook", "check", "gh pr view 1"] => {"No rewrite for: gh pr view 1\n", 1},
            ["gain", "-f", "json"] => gain_response
          })
      ]
    end

    defp gain_json(summary), do: {Jason.encode!(%{"summary" => summary}), 0}

    test "reports the recorded saving" do
      html =
        render_rtk_panel(
          admitted_rtk(
            gain_json(%{
              "total_commands" => 2,
              "total_input" => 469,
              "total_output" => 106,
              "total_saved" => 363,
              "avg_savings_pct" => 77.39872068230277
            })
          )
        )

      assert html =~ "Agent output compression"
      assert html =~ ~s(class="an-rtk-val")
      assert html =~ "77.4%"
      assert html =~ "469"
      assert html =~ "363"
    end

    # An empty rtk history reports `total_commands: 0` beside
    # `avg_savings_pct: 0.0`. The panel must say so in words: "0%" would claim
    # rtk filtered agent output and removed none of it.
    test "says no commands were filtered instead of rendering 0%" do
      html =
        render_rtk_panel(
          admitted_rtk(
            gain_json(%{
              "total_commands" => 0,
              "total_input" => 0,
              "total_output" => 0,
              "total_saved" => 0,
              "avg_savings_pct" => 0.0
            })
          )
        )

      assert html =~ "No commands filtered yet"
      assert html =~ "no saving to report"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end

    test "says rtk is off rather than showing an empty chart" do
      html = render_rtk_panel(enabled?: false)

      assert html =~ "Output compression is off"
      assert html =~ "agent.rtk.enabled"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end

    test "says rtk is missing when it is enabled but not installed" do
      html = render_rtk_panel(enabled?: true, rtk_path: nil)

      assert html =~ "rtk is not installed"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end

    # The operator has to be able to see *why* an enabled rtk is reporting
    # nothing, and "held back to protect the gh guard" is a different fact from
    # "not installed".
    test "names the gh-guard refusal on the page" do
      opts = [
        enabled?: true,
        rtk_path: "/usr/bin/rtk",
        runner:
          rtk_runner(%{
            ["--version"] => {"rtk 0.47.0\n", 0},
            ["hook", "check", "gh pr view 1"] => {"rtk gh pr view 1\n", 0}
          })
      ]

      html = render_rtk_panel(opts)

      assert html =~ "rtk is enabled but held back"
      assert html =~ "would rewrite"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end

    test "reports an unreadable summary as unknown rather than zero" do
      html = render_rtk_panel(admitted_rtk({"not json", 0}))

      assert html =~ "Savings could not be read"
      assert html =~ "unknown rather than zero"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end
  end

  # --- awaiting-Commands banner ---------------------------------------------

  defp awaiting_commands_config(context) do
    case context[:awaiting_commands] do
      nil -> []
      counts -> [decision_store: AwaitingCommands.start(counts)]
    end
  end
end
