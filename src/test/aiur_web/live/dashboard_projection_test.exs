defmodule AiurWeb.DashboardProjectionTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport, only: [build_conn: 0, start_test_endpoint: 1, eventually: 2]

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{SnapshotStore, StatusReport}
  alias Aiur.TestSupport.RefreshTrace
  alias AiurWeb.ObservabilityPubSub

  @endpoint AiurWeb.Endpoint

  test "refreshes a dashboard only after an orchestrator projection completes" do
    orchestrator_name = Module.concat(__MODULE__, :ProjectedDashboardOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      SnapshotStore.forget(orchestrator_name)
    end)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5, control_center_cache: false)
    :ok = ObservabilityPubSub.subscribe()
    {:ok, view, _initial_html} = live(build_conn(), "/commands")
    assert eventually(fn -> not :sys.get_state(view.pid).socket.assigns.payload_reload_scheduled? end, 100)
    prior_payload_load = :sys.get_state(view.pid).socket.assigns.payload_loaded_at_ms

    :sys.replace_state(pid, &%{&1 | snapshot_ready?: true})
    assert RefreshTrace.count(fn -> :ok = StatusReport.notify_dashboard(:sys.get_state(pid)) end) == 0

    assert eventually(fn -> assert_receive({:observability_updated, _event_id}, 1_000) && match?({:current, _, _}, SnapshotStore.read(orchestrator_name, 1_000)) end, 100)
    assert eventually(fn -> :sys.get_state(view.pid).socket.assigns.payload_loaded_at_ms > prior_payload_load end, 100)
  end
end
