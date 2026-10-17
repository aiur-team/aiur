defmodule AiurWeb.AnalyticsUnknownCapTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @endpoint Endpoint
  @fixtures Path.expand("../../fixtures/run_telemetry", __DIR__)

  setup context do
    previous_telemetry = Application.get_env(:aiur, :analytics_telemetry_file)
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    orchestrator = {:global, {__MODULE__, context.test}}

    endpoint_config =
      Keyword.merge(previous_endpoint || [],
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        orchestrator: orchestrator
      )

    Application.put_env(:aiur, Endpoint, endpoint_config)
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      reset_env(:analytics_telemetry_file, previous_telemetry)
      reset_env(Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "reports no wasted-capacity figure when no effective cap is known" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, _html} = live(build_conn(), "/analytics")

    html = LiveViewAsync.render_when_complete(view)

    # Idle slot-hours are a subtraction from the cap. With no cap reported the
    # page must not substitute the local config file and print a precise hour
    # count under a ceiling it just called unknown.
    assert html =~ ~r/\d+ at run end \/ unknown cap</

    assert {:ok, model} =
             Presenter.load(
               telemetry_file: @fixtures,
               orchestrator: Endpoint.config(:orchestrator)
             )

    assert model.cap == nil
    assert model.kpis.cap == nil
    refute html =~ ~r/>cap \d+<\/text>/
    refute html =~ ~s|fill="var(--blocking)" fill-opacity="0.07"|
    refute html =~ "unknown cap (configured"
    assert html =~ ~r/Wasted capacity<\/span>\s*<span class="an-kpi-val">—/
  end

  # Adopted agents the sampler never attributed left the tile at a confident 0 (#4829).
  test "an occupied fleet with no sampled agents reads unknown peak concurrency, never 0" do
    Application.put_env(:aiur, :analytics_telemetry_file, occupied_fleet_fixture!(Aiur.RunTelemetry.boot_id(), 7))

    {:ok, view, _html} = live(build_conn(), "/analytics")
    LiveViewAsync.render_when_complete(view)
    tile = view |> element(".an-kpi", "Peak concurrency") |> render()

    assert tile =~ ~s(<span class="an-kpi-val">unknown</span>)
    assert tile =~ "partial: 7 of 7 occupied slots not seen as active"
  end

  # Only the daemon's fleet sample: no `ticket:*` resource actor ever reports active.
  defp occupied_fleet_fixture!(boot_id, occupied) do
    root = Path.join(System.tmp_dir!(), "aiur-analytics-occupied-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")

    records = [
      record(boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], %{"event" => "restart", "boundary" => "point"}),
      record(boot_id, 2, "resource", ~U[2026-07-11 00:01:01Z], %{
        "actor" => "_daemon",
        "actor_type" => "daemon",
        "availability" => "unavailable",
        "fleet_capacity_status" => "current",
        "fleet_agents_occupied" => occupied,
        "fleet_agents_configured" => 16,
        "fleet_agents_max" => 16,
        "fleet_agents_effective" => 12,
        "fleet_capacity_observed_at_ms" => DateTime.to_unix(~U[2026-07-11 00:00:40Z], :millisecond)
      }),
      record(boot_id, 3, "lifecycle", ~U[2026-07-11 00:01:02Z], %{"event" => "dispatch", "boundary" => "point", "ticket" => "941"})
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file]) end)
    path
  end

  defp record(boot_id, sequence, kind, timestamp, attributes) do
    %{
      schema_version: 2,
      kind: kind,
      timestamp: DateTime.to_iso8601(timestamp),
      recorded_at: DateTime.to_iso8601(timestamp),
      boot_id: boot_id,
      sequence: sequence,
      record_id: "#{boot_id}:#{sequence}",
      attributes: Map.put(attributes, "event_key", "route-#{boot_id}-#{sequence}")
    }
  end

  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  defp reset_env(key, nil), do: Application.delete_env(:aiur, key)
  defp reset_env(key, value), do: Application.put_env(:aiur, key, value)
end
