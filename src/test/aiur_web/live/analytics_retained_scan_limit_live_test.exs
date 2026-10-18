defmodule AiurWeb.AnalyticsRetainedScanLimitLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.RunTelemetry.Summaries
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.Endpoint

  @endpoint Endpoint
  @summary_fixture Path.expand("../../fixtures/analytics/runs/boot-a/run-summary.json", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "analytics-scan-limit-#{System.unique_integer([:positive])}")

    previous =
      for key <- [:repo_base_root, :analytics_repo, :analytics_telemetry_file, :analytics_rtk_opts, Endpoint],
          do: {key, Application.fetch_env(:aiur, key)}

    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "scan-limit/test")
    Application.put_env(:aiur, :analytics_telemetry_file, Path.join(root, "missing.ndjson"))
    Application.put_env(:aiur, :analytics_rtk_opts, enabled?: false)

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(Application.get_env(:aiur, Endpoint, []),
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false
      )
    )

    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)

      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  test "full analytics names the bounded scan state when a retained summary is too large" do
    summary = @summary_fixture |> File.read!() |> Jason.decode!()
    warnings = Enum.map(1..1_000, fn n -> %{"kind" => "warning", "details" => String.duplicate("x", 50_000), "record_id" => "warning-#{n}"} end)
    body = summary |> Map.put("records", warnings) |> put_in(["provenance", "time_range", "end"], "2026-10-18T00:00:00Z")
    path = Summaries.run_summary_path("oversized")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(body))
    assert File.stat!(path).size > 45 * 1024 * 1024

    {:ok, view, _html} = live(authenticated_conn(), "/analytics")
    render_click(view, "range", %{"range" => "full"})
    html = LiveViewAsync.render_when_complete(view)

    assert html =~ ~s(data-empty-reason="retained_scan_limited")
    assert html =~ "too large to scan within the page budget"
    refute html =~ "its retained summary cannot be decoded"
  end

  defp authenticated_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end
end
