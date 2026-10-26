defmodule AiurWeb.AnalyticsPartialCoverageTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.RunTelemetry
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.Endpoint

  @endpoint Endpoint
  @reason "partial: 7 of 7 occupied slots not seen as active"

  setup context do
    previous_telemetry = Application.get_env(:aiur, :analytics_telemetry_file)
    previous_endpoint = Application.get_env(:aiur, Endpoint)

    endpoint_config =
      Keyword.merge(previous_endpoint || [],
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        orchestrator: {:global, {__MODULE__, context.test}}
      )

    Application.put_env(:aiur, Endpoint, endpoint_config)
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      reset_env(:analytics_telemetry_file, previous_telemetry)
      reset_env(Endpoint, previous_endpoint)
    end)

    :ok
  end

  # #4852: the daemon saw 7 occupied slots but no agent was sampled, so every
  # agent-derived figure on the page is unknown rather than a confident zero.
  test "an unsampled occupied fleet shows unknown utilization and no flat-zero concurrency chart" do
    Application.put_env(:aiur, :analytics_telemetry_file, occupied_fixture!(RunTelemetry.boot_id(), 7))

    {:ok, view, _html} = live(build_conn(), "/analytics")
    LiveViewAsync.render_when_complete(view)

    tile = view |> element(".an-kpi", "Mean utilization") |> render()
    assert tile =~ ~s(<span class="an-kpi-val">unknown</span>)
    assert tile =~ @reason
    refute tile =~ ~s(<span class="an-kpi-val">0%</span>)

    assert view |> element("#analytics-concurrency-coverage") |> render() =~ @reason
    chart = view |> element("#analytics-concurrency-chart") |> render()
    assert chart =~ "Concurrency unknown: no active agents were sampled."
    refute chart =~ "<svg"
  end

  test "no capacity or agent samples show unknown on both cards and the chart" do
    Application.put_env(:aiur, :analytics_telemetry_file, empty_window_fixture!(RunTelemetry.boot_id()))

    {:ok, view, _html} = live(build_conn(), "/analytics")
    LiveViewAsync.render_when_complete(view)

    utilization = view |> element(".an-kpi", "Mean utilization") |> render()
    peak = view |> element(".an-kpi", "Peak concurrency") |> render()

    assert utilization =~ ~s(<span class="an-kpi-val">unknown</span>)
    assert peak =~ ~s(<span class="an-kpi-val">unknown</span>)
    refute utilization =~ ~s(<span class="an-kpi-val">0%)
    refute peak =~ ~s(<span class="an-kpi-val">0</span>)
    assert utilization =~ "no fleet-capacity or agent samples in this window"
    assert peak =~ "no fleet-capacity or agent samples in this window"
    assert utilization =~ "of 4 cores"
    assert peak =~ "of 4 cores"

    assert view |> element("#analytics-concurrency-chart") |> render() =~
             "Concurrency unknown: no fleet-capacity or agent samples in this window."
  end

  defp empty_window_fixture!(boot_id) do
    root = Path.join(System.tmp_dir!(), "aiur-analytics-empty-window-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")

    records = [
      record(boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], %{"event" => "restart", "boundary" => "point"}),
      record(boot_id, 2, "lifecycle", ~U[2026-07-11 00:01:02Z], %{"event" => "dispatch", "boundary" => "point", "ticket" => "941"})
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file]) end)
    path
  end

  defp occupied_fixture!(boot_id, occupied) do
    root = Path.join(System.tmp_dir!(), "aiur-analytics-coverage-#{System.unique_integer([:positive])}")
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
      attributes: Map.put(attributes, "event_key", "#{kind}-#{boot_id}-#{sequence}")
    }
  end

  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  defp reset_env(key, nil), do: Application.delete_env(:aiur, key)
  defp reset_env(key, value), do: Application.put_env(:aiur, key, value)
end
