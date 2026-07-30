defmodule AiurWeb.AnalyticsLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AiurWeb.Endpoint

  @endpoint Endpoint
  @fixtures Path.expand("../../fixtures/run_telemetry", __DIR__)

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
    assert html =~ "Per-unit CPU"
    assert html =~ "Cost per ticket"
    assert html =~ "Complexity breakdown"
    assert html =~ "—"
    assert html =~ "<svg"
    refute html =~ "No run telemetry to analyze yet"
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

    zoomed = render_hook(view, "time-domain", %{"t0" => 1_783_728_061_000, "t1" => 1_783_728_065_000})

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

    html = render_hook(view, "time-domain", %{"t0" => 1_783_728_061_000, "t1" => 1_783_728_061_001})

    refute html =~ ~s(class="an-zoombar")
  end

  test "changing the existing range control clears an active time zoom" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, _html} = live(build_conn(), "/analytics")

    assert render_hook(view, "time-domain", %{"t0" => 1_783_728_061_000, "t1" => 1_783_728_065_000}) =~
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
    assert html =~ "Build Order page"
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
    root = Path.join(System.tmp_dir!(), "aiur-analytics-complexity-#{System.unique_integer([:positive])}")
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
