defmodule Aiur.AgentControlCapacityBindingTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  test "status and Analytics derive cap facts from the same unsaturated daemon report" do
    capacity = %{
      occupied: 6,
      max: 20,
      effective: 9,
      configured: 16,
      available: 3,
      queued_demand?: true,
      session_override?: true,
      active: 6,
      reserved_paused: 0,
      capacity_hold: nil
    }

    polling = %{}
    orchestrator = {:global, {__MODULE__, make_ref()}}
    publisher = start_supervised!({Agent, fn -> :ok end})
    {:global, name} = orchestrator
    :yes = :global.register_name(name, publisher)
    on_exit(fn -> SnapshotStore.forget(orchestrator) end)

    :ok =
      SnapshotStore.publish(orchestrator, %{
        capacity: capacity,
        polling: polling,
        global_pause: %{globally_paused: false, paused_at: nil, source: nil}
      })

    snapshot = %{
      statuses: [],
      capacity: capacity,
      polling: polling,
      global_pause: %{globally_paused: false, paused_at: nil, source: nil}
    }

    output = capture_io(fn -> AgentControlCLI.status(fleet_view: {:ok, snapshot, %{status: :current}}) end)
    assert output =~ "AGENTS 6/20 (binding: awaiting dispatch; ceiling: AIMD envelope 9)"

    telemetry_fixture = Path.expand("../../fixtures/run_telemetry", __DIR__)
    telemetry_root = Aiur.TestSupport.tmp_root!("capacity-binding-analytics")
    telemetry_file = Path.join(telemetry_root, "telemetry.ndjson")
    File.mkdir_p!(telemetry_root)

    File.write!(
      telemetry_file,
      Jason.encode!(%{
        schema_version: 1,
        kind: "resource",
        timestamp: "2026-10-12T00:00:00Z",
        recorded_at: "2026-10-12T00:00:00Z",
        boot_id: "capacity-binding-test",
        sequence: 1,
        record_id: "capacity-binding-test:1",
        attributes: %{actor: "ticket:4175", actor_type: "agent", ticket: "4175", availability: "measured", cpu_percent: 1.0, rss_bytes: 100_000}
      }) <> "\n"
    )

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(telemetry_root) end)
    assert {:ok, model} = Presenter.load(telemetry_file: [telemetry_fixture, telemetry_file], orchestrator: orchestrator)
    assert model.cap == 9
    assert model.cap_binding == "awaiting dispatch"
    assert Presenter.cap_label(model) == "9 cap (binding: awaiting dispatch, session 20, configured 16)"
  end
end
