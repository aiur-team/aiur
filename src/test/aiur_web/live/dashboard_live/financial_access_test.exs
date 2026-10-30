defmodule AiurWeb.DashboardLive.FinancialAccessTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import AiurWeb.DashboardLiveSupport

  alias AiurWeb.DashboardLiveSupport.OrchestratorStubs.CountingOrchestrator

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
end
