defmodule AiurWeb.DashboardProjectionTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport, only: [build_conn: 0, start_test_endpoint: 1]

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{SnapshotStore, StatusReport}
  alias AiurWeb.ObservabilityPubSub

  @endpoint AiurWeb.Endpoint

  test "refreshes a dashboard only after an orchestrator projection completes" do
    orchestrator_name = Module.concat(__MODULE__, :ProjectedDashboardOrchestrator)
    test_pid = self()
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      SnapshotStore.forget(orchestrator_name)
    end)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 5,
      control_center_cache: false,
      control_center_reload_timer: fn view_pid, message, _delay_ms ->
        send(test_pid, {:reload_scheduled, view_pid, message})
        make_ref()
      end
    )

    :ok = ObservabilityPubSub.subscribe()
    {:ok, view, _initial_html} = live(build_conn(), "/commands")
    {:reload_scheduled, view_pid, :reload_payload} = receive_barrier({:reload_scheduled, _view_pid, :reload_payload})
    assert view_pid == view.pid
    send(view.pid, :reload_payload)
    :sys.get_state(view.pid)
    prior_payload_load = :sys.get_state(view.pid).socket.assigns.payload_loaded_at_ms

    ready_state = :sys.replace_state(pid, &%{&1 | snapshot_ready?: true})
    projected_snapshot = StatusReport.snapshot_payload(ready_state)
    :ok = SnapshotStore.publish(orchestrator_name, projected_snapshot, ready_state)

    {:observability_updated, _event_id} = receive_barrier({:observability_updated, _event_id})
    assert {:current, _, _} = SnapshotStore.read(orchestrator_name, 1_000)
    {:reload_scheduled, reload_pid, :reload_payload} = receive_barrier({:reload_scheduled, _reload_pid, :reload_payload})
    assert reload_pid == view.pid

    send(view.pid, :reload_payload)
    reloaded_state = :sys.get_state(view.pid)
    assert reloaded_state.socket.assigns.payload_loaded_at_ms > prior_payload_load
  end
end
