defmodule AiurWeb.DashboardLive.FinancialAccessTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes

  alias AiurWeb.DashboardLiveSupport.OrchestratorStubs.CountingOrchestrator
  alias AiurWeb.OperatorControlCenter.PayloadLoader

  @endpoint AiurWeb.Endpoint

  test "unconfigured dashboard authentication refuses the dashboard route with its cause" do
    orchestrator_name = Module.concat(__MODULE__, :FinancialBoundaryOrchestrator)
    sentinel = "acct-plan-quota-reset-financial-sentinel"
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    start_supervised!(
      {CountingOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{
           input_tokens: sentinel,
           output_tokens: sentinel,
           total_tokens: sentinel,
           seconds_running: 41
         },
         rate_limits: %{
           provider: sentinel,
           plan: sentinel,
           quota: sentinel,
           reset_at: sentinel,
           last_known_good: sentinel
         }
       }}
    )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      dashboard_auth_required: false
    )

    response = get(Phoenix.ConnTest.build_conn(), "/")

    assert response.status == 503
    assert response.resp_body =~ "Dashboard authentication is not configured"
    refute response.resp_body =~ sentinel
  end

  test "a revoked financial session renders a locked capability without leaking financial sentinels" do
    orchestrator_name = Module.concat(__MODULE__, :RevokedFinancialBoundaryOrchestrator)
    sentinel = "acct-plan-quota-reset-financial-sentinel"
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "boundary-secret")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    start_supervised!(
      {CountingOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{
           input_tokens: sentinel,
           output_tokens: sentinel,
           total_tokens: sentinel,
           seconds_running: 41
         },
         rate_limits: %{
           provider: sentinel,
           plan: sentinel,
           quota: sentinel,
           reset_at: sentinel,
           last_known_good: sentinel
         }
       }}
    )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      dashboard_auth_required: true,
      dashboard_writable: false
    )

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:boundary-secret"))

    test_process = self()

    log =
      capture_log(fn ->
        {:ok, view, _html} = live(conn, "/units")
        socket = :sys.get_state(view.pid).socket
        assert socket.assigns.financial_data_capability.state == :authorized

        # Rotate credentials so the outstanding session marker becomes stale.
        System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-boundary-secret")
        refute Map.has_key?(PayloadLoader.load(:fresh), :units_status_snapshot)

        {:ok, redirected, redirected_html} = live_redirect(view, to: "/commands")
        send(test_process, {:revoked_financial, redirected})
        assert redirected_html =~ "Commands"
      end)

    assert_receive {:revoked_financial, redirected}, 2_000
    socket = :sys.get_state(redirected.pid).socket

    assert socket.assigns.financial_data_capability.state == :locked
    assert socket.assigns.payload.fleet.agent_totals == %{seconds_running: 41}
    refute Map.has_key?(socket.assigns.payload.fleet, :rate_limits)
    Aiur.TestSupport.refute_leak(socket, sentinel)
    refute render(redirected) =~ sentinel
    refute log =~ sentinel
  end

  test "configured Basic Auth survives the LiveView socket boundary as private financial authority" do
    orchestrator_name = Module.concat(__MODULE__, :AuthenticatedFinancialBoundaryOrchestrator)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "socket-bound-secret")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      dashboard_auth_required: true,
      dashboard_writable: false
    )

    unauthenticated = get(Phoenix.ConnTest.build_conn(), "/")
    assert response(unauthenticated, 401) == "Unauthorized"

    conn =
      build_conn()
      |> Plug.Conn.put_req_header(
        "authorization",
        "Basic " <> Base.encode64("operator:socket-bound-secret")
      )

    assert {:ok, view, _html} = live(conn, "/units")
    socket = :sys.get_state(view.pid).socket

    assert socket.assigns.financial_data_capability == %{state: :authorized, version: 1}
    assert %AiurWeb.FinancialDataAccess.Context{} = socket.private.aiur_financial_data_access
    Aiur.TestSupport.refute_leak(socket.private.aiur_financial_data_access, "operator")
    Aiur.TestSupport.refute_leak(socket.private.aiur_financial_data_access, "socket-bound-secret")
    assert socket.assigns.writable == false
  end

  test "authorized usage and cost panel opens the capability gate without leaking a locked state" do
    orchestrator_name = Module.concat(__MODULE__, :AuthorizedUsageOrchestrator)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "usage-panel-secret")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      dashboard_auth_required: true,
      dashboard_writable: false
    )

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:usage-panel-secret"))

    assert {:ok, view, _html} = live(conn, "/units")
    socket = :sys.get_state(view.pid).socket

    # The gate opens: the panel is no longer locked. With no active run scope it
    # is a truthful empty state, never a synthetic zero total.
    assert socket.assigns.financial_data_capability.state == :authorized
    refute socket.assigns.usage_summary.state == :locked
    assert socket.assigns.usage_summary.state in [:empty, :ready, :partial, :stale, :unavailable]
  end
end
