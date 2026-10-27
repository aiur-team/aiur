defmodule AiurWeb.DashboardLive.CommandHistoryTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.DecisionStore

  @endpoint AiurWeb.Endpoint

  test "paginates Command history ten rows at a time instead of rendering every resolved Command" do
    orchestrator_name = Module.concat(__MODULE__, :BoundedHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :BoundedHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 507}}}
      end)

    start_counting_orchestrator(orchestrator_name)

    for index <- 1..25 do
      decision = request_dashboard_decision(store, "history-#{index}")

      assert {:ok, %{status: :accepted}} =
               DecisionStore.answer(
                 decision.decision_id,
                 %{
                   "idempotency_key" => "history-answer-#{index}",
                   "expected_version" => decision.version,
                   "option_id" => "ship"
                 },
                 [actor: %{kind: :operator, id: "operator"}],
                 store
               )
    end

    # This test measures what the operator's own clicks put on screen: page one,
    # then one page per "Load more". The view also refreshes itself on a timer
    # (PayloadLoader schedules :reload_payload 50-450ms out), and that refresh
    # correctly prepends a Command that reached history since the last read --
    # here, history-26. Whether that refresh lands inside the window between
    # answering history-26 and a click is pure scheduling luck, so the row count
    # was 20-or-21 and then 25-or-26 depending on box load; CI saw the second
    # form. Holding the timer inert makes the pagination arithmetic the only
    # thing moving the rows. The totals still come from the store, because
    # "Load more" reads the counts and the page in the same serialized read --
    # so the 26 assertions below still prove the refresh path is not the source
    # of the count. Same seam, and same reason, as the retry test above.
    inert_reload_timer = fn _destination, _message, _delay_ms -> make_ref() end

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      decision_store: decision_store_name,
      control_center_reload_timer: inert_reload_timer
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    assert history_row_count(view) == 10
    assert render(view) =~ "10 of 25"

    newest = request_dashboard_decision(store, "history-26")

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               newest.decision_id,
               %{
                 "idempotency_key" => "history-answer-26",
                 "expected_version" => newest.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "operator"}],
               store
             )

    view |> element(~s(button[phx-click="load-more-history"])) |> render_click()
    assert history_row_count(view) == 20
    assert render(view) =~ ~r/All\s+<span class="count num">26<\/span>/
    assert render(view) =~ ~r/Resolved\s+<span class="count num">26<\/span>/

    view |> element(~s(button[phx-click="load-more-history"])) |> render_click()
    assert history_row_count(view) == 25
    assert render(view) =~ "25 of 26"
    refute has_element?(view, ~s(button[phx-click="load-more-history"]))
  end

  test "an answered Command leaves the inbox and appears in green history" do
    orchestrator_name = Module.concat(__MODULE__, :DismissToHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DismissToHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 508}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    decision = request_dashboard_decision(store, "dismiss-to-history")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    assert has_element?(view, "#decision-#{decision.decision_id}")
    assert history_row_count(view) == 0

    view
    |> form("#decision-answer-form-#{decision.decision_id}", %{"answer" => %{"choice" => "option:ship"}})
    |> render_submit()

    refute has_element?(view, "#decision-#{decision.decision_id}")
    assert has_element?(view, "#history-#{decision.decision_id}")
    assert history_row_count(view) == 1

    row = view |> render() |> Floki.parse_document!() |> Floki.find("#history-#{decision.decision_id}")
    assert Floki.attribute(row, "data-severity") == ["good"]
    assert row |> Floki.text() =~ "Answered"
  end

  test "expands a history row in place and quotes the answer the operator recorded" do
    orchestrator_name = Module.concat(__MODULE__, :HistoryAccordionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :HistoryAccordionDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 510}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    answered = request_dashboard_decision(store, "history-accordion")

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               answered.decision_id,
               %{
                 "idempotency_key" => "history-accordion-answer",
                 "expected_version" => answered.version,
                 "custom_response" => "it is the executor's job to review"
               },
               [actor: %{kind: :operator, id: "operator"}],
               store
             )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    row = view |> render() |> Floki.parse_document!() |> Floki.find("#history-#{answered.decision_id}")
    assert row |> Floki.text() =~ "“it is the executor's job to review”"
    assert row |> Floki.find("button.history-row-toggle") |> Floki.attribute("aria-expanded") == ["false"]
    refute has_element?(view, "#history-detail-history-#{answered.decision_id}")

    # Clicking the row is what opens it; the Command's own context arrives
    # inline, and no card is hoisted to the top of the page.
    view |> element("#history-#{answered.decision_id}") |> render_click()

    assert has_element?(view, "#history-detail-history-#{answered.decision_id}")
    assert has_element?(view, "#history-#{answered.decision_id} button[aria-expanded='true']")
    assert has_element?(view, "#history-detail-history-#{answered.decision_id} #decision-detail-#{answered.decision_id}")
    refute has_element?(view, ".decision-list #decision-#{answered.decision_id}")

    view |> element("#history-#{answered.decision_id}") |> render_click()
    refute has_element?(view, "#history-detail-history-#{answered.decision_id}")
  end

  test "refreshes a history row in place when the store revises the Command behind it" do
    orchestrator_name = Module.concat(__MODULE__, :HistoryRefreshOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :HistoryRefreshDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 512}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    decision = request_dashboard_decision(store, "history-refresh")

    assert {:ok, %{status: :accepted, action: original}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "history-refresh-original",
                 "expected_version" => decision.version,
                 "custom_response" => "ship the original answer"
               },
               [actor: %{kind: :operator, id: "operator"}],
               store
             )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    assert render(view) =~ "“ship the original answer”"

    # Somebody else revises the Command while the row is already on screen. The
    # loaded row must not keep asserting the answer it was loaded with.
    assert {:ok, %{status: :accepted}} =
             DecisionStore.revise(
               decision.decision_id,
               %{
                 "idempotency_key" => "history-refresh-revision",
                 "expected_version" => decision.version,
                 "expected_action_id" => original.action_id,
                 "expected_revision_sequence" => 0,
                 "custom_response" => "no, the executor reviews it",
                 "rationale" => "The first answer was wrong"
               },
               [actor: %{kind: :operator, id: "operator"}],
               store
             )

    assert eventually(fn -> render(view) =~ "“no, the executor reviews it”" end, 100)
    refute render(view) =~ "“ship the original answer”"
    assert history_row_count(view) == 1
  end

  test "keeps a deep-linked Command readable when history has not loaded its page" do
    orchestrator_name = Module.concat(__MODULE__, :DeepLinkHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DeepLinkHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 513}}}
      end)

    start_counting_orchestrator(orchestrator_name)

    # One page of history plus one older Command: the deep-linked row sits
    # beyond the ten rows the first page loads.
    answered =
      for index <- 1..11 do
        decision = request_dashboard_decision(store, "deep-link-#{index}")

        assert {:ok, %{status: :accepted}} =
                 DecisionStore.answer(
                   decision.decision_id,
                   %{
                     "idempotency_key" => "deep-link-answer-#{index}",
                     "expected_version" => decision.version,
                     "option_id" => "ship"
                   },
                   [actor: %{kind: :operator, id: "operator"}],
                   store
                 )

        decision
      end

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")
    assert history_row_count(view) == 10

    unloaded =
      Enum.find(answered, fn decision ->
        not has_element?(view, "#history-#{decision.decision_id}")
      end)

    refute is_nil(unloaded), "expected one answered Command outside the first history page"

    {:ok, deep_linked, _html} = live(build_conn(), "/commands/#{unloaded.decision_id}")

    # No row to expand, so the card is still the only way to read it.
    refute has_element?(deep_linked, "#history-detail-history-#{unloaded.decision_id}")
    assert has_element?(deep_linked, "#decision-#{unloaded.decision_id}")
    refute render(deep_linked) =~ "Command not found"
  end

  test "reports an expired Command as having no decision at all" do
    orchestrator_name = Module.concat(__MODULE__, :ExpiredHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ExpiredHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 511}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    expired = request_dashboard_decision(store, "history-expired", "reversible", blocking: false)

    assert {:ok, _expired} =
             DecisionStore.expire(expired.decision_id, "agent_not_running", [], store)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    row = view |> render() |> Floki.parse_document!() |> Floki.find("#history-#{expired.decision_id}")

    assert row |> Floki.find("td.history-decision") |> Floki.text() == "N/A"
    assert row |> Floki.text() =~ "Expired"
  end

  test "notifying the Executor keeps the Command open without flattening it into an answer" do
    orchestrator_name = Module.concat(__MODULE__, :DeferToHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DeferToHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 509}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    decision = request_dashboard_decision(store, "defer-to-history")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    view
    |> element(~s(button[phx-click="defer-decision"][phx-value-decision-id="#{decision.decision_id}"]))
    |> render_click()

    assert has_element?(view, ".decision-list #decision-#{decision.decision_id}")
    refute has_element?(view, "#history-#{decision.decision_id}")

    card = view |> render() |> Floki.parse_document!() |> Floki.find("#decision-#{decision.decision_id}")
    assert card |> Floki.text() =~ "Deferred to Executor"
    refute card |> Floki.text() =~ "Answered"
  end
end
