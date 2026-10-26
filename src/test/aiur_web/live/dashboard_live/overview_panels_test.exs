defmodule AiurWeb.DashboardLive.OverviewPanelsTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures

  @endpoint AiurWeb.Endpoint

  test "membership provider failure renders unavailable counts instead of healthy zeros" do
    orchestrator_name = Module.concat(__MODULE__, :UnavailableUnitsOrchestrator)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> raise "membership unavailable" end,
      units_activity_fun: fn -> exit(:activity_unavailable) end
    )

    {:ok, _view, html} = live(build_conn(), "/units")

    assert html =~ "No active units"
    refute html =~ "Observed and selected-scope counts unavailable"
    assert html =~ "Count unavailable"
    assert html =~ ~s(aria-label="Count unavailable")
    refute html =~ "0 observed"
    refute html =~ "0 in selected scope"
  end

  test "the Agents panel titles and counts itself above the filter row" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :AgentsHeaderOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot([]) end
    )

    {:ok, _view, html} = live(build_conn(), "/units")

    # The same title/count pair the APIs and Models panels use.
    assert html =~ ~s(<span class="rs-group-title" id="units-title">Units</span>)
    assert html =~ ~s(<span class="rs-group-count">1 unit</span>)

    [_before, after_header] = String.split(html, "units-title", parts: 2)
    assert after_header =~ "units-filter-list"
  end
end
