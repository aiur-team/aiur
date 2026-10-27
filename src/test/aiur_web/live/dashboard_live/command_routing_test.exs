defmodule AiurWeb.DashboardLive.CommandRoutingTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.DecisionStore

  @endpoint AiurWeb.Endpoint

  test "routing filters are shareable and refresh after durable escalation" do
    orchestrator = Module.concat(__MODULE__, :Orchestrator)
    store_name = Module.concat(__MODULE__, :Store)
    start_counting_orchestrator(orchestrator)
    store = start_decision_store(store_name, fn _, _ -> {:ok, %{status: :accepted}} end)
    now = DateTime.utc_now()
    human = request_queue_decision(store, "human", "6411", now: DateTime.add(now, -600, :second))
    both = request_queue_decision(store, "both", "6411")
    executor = request_queue_decision(store, "executor", "6411")
    legacy = request_queue_decision(store, "legacy", "6411")
    route(store, human, :with_human, DateTime.add(now, -300, :second))
    route(store, both, :with_both, now)
    route(store, executor, :with_executor, now)
    start_test_endpoint(orchestrator: orchestrator, decision_store: store_name)

    {:ok, view, html} = live(build_conn(), "/commands?route=needs_you")
    assert has_element?(view, "#decision-#{human.decision_id}")
    assert has_element?(view, "#decision-#{both.decision_id}")
    refute has_element?(view, "#decision-#{executor.decision_id}")
    refute has_element?(view, "#decision-#{legacy.decision_id}")
    assert html =~ "Needs you and Executor"
    assert html =~ "needs you since 5 min ago"
    assert html =~ "asked 10m ago"
    assert has_element?(view, "#decisions-banner", "2 Commands need you")

    view |> element("button[phx-value-filter=with_executor]") |> render_click()
    assert_patch(view, "/commands?route=with_executor")
    assert has_element?(view, "#decision-#{executor.decision_id}", "With Executor")
    refute has_element?(view, "#decision-#{human.decision_id}")

    assert {:ok, _} =
             DecisionStore.record_command_fact(
               executor.decision_id,
               :escalated,
               %{at: now, cause: :executor_ack_timeout, detail: "Executor did not acknowledge", actor: %{kind: :system, id: "routing"}}, server: store)

    # Navigate through the same filter control after the store fact; no reload.
    view |> element("button[phx-value-filter=needs_you]") |> render_click()
    assert has_element?(view, "#decision-#{executor.decision_id}", "Needs you")

    view |> element("button[phx-value-filter=all]") |> render_click()
    assert has_element?(view, "#decision-#{legacy.decision_id} [data-route-state=unknown]", "Routing…")
    view |> element("button[phx-value-filter=from_executor]") |> render_click()
    assert_patch(view, "/commands?route=from_executor")
    assert has_element?(view, ".empty-state", "No Commands match this filter.")
  end

  defp route(store, decision, state, now) do
    policy = %{with_human: :human_only, with_both: :simultaneous, with_executor: :executor_first}[state]
    assert {:ok, _} = DecisionStore.record_command_fact(decision.decision_id, :routed, %{policy: policy, state: state, at: now, cause: nil, actor: %{kind: :system, id: "routing"}}, server: store)
  end
end
