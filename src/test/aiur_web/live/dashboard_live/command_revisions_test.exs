defmodule AiurWeb.DashboardLive.CommandRevisionsTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.Decision
  alias Aiur.DecisionEvent
  alias Aiur.DecisionHistory
  alias Aiur.DecisionMetrics
  alias Aiur.DecisionMetrics.Event, as: DecisionMetricsEvent
  alias Aiur.DecisionPubSub
  alias Aiur.DecisionStore
  alias Aiur.Events.Exchange
  alias Aiur.Issue
  alias Aiur.Orchestrator.OperatorMessages
  alias AiurWeb.DashboardLiveSupport.StoreStubs.RejectingRevisionStore

  @endpoint AiurWeb.Endpoint

  test "append-only revision preserves the original answer and obeys the writable gate" do
    orchestrator_name = Module.concat(__MODULE__, :RevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RevisionDecisionStore)

    dispatcher = fn _decision, _opts ->
      {:ok, %{status: :accepted, item: %{id: System.unique_integer([:positive])}}}
    end

    store = start_decision_store(decision_store_name, dispatcher)
    decision = request_dashboard_decision(store, "dashboard-revision", "irreversible")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

    _html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "confirmed" => "true"}
      })

    assert eventually(fn -> render(view) =~ ~s(phx-submit="revise-decision") end, 100)

    revision_params = %{
      "decision_id" => decision.decision_id,
      "revision" => %{
        "choice" => "custom",
        "custom_response" => "Hold deployment until the incident closes",
        "reason" => "New production evidence"
      }
    }

    assert render_change(view, "decision-revision-change", revision_params) =~
             "Hold deployment until the incident closes"

    html = render_submit(view, "revise-decision", revision_params)
    assert html =~ "Confirm that you understand this revised direction"

    assert {:ok, unchanged} = DecisionStore.get(decision.decision_id, store)
    assert unchanged.revision_sequence == 0

    html =
      render_submit(view, "revise-decision", %{
        revision_params
        | "revision" => Map.put(revision_params["revision"], "confirmed", "true")
      })

    assert html =~ "Revision recorded"
    assert html =~ "Original answer · preserved"
    assert html =~ "Hold deployment until the incident closes"
    assert html =~ "New production evidence"
    assert html =~ "Current revised answer"

    assert {:ok, revised} = DecisionStore.get(decision.decision_id, store)
    assert revised.revision_sequence == 1
    assert revised.answer.selected_option_id == "ship"
    assert Decision.active_answer(revised).custom_response == "Hold deployment until the incident closes"
    assert revised.active_action_id == List.last(revised.revisions).action_id

    disable_dashboard_writes()

    html = render_submit(view, "revise-decision", revision_params)
    assert html =~ "Original answer · preserved"
    assert html =~ "Read-only mode · Command mutation controls are hidden."
    refute html =~ ~s(phx-submit="revise-decision")

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :revision_recorded}, &1)) == 1
  end

  test "un-applicable revision exposes and handles the parent follow-up" do
    orchestrator_name = Module.concat(__MODULE__, :RevisionFollowUpOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RevisionFollowUpDecisionStore)

    dispatcher = fn dispatched, _opts ->
      if dispatched.revision_sequence > 0,
        do: {:no_longer_applicable, :missing},
        else: {:ok, %{status: :accepted, item: %{id: 504}}}
    end

    store =
      start_decision_store(decision_store_name, dispatcher,
        revision_follow_up_projector: fn _decision, _action_id -> :ok end,
        revision_follow_up_resolver: fn _decision, _action_id -> :ok end
      )

    decision = request_dashboard_decision(store, "dashboard-revision-follow-up")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

    _html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship"}
      })

    _html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Stop the inactive rollout",
          "reason" => "The target is no longer active"
        }
      })

    assert eventually(fn -> render(view) =~ "Executor follow-up required" end, 100)

    {:ok, pending} = DecisionStore.get(decision.decision_id, store)

    {action_id, follow_up} =
      Enum.find(pending.revision_follow_ups, fn {_action_id, item} ->
        is_nil(item.handled_at)
      end)

    refute follow_up.question =~ ~r/rolled back|reverted|undone/i

    html =
      render_submit(view, "handle-revision-follow-up", %{
        "decision_id" => decision.decision_id,
        "action_id" => action_id,
        "follow_up" => %{"detail" => "Opened an incident command and notified the operator"}
      })

    assert html =~ "Revision follow-up handled"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             not is_nil(current.revision_follow_ups[action_id].handled_at)
           end)

    assert {:ok, handled} = DecisionStore.get(decision.decision_id, store)

    assert handled.revision_follow_ups[action_id].handled_detail ==
             "Opened an incident command and notified the operator"

    assert handled.revision_follow_ups[action_id].handled_by.kind == :operator
  end

  test "stale revision rejection preserves the corrective draft" do
    orchestrator_name = Module.concat(__MODULE__, :StaleRevisionOrchestrator)
    source_store_name = Module.concat(__MODULE__, :StaleRevisionSourceStore)
    rejecting_store_name = Module.concat(__MODULE__, :RejectingRevisionStoreInstance)

    source_store =
      start_decision_store(source_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 505}}}
      end)

    decision = request_dashboard_decision(source_store, "dashboard-stale-revision")

    assert {:ok, _accepted} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "stale-revision-original",
                 "expected_version" => decision.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "test"}],
               source_store
             )

    assert {:ok, answered} = DecisionStore.get(decision.decision_id, source_store)

    start_supervised!({RejectingRevisionStore, name: rejecting_store_name, decision: answered, report: self()})

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: rejecting_store_name,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Keep the safer correction",
          "reason" => "The canonical action moved"
        }
      })

    assert html =~ "active action changed"
    assert html =~ "Keep the safer correction"
    assert html =~ "The canonical action moved"
    assert html =~ ~s(phx-submit="revise-decision")

    assert_receive {:dashboard_revision_attempt, decision_id, payload, opts}, 1000
    assert decision_id == decision.decision_id
    assert payload["expected_version"] == answered.version
    assert payload["expected_action_id"] == answered.active_action_id
    assert payload["expected_revision_sequence"] == 0
    assert String.starts_with?(payload["idempotency_key"], "ui_rev_")
    assert opts[:actor].kind == :operator
  end

  test "human dashboard revision traverses the corrective queue and lifecycle projections" do
    orchestrator_name = Module.concat(__MODULE__, :RevisionCapstoneOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RevisionCapstoneDecisionStore)
    metrics_name = Module.concat(__MODULE__, :RevisionCapstoneDecisionMetrics)

    orchestrator = start_queue_orchestrator(orchestrator_name, "987")

    issue_fetcher = fn ["987"] ->
      {:ok,
       [
         %Issue{
           id: "987",
           identifier: "987",
           state: "in-progress",
           title: "Operator Control Center"
         }
       ]}
    end

    store =
      start_decision_store(
        decision_store_name,
        dispatch_via(orchestrator, issue_fetcher: issue_fetcher),
        dispatch_delay_ms: 0
      )

    metrics = start_dashboard_metrics(metrics_name, store)
    assert :ok = DecisionPubSub.subscribe()
    assert :ok = Exchange.subscribe("ticket.987.agent.decision.revision-recorded")
    decision = request_queue_decision(store, "dashboard-revision-capstone", "987")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics,
      control_center_cache: false,
      dashboard_writable: true
    )

    path = "/commands/#{decision.decision_id}"
    {:ok, view, _html} = live(build_conn(), path)

    _html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{
          "choice" => "option:ship",
          "rationale" => "Initial production evidence supports shipping"
        }
      })

    assert_receive {:agent_queue_updated, "987", original_queue_id, _delivery}, 2_000

    assert {:ok, %{id: ^original_queue_id} = original_item} =
             OperatorMessages.claim_next_queue_item(orchestrator, "987")

    assert {:ok, original_queued} = DecisionStore.get(decision.decision_id, store)
    original_action_id = original_queued.active_action_id
    assert original_item.action_id == original_action_id
    assert original_item.correlation.decision_id == decision.decision_id
    assert {:ok, :accepted} = DecisionStore.record_delivery(original_item, store)

    lifecycle_opts = [
      ticket_identifier: "987",
      actor: %{kind: :agent, id: "ticket-agent"},
      source: %{
        agent_id: "codex",
        session_id: "revision-capstone-session",
        invocation_id: "revision-capstone-lifecycle"
      }
    ]

    original_lifecycle = %{
      "decision_id" => decision.decision_id,
      "action_id" => original_action_id,
      "expected_version" => decision.version,
      "detail" => "Original direction applied"
    }

    assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
             DecisionStore.agent_lifecycle(:acknowledged, original_lifecycle, lifecycle_opts, store)

    assert {:ok, %{status: :accepted, decision_status: :resolved}} =
             DecisionStore.agent_lifecycle(:resolved, original_lifecycle, lifecycle_opts, store)

    assert {:ok, _initial_metrics} = DecisionMetrics.snapshot(decision.decision_id, metrics)
    drain_metrics_notifications()
    assert reload_view(view) =~ "Resolved"

    revision_html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Hold deployment until the incident closes",
          "reason" => "New production evidence invalidated the original direction"
        }
      })

    assert revision_html =~ "Revision recorded"
    assert revision_html =~ "Original answer · preserved"
    assert revision_html =~ "Hold deployment until the incident closes"
    assert_receive {:event, revision_metric_event}, 2_000
    normalized_metric_event = DecisionMetricsEvent.normalize(revision_metric_event, DateTime.utc_now())

    assert match?({:ok, _fact}, normalized_metric_event),
           "revision event was not metric-compatible: #{inspect(revision_metric_event)}"

    assert_receive :decision_metrics_changed, 2_000
    assert_receive {:agent_queue_updated, "987", revision_queue_id, _delivery}, 2_000

    assert {:ok, %{id: ^revision_queue_id} = revision_item} =
             OperatorMessages.claim_next_queue_item(orchestrator, "987")

    # `:agent_queue_updated` is broadcast by the dispatch task while it is still
    # enqueueing; the store only records `:revision_dispatched` once that task
    # reports back. Await the store's own transition instead of reading through
    # the queue signal.
    assert {:ok, revision_queued} = await_dispatched_revision(store, decision.decision_id)
    revised_answer = Decision.active_answer(revision_queued)

    assert revision_queued.revision_sequence == 1
    assert revision_queued.revision_result == :dispatched
    assert revision_queued.active_action_id == revised_answer.action_id
    assert revision_queued.active_action_id != original_action_id
    assert is_nil(revision_queued.acknowledgement)
    assert is_nil(revision_queued.resolution)
    assert revision_item.action_id == revised_answer.action_id
    assert revision_item.correlation.decision_id == decision.decision_id
    assert revision_item.correlation.decision_version == decision.version
    assert revision_item.correlation.prior_action_id == original_action_id
    assert revision_item.correlation.revision_sequence == 1
    assert revision_item.correlation.actor.kind == :operator
    assert revision_item.body.text =~ "corrective, append-only direction"
    assert {:ok, :accepted} = DecisionStore.record_delivery(revision_item, store)

    revised_lifecycle = %{
      "decision_id" => decision.decision_id,
      "action_id" => revised_answer.action_id,
      "expected_version" => revised_answer.decision_version,
      "detail" => "Corrective direction applied"
    }

    assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
             DecisionStore.agent_lifecycle(:acknowledged, revised_lifecycle, lifecycle_opts, store)

    assert {:ok, %{status: :accepted, decision_status: :resolved}} =
             DecisionStore.agent_lifecycle(:resolved, revised_lifecycle, lifecycle_opts, store)

    assert {:ok, metrics_snapshot} = DecisionMetrics.snapshot(decision.decision_id, metrics)
    assert metrics_snapshot.revised
    assert metrics_snapshot.actor == "human"

    history = DecisionHistory.list(server: store, limit: 100)

    revised_history =
      Enum.find(history, fn entry ->
        entry.action_id == revised_answer.action_id and entry.revision_result == :dispatched
      end)

    assert revised_history.change == :revised
    assert revised_history.prior_action_id == original_action_id
    assert revised_history.revision_sequence == 1
    assert revised_history.choice == "Hold deployment until the incident closes"
    assert revised_history.actor.type == :human_operator

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)

    assert Enum.map(audit, fn
             %Decision{} -> :requested
             %DecisionEvent{type: type} -> type
           end) == [
             :requested,
             :answer_recorded,
             :dispatch_queued,
             :delivered,
             :acknowledged,
             :resolved,
             :revision_recorded,
             :revision_dispatched,
             :delivered,
             :acknowledged,
             :resolved
           ]

    detail_html = reload_view(view)
    assert detail_html =~ "Resolved"
    assert detail_html =~ "Revision 1"
    assert detail_html =~ "Revised"
    assert detail_html =~ "Event timeline"

    root_html = render_patch(view, "/units")
    refute root_html =~ "Command history"

    decisions_html = render_patch(view, "/commands")
    assert decisions_html =~ "Command history"
    assert decisions_html =~ "Hold deployment until the incident closes"
  end
end
