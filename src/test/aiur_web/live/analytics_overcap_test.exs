# Cohesive cap/coverage and pressure-table regressions share LiveView endpoint and telemetry setup.
defmodule AiurWeb.AnalyticsOvercapTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.RunTelemetry
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.Endpoint

  @endpoint Endpoint

  setup context do
    previous_telemetry = Application.get_env(:aiur, :analytics_telemetry_file)
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    orchestrator = {:global, {__MODULE__, context.test}}
    # A live publisher must hold the orchestrator name, or the read is a retained-cache state.
    publisher = start_supervised!({Agent, fn -> :ok end})
    :yes = :global.register_name({__MODULE__, context.test}, publisher)

    SnapshotStore.publish(orchestrator, %{
      capacity: %{effective: 16, max: 20, configured: 16, occupied: 17, available: 0, queued_demand?: true}
    })

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
    root = Path.join(System.tmp_dir!(), "aiur-analytics-overcap-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      SnapshotStore.forget(orchestrator)
      reset_env(:analytics_telemetry_file, previous_telemetry)
      reset_env(Endpoint, previous_endpoint)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  # The sample's own effective (20) differs from the live snapshot's (16), so the cap must come from the snapshot.
  test "names the overage when live occupancy exceeds the effective cap", %{root: root} do
    Application.put_env(:aiur, :analytics_telemetry_file, telemetry_fixture!(root, RunTelemetry.boot_id()))

    {:ok, view, _html} = live(build_conn(), "/analytics")
    html = LiveViewAsync.render_when_complete(view)

    assert html =~ ~r/17 now, 1 over cap \/ 16 cap \(.*session 20\)/
    assert html =~ "partial: 2 of 17 occupied slots not seen as active"
  end

  @tag analytics_capacity: %{effective: 16, max: 20, configured: 16, occupied: 15, available: 1, queued_demand?: true}
  test "renders exact source-gated values and retained-run wording in the pressure table" do
    Application.put_env(:aiur, :analytics_telemetry_file, pressure_fixture!(RunTelemetry.boot_id(), {15, 20, 16}))
    {:ok, view, _html} = live(build_conn(), "/analytics")
    html = LiveViewAsync.render_when_complete(view)

    assert html =~ ~s(<table id="analytics-pressure-table">)
    assert html =~ ~r/15 now \/ 16 cap \(.*session 20\)/
    refute html =~ "(fleet)"
    assert html =~ "16 / 20 / 16"
    assert html =~ ">2<" and html =~ "2 / 8" and html =~ "189s"
    assert html =~ "2026-07-11T00:00:40.000Z" and html =~ "2026-07-11T00:00:55.000Z"
    assert html =~ ">current<" and html =~ ">measured<"

    # A retained prior run's current fleet sample is history, never "now".
    Application.put_env(:aiur, :analytics_telemetry_file, pressure_fixture!("boot-before-restart", {15, 20, 16}))
    {:ok, retained_view, _html} = live(build_conn(), "/analytics")
    retained = LiveViewAsync.render_when_complete(retained_view)
    assert retained =~ ~s(data-source-kind="retained") and retained =~ ~r/an-kpi-sub">\d+ at run end \/ 16 cap/
    refute retained =~ " now /"
  end

  test "renders unavailable pressure evidence as em-dash, never a confident zero" do
    boot_id = RunTelemetry.boot_id()
    Application.put_env(:aiur, :analytics_telemetry_file, pressure_fixture_with_gap!(boot_id))
    {:ok, view, _html} = live(build_conn(), "/analytics")
    html = LiveViewAsync.render_when_complete(view)

    # The gap row's degraded build must render its missing wait as "—", and a
    # missing fleet figure must never be coerced into a confident "0".
    assert html =~ "—" and html =~ "occupancy unavailable"
    assert html =~ ">degraded<"
    refute html =~ ">0s<"
    # The measured row still carries its exact values (not blurred by the gap).
    assert html =~ "13" and not (html =~ "13 now /")
    assert html =~ "189s"
  end

  defp pressure_fixture_with_gap!(boot_id) do
    root = Path.join(System.tmp_dir!(), "aiur-analytics-pressure-gap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")
    timestamp = ~U[2026-07-11 00:01:01Z]
    gap_timestamp = ~U[2026-07-11 00:11:01Z]

    records = [
      record(boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], %{"event" => "restart", "boundary" => "point", "event_key" => "route-1"}),
      agent_resource_records(boot_id, 20, 13, timestamp),
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
      record(boot_id, 4, "lifecycle", ~U[2026-07-11 00:01:02Z], %{"event" => "dispatch", "boundary" => "point", "event_key" => "route-4", "ticket" => "941"})
    ]

    File.write!(path, Enum.map_join(List.flatten(records), "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file]) end)
    path
  end

  defp pressure_fixture!(boot_id, capacity) do
    root = Path.join(System.tmp_dir!(), "aiur-analytics-pressure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")
    timestamp = ~U[2026-07-11 00:01:01Z]

    records = [
      record(boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], %{"event" => "restart", "boundary" => "point", "event_key" => "route-1"}),
      agent_resource_records(boot_id, 20, elem(capacity, 0), timestamp),
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
          "fleet_agents_occupied" => elem(capacity, 0),
          "fleet_agents_configured" => 16,
          "fleet_agents_max" => elem(capacity, 1),
          "fleet_agents_effective" => elem(capacity, 2),
          "fleet_capacity_observed_at_ms" => DateTime.to_unix(~U[2026-07-11 00:00:40Z], :millisecond),
          "build_gate_status" => "measured",
          "build_gate_capacity" => 2,
          "build_gate_observed_at_ms" => DateTime.to_unix(~U[2026-07-11 00:00:55Z], :millisecond),
          "build_gate_active" => 2,
          "build_gate_queued" => 8,
          "build_queue_oldest_wait_seconds" => 189
        }
      },
      record(boot_id, 3, "lifecycle", ~U[2026-07-11 00:01:02Z], %{"event" => "dispatch", "boundary" => "point", "event_key" => "route-3", "ticket" => "941"})
    ]

    File.write!(path, Enum.map_join(List.flatten(records), "\n", &Jason.encode!/1) <> "\n")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root, unset: [:analytics_telemetry_file]) end)
    path
  end

  defp telemetry_fixture!(root, boot_id) do
    File.mkdir_p!(root)
    path = Path.join(root, "telemetry.ndjson")

    sample = %{
      "actor" => "_daemon",
      "actor_type" => "daemon",
      "availability" => "unavailable",
      "fleet_capacity_status" => "current",
      "fleet_agents_occupied" => 17,
      "fleet_agents_configured" => 16,
      "fleet_agents_max" => 20,
      "fleet_agents_effective" => 20,
      "fleet_capacity_observed_at_ms" => DateTime.to_unix(~U[2026-07-11 00:00:40Z], :millisecond)
    }

    records = [
      record(boot_id, 1, "restart", ~U[2026-07-11 00:01:00Z], %{"event" => "restart", "boundary" => "point", "event_key" => "route-1"}),
      record(boot_id, 2, "resource", ~U[2026-07-11 00:01:01Z], sample),
      agent_resource_records(boot_id, 4, 15, ~U[2026-07-11 00:01:01Z]),
      record(boot_id, 3, "lifecycle", ~U[2026-07-11 00:01:02Z], %{"event" => "dispatch", "boundary" => "point", "event_key" => "route-3", "ticket" => "941"})
    ]

    File.write!(path, Enum.map_join(List.flatten(records), "\n", &Jason.encode!/1) <> "\n")
    path
  end

  defp agent_resource_records(boot_id, first_sequence, count, timestamp) do
    for offset <- 0..(count - 1) do
      sequence = first_sequence + offset
      ticket = 900 + offset

      record(boot_id, sequence, "resource", timestamp, %{
        "actor" => "ticket:#{ticket}",
        "actor_type" => "agent",
        "ticket" => "#{ticket}",
        "availability" => "measured",
        "cpu_percent" => 1.0,
        "rss_bytes" => 1
      })
    end
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
      attributes: attributes
    }
  end

  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  defp reset_env(key, nil), do: Application.delete_env(:aiur, key)
  defp reset_env(key, value), do: Application.put_env(:aiur, key, value)
end
