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

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "Run analytics"
    assert html =~ "No run telemetry to analyze yet"
    refute html =~ "Peak concurrency"
  end

  test "renders the KPI strip and inline SVG charts from telemetry" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = live(build_conn(), "/analytics")

    assert html =~ "Peak concurrency"
    assert html =~ "Wasted capacity"
    assert html =~ "Per-unit CPU"
    assert html =~ "Cost per ticket"
    assert html =~ "<svg"
    refute html =~ "No run telemetry to analyze yet"
  end

  test "range and sort toggles re-render without crashing" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, _html} = live(build_conn(), "/analytics")

    assert render_click(view, "range", %{"range" => "full"}) =~ "Run analytics"
    assert render_click(view, "sort", %{"by" => "mem"}) =~ "Cost per ticket"
    assert render_click(view, "select_none", %{}) =~ "Units"
  end

  defp reset_env(key, nil), do: Application.delete_env(:aiur, key)
  defp reset_env(key, value), do: Application.put_env(:aiur, key, value)
end
