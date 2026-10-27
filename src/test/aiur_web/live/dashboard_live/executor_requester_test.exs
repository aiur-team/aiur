defmodule AiurWeb.DashboardLive.ExecutorRequesterTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.DecisionStore
  alias AiurWeb.OperatorControlCenter.DecisionProvider

  @endpoint AiurWeb.Endpoint

  setup do
    store_name = Module.concat(__MODULE__, :Store)
    orchestrator = Module.concat(__MODULE__, :Orchestrator)
    store = start_decision_store(store_name, fn _decision, _opts -> {:error, :unused} end)
    start_counting_orchestrator(orchestrator)
    start_test_endpoint(orchestrator: orchestrator, decision_store: store_name, control_center_cache: false)
    %{store: store}
  end

  test "requester filter selects Executor rows within the page and keeps the underlying cursor", %{store: store} do
    now = DateTime.utc_now()
    executor = request!(store, "executor", now)
    worker = request!(store, "979", DateTime.add(now, 1, :second))
    opts = [decision_store: store, decision_metrics: make_ref()]
    assert {:ok, page} = DecisionProvider.list(%{"requester" => "executor", "limit" => 2}, opts)
    assert Enum.map(page.decisions, & &1.decision_id) == [executor.decision_id]
    assert page.requester_page == %{count: 1, partial?: false}
    assert page.pagination.total == nil
    assert {:ok, first} = DecisionProvider.list(%{"requester" => "executor", "limit" => 1}, opts)
    assert first.decisions == []
    assert first.requester_page.count == 0
    assert is_binary(first.pagination.next_cursor)
    assert {:ok, second} = DecisionProvider.list(%{"requester" => "executor", "limit" => 1, "cursor" => first.pagination.next_cursor}, opts)
    assert Enum.map(second.decisions, & &1.decision_id) == [executor.decision_id]
    assert {:ok, all} = DecisionProvider.list(%{"limit" => 2}, opts)
    assert Enum.map(all.decisions, & &1.decision_id) == [worker.decision_id, executor.decision_id]
    assert {:error, {:invalid_query, {:requester, :invalid_value}}} = DecisionProvider.list(%{"requester" => "other"}, opts)
  end

  test "filter link and detail navigation preserve requester and show badges instead of a synthetic ticket", %{store: store} do
    executor = request!(store, "executor", DateTime.utc_now())
    worker = request!(store, "979", DateTime.utc_now())
    {:ok, view, _html} = live(build_conn(), "/commands")
    assert has_element?(view, "#decision-#{worker.decision_id} .ticket-id", "#979 · agent-979")
    refute has_element?(view, "#decision-#{worker.decision_id} .requester-badge")
    view |> element("a.filter-chip", "From Executor") |> render_click()
    assert_patch(view, "/commands?requester=executor")
    refute has_element?(view, "#decision-#{worker.decision_id}")
    assert has_element?(view, "[data-requester-count]", "1 from Executor on this retained page (not a total).")
    assert has_element?(view, "#decision-#{executor.decision_id} .ticket-id", "Executor")
    assert has_element?(view, "#decision-#{executor.decision_id} .requester-badge", "From Executor")
    refute render(view) =~ "#executor"
    view |> element("#decision-#{executor.decision_id} .decision-card-head") |> render_click()
    assert_patch(view, "/commands/#{executor.decision_id}?requester=executor")
    refute has_element?(view, "#decision-#{worker.decision_id}")
    assert has_element?(view, "[data-requester-count]", "1 from Executor on this retained page")
    send(view.pid, :reload_payload)
    render(view)
    refute has_element?(view, "#decision-#{worker.decision_id}")
    assert has_element?(view, "[data-requester-count]", "1 from Executor on this retained page")
    assert has_element?(view, "#decision-detail-#{executor.decision_id} header .requester-line", "Executor")
    assert has_element?(view, "#decision-detail-#{executor.decision_id} header .requester-badge", "From Executor")
    view |> element("#decision-detail-#{executor.decision_id} a", "Collapse details") |> render_click()
    assert_patch(view, "/commands?requester=executor")
    view |> element("button[phx-value-filter=open]") |> render_click()
    assert_patch(view, "/commands?filter=open&requester=executor")
    render_submit(view, "search-commands", %{"search" => ""})
    assert_patch(view, "/commands?requester=executor")
    view |> element("button[phx-value-filter=open]") |> render_click()
    assert_patch(view, "/commands?filter=open&requester=executor")
    view |> element("a.filter-chip", "From Executor") |> render_click()
    assert_patch(view, "/commands?filter=open")
    assert has_element?(view, "#decision-#{worker.decision_id}")
  end

  test "partial and unavailable filtered pages never render a zero count or an empty claim", %{store: store} do
    request!(store, "979", DateTime.utc_now())
    :sys.replace_state(store, &Map.put(&1, :health, {:corrupt, 2, :invalid_record}))
    opts = [decision_store: store, decision_metrics: make_ref()]
    assert {:ok, page} = DecisionProvider.list(%{"requester" => "executor"}, opts)
    assert page.requester_page == %{count: nil, partial?: true}
    {:ok, view, html} = live(build_conn(), "/commands?requester=executor")
    assert has_element?(view, "[data-requester-count]", "Executor count unknown")
    assert html =~ "Showing a partial list of Commands."
    refute html =~ "0 from Executor"
    refute html =~ "No Commands from the Executor"
    assert {:ok, unavailable} = DecisionProvider.list(%{"requester" => "executor"}, decision_store: make_ref())
    assert unavailable.requester_page == %{count: nil, partial?: true}
  end

  test "empty requester state names the retained page and offers the next page", %{store: store} do
    for i <- 1..26, do: request!(store, "#{i}", DateTime.add(DateTime.utc_now(), i, :second))
    {:ok, view, _html} = live(build_conn(), "/commands?requester=executor")
    assert has_element?(view, ".empty-state", "No Commands from the Executor on this retained page.")
    assert has_element?(view, "[data-requester-count]", "0 from Executor on this retained page")
    view |> element("a", "Next retained page") |> render_click()
    path = assert_patch(view)
    assert URI.decode_query(URI.parse(path).query)["requester"] == "executor"
    assert URI.decode_query(URI.parse(path).query)["cursor"] != nil
    refute has_element?(view, "a", "Next retained page")
  end

  defp request!(store, ticket, now) do
    attribution = if ticket == "executor", do: [requester: %{kind: :executor, executor_id: "operator"}, origin: :executor_cli], else: []

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{"question" => "Choose scope for #{ticket}?", "source_id" => "requester-#{ticket}", "blocking" => false, "reversibility" => "reversible"},
               [ticket: %{identifier: ticket}, source: %{agent_id: "agent-#{ticket}", session_id: "session-#{ticket}", event_id: "event-#{ticket}"}, now: now] ++ attribution,
               store
             )

    decision
  end
end
