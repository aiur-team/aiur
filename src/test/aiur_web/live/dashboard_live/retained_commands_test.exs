defmodule AiurWeb.DashboardLive.RetainedCommandsTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.CommandsCLI
  alias Aiur.DecisionMetrics
  alias Aiur.DecisionPubSub
  alias Aiur.DecisionStore
  alias Aiur.Events.Exchange
  alias AiurWeb.DashboardLiveSupport.StoreStubs.AvailabilityStore
  alias AiurWeb.DashboardLiveSupport.StoreStubs.StaleCountsStore
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.PayloadLoader

  @endpoint AiurWeb.Endpoint

  test "cached payload follows a same-name DecisionMetrics replacement" do
    orchestrator_name = Module.concat(__MODULE__, :RestartCacheOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RestartCacheDecisionStore)
    metrics_name = Module.concat(__MODULE__, :RestartCacheDecisionMetrics)
    requested_at = ~U[2026-07-12 12:00:00.000Z]

    start_counting_orchestrator(orchestrator_name)

    store =
      start_decision_store(
        decision_store_name,
        fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 507}}} end,
        dispatch_delay_ms: 60_000
      )

    assert :ok = Exchange.subscribe("ticket.987.agent.decision.#")
    assert :ok = DecisionPubSub.subscribe()
    decision = request_queue_decision(store, "restart-cache", "987", now: requested_at)
    assert_receive {:event, %{topic: "ticket.987.agent.decision.requested"} = request_event}, 2_000

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "restart-cache-answer",
                 "expected_version" => decision.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "operator"}, now: DateTime.add(requested_at, 2, :second)],
               store
             )

    assert_receive {:event, %{topic: "ticket.987.agent.decision.answered"} = answer_event}, 2_000
    {old_metrics, restart_metrics} = start_restartable_dashboard_metrics(metrics_name, store)
    assert :ok = DecisionMetrics.observe(request_event, old_metrics)
    assert :ok = DecisionMetrics.observe(answer_event, old_metrics)
    drain_metrics_notifications()

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics_name
    )

    old_payload = PayloadLoader.load(:fresh)
    assert payload_latency(old_payload, decision.decision_id).request_to_decision_ms == 2_000

    GenServer.stop(old_metrics)
    new_metrics = restart_metrics.()
    refute new_metrics == old_metrics

    assert :ok = DecisionMetrics.observe(request_event, new_metrics)
    assert_receive :decision_metrics_changed, 2_000

    cache = EndpointConfig.get(:control_center_cache)
    touch_cached_payloads(cache)
    assert map_size(:sys.get_state(cache).entries) == 1
    assert cached_payloads_fresh?(cache, 400)

    restarted_payload = PayloadLoader.load(:cached)
    restarted_latency = payload_latency(restarted_payload, decision.decision_id)

    assert restarted_latency.requested_at == DateTime.to_iso8601(requested_at)
    assert restarted_latency.request_to_decision_ms == nil

    final_metrics =
      Enum.reduce(1..12, new_metrics, fn _restart, current_metrics ->
        GenServer.stop(current_metrics)
        replacement = restart_metrics.()
        assert :ok = DecisionMetrics.observe(request_event, replacement)

        replacement_payload = PayloadLoader.load(:cached)
        assert payload_latency(replacement_payload, decision.decision_id).request_to_decision_ms == nil
        replacement
      end)

    assert GenServer.whereis(metrics_name) == final_metrics
    assert map_size(:sys.get_state(cache).entries) == 8
    drain_metrics_notifications()
  end

  test "persists a decision filter in the URL while opening and closing a card" do
    orchestrator_name = Module.concat(__MODULE__, :FilterOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :FilterDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 506}}}
      end)

    decision = request_dashboard_decision(store, "dashboard-filter")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    view
    |> element(~s(button[phx-click="filter-decisions"][phx-value-filter="blocking"]))
    |> render_click()

    assert_patch(view, "/commands?filter=blocking")

    view
    |> element("#decision-#{decision.decision_id} .decision-card-head")
    |> render_click()

    assert_patch(view, "/commands/#{decision.decision_id}?filter=blocking")

    view
    |> element("#decision-#{decision.decision_id} .decision-card-head")
    |> render_click()

    assert_patch(view, "/commands?filter=blocking")

    view
    |> element("#decision-#{decision.decision_id} .decision-card-head")
    |> render_click()

    assert_patch(view, "/commands/#{decision.decision_id}?filter=blocking")
    render_submit(view, "search-commands", %{"search" => decision.decision_id})
    assert_patch(view, "/commands?search=#{decision.decision_id}")
  end

  test "ticket query navigation returns the exact Commands ticket instead of identifier prefixes" do
    orchestrator_name = Module.concat(__MODULE__, :ExactTicketQueryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ExactTicketQueryStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 61}}}
      end)

    exact =
      request_dashboard_decision(store, "exact-ticket-11", "reversible", ticket: %{identifier: "11", title: "Exact ticket", url: nil})

    prefixed =
      request_dashboard_decision(store, "prefixed-ticket-1110", "reversible", ticket: %{identifier: "1110", title: "Prefixed ticket", url: nil})

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands?ticket=11")

    assert has_element?(view, "#decision-#{exact.decision_id}")
    refute has_element?(view, "#decision-#{prefixed.decision_id}")
  end

  test "Open Commands includes every canonical open authority" do
    orchestrator_name = Module.concat(__MODULE__, :MixedAuthorityOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :MixedAuthorityDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_078}}}
      end)

    human = request_dashboard_decision(store, "open-human")

    delegated =
      request_dashboard_decision(store, "open-supervisor", "reversible", decision_authority: :supervisor_allowed)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    view
    |> element(~s(button[phx-click="filter-decisions"][phx-value-filter="open"]))
    |> render_click()

    assert_patch(view, "/commands?filter=open")
    assert has_element?(view, ".decision-list #decision-#{human.decision_id}")
    assert has_element?(view, ".decision-list #decision-#{delegated.decision_id}")
  end

  test "deferred Commands remain visible in open and blocking queue counts" do
    orchestrator_name = Module.concat(__MODULE__, :DeferredOpenOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DeferredOpenDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_079}}}
      end)

    decision = request_dashboard_decision(store, "deferred-open")

    assert {:ok, %{status: :accepted, decision: %{decision_status: :deferred}}} =
             DecisionStore.defer(
               decision.decision_id,
               [actor: %{kind: :operator, id: "dashboard"}],
               store
             )

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands")

    assert html =~ ~r/Open\s+<span class="count num">1<\/span>/
    assert html =~ ~r/Blocking\s+<span class="count num">1<\/span>/
    assert html =~ ~r/Resolved\s+<span class="count num">0<\/span>/
    assert html =~ ~r/All\s+<span class="count num">1<\/span>/
    assert has_element?(view, ".decision-list #decision-#{decision.decision_id}")
    refute has_element?(view, "#history-#{decision.decision_id}")

    view
    |> element(~s(button[phx-click="filter-decisions"][phx-value-filter="blocking"]))
    |> render_click()

    assert_patch(view, "/commands?filter=blocking")
    assert has_element?(view, ".decision-list #decision-#{decision.decision_id}")

    view
    |> form("#decision-answer-form-#{decision.decision_id}", %{"answer" => %{"choice" => "option:ship"}})
    |> render_submit()

    refute has_element?(view, ".decision-list #decision-#{decision.decision_id}")
    assert has_element?(view, "#history-#{decision.decision_id}")

    transitioned_html = render(view)
    assert transitioned_html =~ ~r/Open\s+<span class="count num">0<\/span>/
    assert transitioned_html =~ ~r/Blocking\s+<span class="count num">0<\/span>/
    assert transitioned_html =~ ~r/Resolved\s+<span class="count num">1<\/span>/
  end

  test "Command chips use the same retained snapshot as history totals" do
    orchestrator_name = Module.concat(__MODULE__, :SnapshotCountsOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :SnapshotCountsDecisionStore)
    stale_counts_store_name = Module.concat(__MODULE__, :StaleSnapshotCountsStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_080}}}
      end)

    decision = request_dashboard_decision(store, "snapshot-counts", "reversible", blocking: false)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.dismiss(
               decision.decision_id,
               [actor: %{kind: :operator, id: "dashboard"}],
               store
             )

    start_supervised!({StaleCountsStore, name: stale_counts_store_name, store: store})
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: stale_counts_store_name,
      control_center_cache: false
    )

    {:ok, view, html} = live(build_conn(), "/commands")

    assert html =~ ~r/All\s+<span class="count num">1<\/span>/
    assert html =~ ~r/Resolved\s+<span class="count num">1<\/span>/
    assert html =~ "1 of 1"

    send(view.pid, :reload_payload)
    reloaded_html = render(view)

    assert reloaded_html =~ ~r/All\s+<span class="count num">1<\/span>/
    assert reloaded_html =~ ~r/Resolved\s+<span class="count num">1<\/span>/
    assert reloaded_html =~ "1 of 1"
  end

  test "Command chips stop showing retained counts when a reload loses the store" do
    orchestrator_name = Module.concat(__MODULE__, :UnavailableCountsOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :UnavailableCountsDecisionStore)
    availability_store_name = Module.concat(__MODULE__, :UnavailableCountsStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_081}}}
      end)

    decision = request_dashboard_decision(store, "unavailable-counts", "reversible", blocking: false)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.dismiss(
               decision.decision_id,
               [actor: %{kind: :operator, id: "dashboard"}],
               store
             )

    start_supervised!({AvailabilityStore, name: availability_store_name, store: store})
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: availability_store_name,
      control_center_cache: false
    )

    {:ok, view, html} = live(build_conn(), "/commands")

    assert html =~ ~r/All\s+<span class="count num">1<\/span>/
    assert :ok = AvailabilityStore.set_available(availability_store_name, false)

    send(view.pid, :reload_payload)
    reloaded_html = render(view)

    assert reloaded_html =~ ~r/All\s+<span class="count num">—<\/span>/
    assert reloaded_html =~ ~r/Open\s+<span class="count num">—<\/span>/
    assert reloaded_html =~ ~r/Blocking\s+<span class="count num">—<\/span>/
  end

  test "All Commands keeps retained search and pagination controls out of the surface" do
    orchestrator_name = Module.concat(__MODULE__, :RetainedPageOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RetainedPageDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_079}}}
      end)

    decisions =
      for index <- 0..26 do
        request_dashboard_decision(store, "retained-page-#{index}", "reversible", now: DateTime.add(~U[2026-07-13 08:00:00Z], index, :second))
      end

    oldest = hd(decisions)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false
    )

    {:ok, view, html} = live(build_conn(), "/commands")

    refute html =~ "Search retained Commands"
    refute html =~ "Command ID or ticket ID"
    refute html =~ "Next page"
    refute html =~ "Final retained Command page"
    refute has_element?(view, "#decision-#{oldest.decision_id}")

    invalid_html = render_patch(view, "/commands?cursor=not-a-valid-cursor")
    assert invalid_html =~ "Commands are unavailable right now"
    assert Process.alive?(view.pid)
  end

  test "All Commands counts retained history while its cards match the CLI open set" do
    orchestrator_name = Module.concat(__MODULE__, :OpenPageOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :OpenPageDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_080}}}
      end)

    # Non-blocking: this fixture only needs historic rows to page over, and a
    # blocking Command cannot be closed without an answer.
    decisions =
      for index <- 0..26 do
        request_dashboard_decision(store, "open-page-#{index}", "reversible",
          blocking: false,
          now: DateTime.add(~U[2026-07-13 08:00:00Z], index, :second)
        )
      end

    Enum.each(Enum.drop(decisions, 2), fn decision ->
      assert {:ok, %{status: :accepted}} =
               DecisionStore.dismiss(
                 decision.decision_id,
                 [actor: %{kind: :operator, id: "dashboard"}],
                 store
               )
    end)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false
    )

    {:ok, view, html} = live(build_conn(), "/commands")

    assert html =~ ~r/All\s+<span class="count num">27<\/span>/
    assert html =~ ~r/Resolved\s+<span class="count num">25<\/span>/
    assert has_element?(view, "#decision-#{Enum.at(decisions, 0).decision_id}")
    assert has_element?(view, "#decision-#{Enum.at(decisions, 1).decision_id}")

    Enum.each(Enum.drop(decisions, 2), fn decision ->
      refute has_element?(view, "#decision-#{decision.decision_id}")
    end)

    assert {:ok, cli} =
             CommandsCLI.build(
               decision_store: decision_store_name,
               decision_metrics: make_ref(),
               history_fun: fn -> [] end
             )

    assert cli["data"]["page"]["decisions"]
           |> MapSet.new(& &1["decision_id"]) ==
             decisions
             |> Enum.take(2)
             |> MapSet.new(& &1.decision_id)
  end
end
