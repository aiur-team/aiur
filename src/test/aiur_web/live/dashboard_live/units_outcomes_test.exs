defmodule AiurWeb.DashboardLive.UnitsOutcomesTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.ControlFixtures
  import AiurWeb.DashboardLiveSupport.DecisionFixtures

  alias Aiur.RecentMerge
  alias AiurWeb.DashboardLiveSupport.OrchestratorStubs.CountingOrchestrator
  alias AiurWeb.EndpointConfig
  alias AiurWeb.Presenter

  @endpoint AiurWeb.Endpoint

  test "keeps durable outcomes off the Units page during a snapshot outage" do
    history = [
      history_entry("dec-human", :human_operator, "Executor", "<script>alert('decision')</script>"),
      history_entry("dec-supervisor", :supervising_agent, "Supervising agent", "Approve the fallback?")
    ]

    assert {:ok, merge} =
             RecentMerge.from_github_event(merged_event(),
               live?: true,
               run_id: "run-observer-123456789",
               now: ~U[2026-07-12 18:01:00Z]
             )

    telemetry_path = Path.expand("../../../fixtures/run_telemetry/session-a/telemetry.ndjson", __DIR__)
    assert File.regular?(telemetry_path), telemetry_path

    payload =
      Presenter.state_payload(Module.concat(__MODULE__, :MissingHistoryOrchestrator), 5,
        decision_history_fun: fn -> history end,
        recent_merge_snapshot_fun: fn ->
          %{
            merges: [merge],
            health: :writable,
            reconciliation: %{status: :partial, partial?: true, pages_fetched: 5}
          }
        end,
        telemetry_file_fun: fn -> telemetry_path end
      )

    assert payload.analytics.available?, inspect(payload.analytics)
    html = render_payload(payload)

    assert html =~ "orchestrator_unavailable"
    refute html =~ "Merged this run"
    refute html =~ "from the current run"
    refute html =~ "Command history"
    refute html =~ "Executor"
    refute html =~ "Supervising agent"
    refute html =~ "&lt;script&gt;alert"
    refute html =~ "<script>alert"
    refute html =~ "Recent repository merges"
    refute html =~ "Observed live"
    refute html =~ "Observer run run-observer"
    refute html =~ "No ticket attribution"
    refute html =~ "5-page cap"
    refute html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute html =~ "<img src=x"
    assert html =~ ~s(href="/analytics")
    refute html =~ "Open analytics report"
  end

  test "bounds each payload signal burst across open dashboards" do
    orchestrator_name = Module.concat(__MODULE__, :CountingOrchestratorInstance)
    test_process = self()

    start_supervised!(
      {CountingOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}
    )

    reload_timer = fn destination, message, delay_ms ->
      send(test_process, {:payload_reload_scheduled, destination, message, delay_ms})
      make_ref()
    end

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_reload_timer: reload_timer
    )

    {:ok, view, _html} = live(build_conn(), "/units")
    {:ok, second_view, _html} = live(build_conn(), "/units")
    views = [view, second_view]
    cache = EndpointConfig.get(:control_center_cache)

    assert_bounded_reload_burst(views, List.duplicate(:observability_updated, 25), cache, orchestrator_name)

    decision_messages =
      Enum.map(1..25, fn version -> {:decision_changed, "decision-#{version}", version} end)

    assert_bounded_reload_burst(views, decision_messages, cache, orchestrator_name)
    assert_bounded_reload_burst(views, List.duplicate(:decision_metrics_changed, 25), cache, orchestrator_name)

    membership_messages =
      List.duplicate({:current_run_membership_changed, %{generation: 2}}, 25)

    assert_bounded_reload_burst(views, membership_messages, cache, orchestrator_name, false)
  end

  describe "current-run outcomes (DASH-034)" do
    test "does not render current-run outcomes on the Units destination" do
      view = start_outcomes_dashboard()
      html = push_outcomes(view, healthy_outcomes_snapshot(numbers: [42, 7]))

      refute html =~ "Finished this run"
      refute html =~ "Current run"
      refute html =~ "Repository merges from this run"
      refute html =~ ~s(id="current-run-outcomes")
      refute html =~ "PR #42"
    end

    test "coalesces a burst of outcome updates into a single scheduled flush" do
      view = start_outcomes_dashboard()

      for _ <- 1..25 do
        send(view.pid, {:current_run_outcome_snapshot_changed, healthy_outcomes_snapshot(numbers: [1])})
      end

      :sys.get_state(view.pid)

      assert_receive {:outcomes_flush_scheduled, pid, :flush_current_run_outcomes, delay_ms}, 0
      assert pid == view.pid
      assert delay_ms > 0
      refute_receive {:outcomes_flush_scheduled, _pid, :flush_current_run_outcomes, _delay}, 0

      send(view.pid, :flush_current_run_outcomes)
      refute render(view) =~ ~s(id="current-run-outcomes")
    end
  end
end
