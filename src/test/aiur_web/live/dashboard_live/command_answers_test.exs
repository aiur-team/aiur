defmodule AiurWeb.DashboardLive.CommandAnswersTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.DecisionEvent
  alias Aiur.DecisionPubSub
  alias Aiur.DecisionStore
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.OperatorMessages
  alias AiurWeb.DashboardLiveSupport.StoreStubs.RejectingDecisionStore

  @endpoint AiurWeb.Endpoint

  test "malformed filter and agent-log events do not crash the dashboard" do
    orchestrator_name = Module.concat(__MODULE__, :MalformedEventOrchestrator)
    start_counting_orchestrator(orchestrator_name)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 100)

    {:ok, view, _html} = live(build_conn(), "/commands")

    assert render_hook(view, "filter-decisions", %{}) =~ "Commands inbox"
    assert render_hook(view, "show-agent-log", %{}) =~ "Commands inbox"
    assert Process.alive?(view.pid)
  end

  test "writable decision form records once and leaves an absent-agent answer pending" do
    orchestrator_name = Module.concat(__MODULE__, :ActionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ActionDecisionStore)
    counter = :counters.new(1, [])

    dispatcher = fn _decision, _opts ->
      :ok = :counters.add(counter, 1, 1)
      {:error, :no_running_agent}
    end

    store = start_decision_store(decision_store_name, dispatcher)
    decision = request_dashboard_decision(store, "dashboard-action")
    decision_id = decision.decision_id
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true,
      control_center_cache: false
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    refute html =~ "Answer this Command"
    assert html =~ ~s(phx-submit="answer-decision")

    params = %{
      "decision_id" => decision.decision_id,
      "answer" => %{"choice" => "option:ship", "rationale" => "Checks are green"}
    }

    :ok = DecisionPubSub.subscribe()
    html = render_submit(view, "answer-decision", params)
    assert html =~ "Answer recorded"

    assert_receive {:decision_changed, ^decision_id, 1}, 2_000
    assert_receive {:decision_changed, ^decision_id, 1}, 2_000

    assert {:ok, %{delivery_status: :pending, pending_for_session?: true}} =
             DecisionStore.get(decision.decision_id, store)

    assert :counters.get(counter, 1) == 1

    {:ok, _view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert html =~ "Recorded answer"
    refute html =~ "Delivery failed"
    refute html =~ ~s(phx-click="retry-decision")

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :answer_recorded}, &1)) == 1
    refute Enum.any?(audit, &match?(%DecisionEvent{type: :failed}, &1))
    assert Enum.count(audit, &match?(%DecisionEvent{type: :pending_for_session}, &1)) == 1
  end

  test "irreversible answers do not require a redundant confirmation" do
    orchestrator_name = Module.concat(__MODULE__, :ConfirmationOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ConfirmationDecisionStore)

    dispatcher = fn _decision, _opts ->
      {:ok, %{status: :accepted, item: %{id: 502}}}
    end

    store = start_decision_store(decision_store_name, dispatcher)
    decision = request_dashboard_decision(store, "dashboard-confirmation", "irreversible")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    refute html =~ "I understand this Command is irreversible or destructive."

    params = %{
      "decision_id" => decision.decision_id,
      "answer" => %{"choice" => "option:ship"}
    }

    html = render_submit(view, "answer-decision", params)
    assert html =~ "Answer recorded"

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer.selected_option_id == "ship"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.any?(audit, &match?(%DecisionEvent{type: :answer_recorded}, &1))
  end

  test "a socket mounted writable fails closed when the endpoint gate changes" do
    orchestrator_name = Module.concat(__MODULE__, :GateChangeOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :GateChangeDecisionStore)
    test_pid = self()

    dispatcher = fn _decision, _opts ->
      send(test_pid, :unexpected_gate_change_dispatch)
      {:ok, %{status: :accepted, item: %{id: 503}}}
    end

    store = start_decision_store(decision_store_name, dispatcher)
    decision = request_dashboard_decision(store, "dashboard-gate-change")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert html =~ ~s(phx-submit="answer-decision")

    endpoint_config = Application.fetch_env!(:aiur, AiurWeb.Endpoint)
    disabled_config = Keyword.put(endpoint_config, :dashboard_writable, false)
    Application.put_env(:aiur, AiurWeb.Endpoint, disabled_config)
    :ok = AiurWeb.Endpoint.config_change([{AiurWeb.Endpoint, disabled_config}], [])

    params = %{
      "decision_id" => decision.decision_id,
      "answer" => %{"choice" => "option:ship"}
    }

    html = render_submit(view, "answer-decision", params)
    assert html =~ "Read-only mode · Command mutation controls are hidden."
    refute html =~ ~s(phx-submit="answer-decision")

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert is_nil(current.answer)
    refute_received :unexpected_gate_change_dispatch
  end

  test "stale answer rejection keeps the draft and explains the canonical refresh" do
    orchestrator_name = Module.concat(__MODULE__, :StaleActionOrchestrator)
    store_name = Module.concat(__MODULE__, :RejectingDecisionStoreInstance)
    decision = dashboard_decision("dec-stale-dashboard")

    start_supervised!({RejectingDecisionStore, name: store_name, decision: decision, report: self()})
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: store_name,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

    params = %{
      "decision_id" => decision.decision_id,
      "answer" => %{"choice" => "custom", "custom_response" => "Use the safer path", "rationale" => "Lower risk"}
    }

    _html = render_submit(view, "answer-decision", params)
    html = render(view)

    assert html =~ "changed to version 2"
    assert html =~ "Use the safer path"
    assert html =~ ~s(phx-submit="answer-decision")

    assert_receive {:dashboard_answer_attempt, decision_id, payload, opts}, 1000
    assert decision_id == decision.decision_id
    assert payload["expected_version"] == 1
    assert payload["custom_response"] == "Use the safer path"
    assert String.starts_with?(payload["idempotency_key"], "ui_")
    assert opts[:actor].kind == :operator
  end

  test "card-face deferral persists and publishes to the Executor without waking the ticket agent" do
    orchestrator_name = Module.concat(__MODULE__, :DismissCapstoneOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DismissCapstoneDecisionStore)
    orchestrator = start_queue_orchestrator(orchestrator_name, "987")
    store = start_decision_store(decision_store_name, fn _decision, _opts -> {:error, :unexpected_dispatch} end)
    live_decision = request_queue_decision(store, "dashboard-dismiss-live", "987")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands")
    assert :ok = Exchange.subscribe("executor.#")
    assert html =~ ~s(phx-click="defer-decision")

    _html =
      view
      |> element("#decision-#{live_decision.decision_id} button[phx-click=\"defer-decision\"]")
      |> render_click()

    assert {:ok, deferred} = DecisionStore.get(live_decision.decision_id, store)
    assert deferred.decision_status == :deferred
    assert deferred.answer == nil
    assert_receive {:event, %{topic: "executor.decision.deferred", decision_id: decision_id, issue_identifier: "987", provenance: :operator_dashboard}}, 500
    assert decision_id == live_decision.decision_id
    assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, "987")

    :sys.replace_state(orchestrator, &%{&1 | running: %{}})
    gone_decision = request_queue_decision(store, "dashboard-dismiss-gone", "988")
    {:ok, gone_view, _html} = live(build_conn(), "/commands")

    _html =
      gone_view
      |> element("#decision-#{gone_decision.decision_id} button[phx-click=\"defer-decision\"]")
      |> render_click()

    assert {:ok, gone_deferred} = DecisionStore.get(gone_decision.decision_id, store)
    assert gone_deferred.decision_status == :deferred
    refute_receive {:agent_queue_updated, "988", _queue_item_id, _delivery}, 200
    assert :empty = OperatorMessages.claim_next_checkpoint_queue_item(orchestrator, "988")
  end

  test "dismissing a Command notifies a live agent to use its judgement, and skips a gone one" do
    orchestrator_name = Module.concat(__MODULE__, :DismissNotifyOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DismissNotifyDecisionStore)
    orchestrator = start_queue_orchestrator(orchestrator_name, "987")
    store = start_decision_store(decision_store_name, fn _decision, _opts -> {:error, :unexpected_dispatch} end)

    assert {:ok, %{decision: live_decision}} =
             Aiur.DecisionStoreCase.request(
               store,
               %{
                 "source_id" => "dashboard-dismiss-notify-live",
                 "question" => "Should the dashboard ship this change?",
                 "blocking" => false,
                 "urgency" => "normal",
                 "reversibility" => "reversible",
                 "options" => [%{"id" => "ship", "label" => "Ship it"}]
               },
               ticket: %{identifier: "987", title: "Operator Control Center", url: nil},
               source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-dismiss-notify-live"}
             )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{live_decision.decision_id}")
    assert html =~ ~s(phx-click="dismiss-decision")

    _html =
      view
      |> element("#decision-#{live_decision.decision_id} button[phx-click=\"dismiss-decision\"]")
      |> render_click()

    assert {:ok, dismissed} = DecisionStore.get(live_decision.decision_id, store)
    assert dismissed.decision_status == :dismissed

    # The live agent is told the operator dismissed its Command and to proceed
    # under its own judgement; the message lands on the checkpoint queue.
    {:ok, item} = OperatorMessages.claim_next_checkpoint_queue_item(orchestrator, "987")
    assert item.category == :operator_message
    assert item.body.text =~ "dismissed by the operator"
    assert item.body.text =~ "Use your judgement"

    # A Command whose agent is gone closes locally with no message.
    :sys.replace_state(orchestrator, &%{&1 | running: %{}})

    assert {:ok, %{decision: gone_decision}} =
             Aiur.DecisionStoreCase.request(
               store,
               %{
                 "source_id" => "dashboard-dismiss-notify-gone",
                 "question" => "Should the dashboard ship this change?",
                 "blocking" => false,
                 "urgency" => "normal",
                 "reversibility" => "reversible",
                 "options" => [%{"id" => "ship", "label" => "Ship it"}]
               },
               ticket: %{identifier: "988", title: "Operator Control Center", url: nil},
               source: %{agent_id: "agent-988", session_id: "session-988", event_id: "event-dismiss-notify-gone"}
             )

    {:ok, gone_view, _html} = live(build_conn(), "/commands/#{gone_decision.decision_id}")

    _html =
      gone_view
      |> element("#decision-#{gone_decision.decision_id} button[phx-click=\"dismiss-decision\"]")
      |> render_click()

    assert {:ok, gone_dismissed} = DecisionStore.get(gone_decision.decision_id, store)
    assert gone_dismissed.decision_status == :dismissed
    assert :empty = OperatorMessages.claim_next_checkpoint_queue_item(orchestrator, "988")
  end

  test "a deferred detail command remains answerable" do
    orchestrator_name = Module.concat(__MODULE__, :DeferredDetailOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DeferredDetailStore)
    store = start_decision_store(decision_store_name, fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 5_074}}} end)
    decision = request_queue_decision(store, "deferred-detail", "987")

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert html =~ ~s(phx-click="defer-decision")

    _html =
      view
      |> element("#decision-#{decision.decision_id} button[phx-click=\"defer-decision\"]")
      |> render_click()

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "The Executor can still receive the final answer"}
      })

    assert html =~ "Answer recorded"
    assert {:ok, %{decision_status: :decided}} = DecisionStore.get(decision.decision_id, store)
  end

  test "free-form attention acknowledges without recording an answer" do
    orchestrator_name = Module.concat(__MODULE__, :AckFreeFormOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :AckFreeFormStore)
    store = start_decision_store(decision_store_name, fn _decision, _opts -> {:error, :unexpected_dispatch} end)

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{
          "source_id" => "dashboard-ack-free-form",
          "question" => "Heads up: the run finished.",
          "blocking" => false,
          "urgency" => "normal",
          "reversibility" => "reversible",
          "options" => []
        },
        [
          ticket: %{identifier: "987", title: "Operator Control Center", url: nil},
          source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-ack"}
        ],
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

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert html =~ ~s(phx-click="dismiss-decision")

    html =
      view
      |> element("#decision-#{decision.decision_id} button[phx-click=\"dismiss-decision\"]")
      |> render_click()

    # The notice states what happened, not which affordance was used: the same
    # event backs the Acknowledge button and the blocker dismissal, so claiming
    # an acknowledgement here would be false on the other route.
    assert html =~ "Command closed without a recorded answer."
    refute html =~ "acknowledged"
    assert {:ok, dismissed} = DecisionStore.get(decision.decision_id, store)
    assert dismissed.decision_status == :dismissed
    assert dismissed.answer == nil
  end
end
