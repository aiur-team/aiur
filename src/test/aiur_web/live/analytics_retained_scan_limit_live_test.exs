defmodule AiurWeb.AnalyticsRetainedScanLimitLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.RunTelemetry.Summaries
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

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
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    newer_at = DateTime.to_iso8601(now)
    older_at = now |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
    older = put_in(summary, ["provenance", "time_range", "end"], older_at)
    older_path = Summaries.run_summary_path("older")
    File.mkdir_p!(Path.dirname(older_path))
    File.write!(older_path, Jason.encode!(older))

    body = summary |> Map.put("records", warnings) |> put_in(["provenance", "time_range", "end"], newer_at)
    path = Summaries.run_summary_path("oversized")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(body))
    assert File.stat!(path).size > 45 * 1024 * 1024

    assert {:ok, cross_model} = Presenter.load(session: :cross, telemetry_file: Application.get_env(:aiur, :analytics_telemetry_file))
    assert cross_model.retained_runs.skipped_large == 1

    {:ok, view, _html} = live(authenticated_conn(), "/analytics")
    latest_html = LiveViewAsync.render_when_complete(view)
    assert latest_html =~ "Newer retained runs skipped: 1 (45 MiB scan budget)"

    render_click(view, "range", %{"range" => "full"})
    html = LiveViewAsync.render_when_complete(view)
    assert html =~ "1 other retained runs omitted by the 45 MiB scan budget"

    File.rm!(older_path)
    {:ok, unavailable_view, _html} = live(authenticated_conn(), "/analytics")
    unavailable_html = LiveViewAsync.render_when_complete(unavailable_view)
    assert unavailable_html =~ ~s(data-empty-reason="retained_scan_limited")
    assert unavailable_html =~ "too large to scan within the page budget"
    refute unavailable_html =~ "its retained summary cannot be decoded"
  end

  defp authenticated_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end
end
