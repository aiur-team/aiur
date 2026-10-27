defmodule AiurWeb.DashboardLive.CommandLifecycleTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.Decision
  alias Aiur.DecisionApi
  alias Aiur.DecisionEvent
  alias Aiur.DecisionMetrics
  alias Aiur.DecisionMetrics.Canonical, as: DecisionMetricsCanonical
  alias Aiur.DecisionPubSub
  alias Aiur.DecisionStore
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.RecentMerge
  alias Aiur.RecentMergeStore
  alias AiurWeb.EndpointConfig

  @endpoint AiurWeb.Endpoint

  test "human dashboard answer traverses the real queue and target lifecycle" do
    orchestrator_name = Module.concat(__MODULE__, :CapstoneOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :CapstoneDecisionStore)
    metrics_name = Module.concat(__MODULE__, :CapstoneDecisionMetrics)
    recent_merge_store_name = Module.concat(__MODULE__, :CapstoneRecentMergeStore)

    orchestrator = start_queue_orchestrator(orchestrator_name, "987")

    store = start_decision_store(decision_store_name, dispatch_via(orchestrator), dispatch_delay_ms: 0)

    metrics = start_dashboard_metrics(metrics_name, store)
    recent_merges = start_recent_merge_store(recent_merge_store_name)
    decision = request_queue_decision(store, "dashboard-capstone", "987")
    assert :ok = DecisionPubSub.subscribe()

    assert {:ok, merge} =
             RecentMerge.from_github_event(merged_event(),
               live?: true,
               run_id: "capstone-run",
               now: ~U[2026-07-12 18:01:00Z]
             )

    assert {:ok, %{status: :accepted}} = RecentMergeStore.upsert(merge, recent_merges)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics,
      recent_merge_store: recent_merge_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    path = "/commands/#{decision.decision_id}"
    {:ok, view, html} = live(build_conn(), path)
    refute html =~ "Answer this Command"
    refute html =~ "Command latency"

    _html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "The integrated checks are green"}
      })

    assert_receive {:decision_changed, decision_id, 1}, 2_000
    assert decision_id == decision.decision_id
    assert_receive {:decision_changed, ^decision_id, 1}, 2_000
    assert {:ok, queued} = DecisionStore.get(decision.decision_id, store)
    assert queued.delivery_status == :queued
    assert queued.decision_status == :decided
    assert_receive {:agent_queue_updated, "987", queue_item_id, _delivery}, 2_000

    assert {:ok, %{id: ^queue_item_id} = item} =
             OperatorMessages.claim_next_queue_item(orchestrator, "987")

    assert item.correlation.decision_id == decision.decision_id
    assert item.action_id == queued.answer.action_id
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)
    assert reload_view(view) =~ "Delivered"

    lifecycle_payload = %{
      "decision_id" => decision.decision_id,
      "action_id" => item.action_id,
      "expected_version" => decision.version,
      "detail" => "Answer observed and applied"
    }

    lifecycle_opts = [
      ticket_identifier: "987",
      actor: %{kind: :agent, id: "ticket-agent"},
      source: %{agent_id: "codex", session_id: "capstone-session", invocation_id: "capstone-ack"}
    ]

    assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
             DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, store)

    assert reload_view(view) =~ "Acknowledged"

    assert {:ok, %{status: :accepted, decision_status: :resolved}} =
             DecisionStore.agent_lifecycle(
               :resolved,
               Map.put(lifecycle_payload, "detail", "Work completed"),
               lifecycle_opts,
               store
             )

    resolved_html = reload_view(view)
    assert resolved_html =~ "Resolved"
    assert resolved_html =~ "Resolved"
    refute render(view) =~ "Command not found"

    root_html = render_patch(view, "/units")
    refute root_html =~ "987"
    refute root_html =~ "Recent repository merges"
    refute root_html =~ "Command history"

    decisions_html = render_patch(view, "/commands")
    assert decisions_html =~ "Command history"
    assert decisions_html =~ "dashboard"

    detail_html = render_patch(view, path)
    assert detail_html =~ decision.decision_id
    assert detail_html =~ "Event timeline"
    assert detail_html =~ "Requested"
    refute detail_html =~ "Command not found"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)

    assert Enum.map(audit, fn
             %Decision{} -> :requested
             %DecisionEvent{type: type} -> type
           end) == [:requested, :answer_recorded, :dispatch_queued, :delivered, :acknowledged, :resolved]
  end

  test "connected cached dashboard converges from store-first revision to concrete metrics" do
    orchestrator_name = Module.concat(__MODULE__, :MetricsConvergenceOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :MetricsConvergenceDecisionStore)
    metrics_name = Module.concat(__MODULE__, :MetricsConvergenceDecisionMetrics)
    requested_at = ~U[2026-07-12 12:00:00.000Z]

    start_counting_orchestrator(orchestrator_name, report: self())
    orchestrator = GenServer.whereis(orchestrator_name)

    store =
      start_decision_store(
        decision_store_name,
        fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 508}}} end,
        dispatch_delay_ms: 60_000
      )

    metrics = start_dashboard_metrics(metrics_name, store, subscribe?: false)
    assert :ok = Exchange.subscribe("ticket.987.agent.decision.#")
    decision = request_queue_decision(store, "metrics-convergence", "987", now: requested_at)
    assert_receive {:event, %{topic: "ticket.987.agent.decision.requested"} = request_event}, 2_000

    assert {:ok, %{status: :accepted, action: original}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "metrics-convergence-answer",
                 "expected_version" => decision.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "operator"}, now: DateTime.add(requested_at, 2, :second)],
               store
             )

    assert_receive {:event, %{topic: "ticket.987.agent.decision.answered"} = answer_event}, 2_000

    assert {:ok, %{status: :accepted}} =
             DecisionStore.revise(
               decision.decision_id,
               %{
                 "idempotency_key" => "metrics-convergence-revision",
                 "expected_version" => decision.version,
                 "expected_action_id" => original.action_id,
                 "expected_revision_sequence" => 0,
                 "custom_response" => "Hold the cached rollout",
                 "rationale" => "New production evidence"
               },
               [actor: %{kind: :operator, id: "operator"}, now: DateTime.add(requested_at, 3, :second)],
               store
             )

    assert_receive {:event, %{topic: "ticket.987.agent.decision.revision-recorded"} = revision_event}, 2_000
    assert DecisionMetrics.snapshots(metrics) == %{}

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics_name,
      dashboard_writable: true
    )

    assert is_pid(EndpointConfig.get(:control_center_cache))

    path = "/commands/#{decision.decision_id}"
    {:ok, view, initial_html} = live(build_conn(), path)

    assert initial_html =~ "Hold the cached rollout"
    assert initial_html =~ "Revision 1"
    refute initial_html =~ "Command latency"
    refute_receive {:dashboard_payload_loaded, ^orchestrator, _count}, 100
    drain_dashboard_payload_notifications(orchestrator)
    assert :ok = DecisionPubSub.subscribe()

    for event <- [request_event, answer_event, revision_event] do
      assert :ok = DecisionMetrics.observe(event, metrics)
      assert_receive :decision_metrics_changed, 2_000
    end

    refute_receive {:dashboard_payload_loaded, ^orchestrator, _count}, 100
    converged_html = render(view)
    refute converged_html =~ "Command latency"
  end

  test "connected mount catches one metrics seed hint released between handshake mounts" do
    orchestrator_name = Module.concat(__MODULE__, :HandshakeOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :HandshakeDecisionStore)
    metrics_name = Module.concat(__MODULE__, :HandshakeDecisionMetrics)
    requested_at = ~U[2026-07-12 12:00:00.000Z]

    start_counting_orchestrator(orchestrator_name)

    store =
      start_decision_store(
        decision_store_name,
        fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 509}}} end,
        dispatch_delay_ms: 60_000
      )

    decision = request_queue_decision(store, "handshake-metrics", "987", now: requested_at)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "handshake-metrics-answer",
                 "expected_version" => decision.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "operator"}, now: DateTime.add(requested_at, 2, :second)],
               store
             )

    test_process = self()

    seed_fun = fn decision_store, limit ->
      send(test_process, {:metrics_seed_waiting, self()})

      receive do
        :release_metrics_seed -> DecisionMetricsCanonical.snapshot(decision_store, limit)
      end
    end

    metrics =
      start_dashboard_metrics(metrics_name, store,
        subscribe?: false,
        seed?: true,
        seed_fun: seed_fun
      )

    assert_receive {:metrics_seed_waiting, seed_process}, 2_000

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics_name
    )

    path = "/commands/#{decision.decision_id}"
    conn = get(build_conn(), path)
    disconnected_html = html_response(conn, 200)

    assert disconnected_html =~ "Recorded answer"
    refute disconnected_html =~ "Command latency"
    assert :ok = DecisionPubSub.subscribe()

    send(seed_process, :release_metrics_seed)
    assert :ok = DecisionMetrics.await_seed(metrics)
    assert_receive :decision_metrics_changed, 2_000
    refute_receive :decision_metrics_changed, 50

    {:ok, _view, connected_html} = live(conn)
    refute connected_html =~ "Command latency"
  end

  test "supervisor API mutations converge on LiveView without weakening human-required authority" do
    orchestrator_name = Module.concat(__MODULE__, :SupervisorCapstoneOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :SupervisorCapstoneDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: System.unique_integer([:positive])}}}
      end)

    start_counting_orchestrator(orchestrator_name)

    human = request_api_decision(store, "human-required", :human_required)

    delegated =
      request_api_decision(store, "supervisor-allowed", :supervisor_allowed,
        provenance: %{
          agent_family: "codex",
          backend: "codex-app-server",
          requested_model: "gpt-requested",
          resolved_model: "gpt-resolved",
          session_id: "history-thread",
          attempt_id: "history-attempt",
          source: "agent_runner"
        }
      )

    api_opts = supervisor_api_opts(store)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, human_html} = live(build_conn(), "/commands/#{human.decision_id}")
    refute human_html =~ "Human required"

    assert {:error, {:delegation_forbidden, %{reasons: [:human_required]}}} =
             DecisionApi.decide(human.decision_id, supervisor_decision_payload(1), api_opts)

    assert {:ok, current_human} = DecisionStore.get(human.decision_id, store)
    assert current_human.decision_status == :open
    assert is_nil(current_human.answer)

    delegated_path = "/commands/#{delegated.decision_id}"
    delegated_html = render_patch(view, delegated_path)
    assert delegated_html =~ ~s(phx-submit="answer-decision")

    assert {:ok, %{"status" => "accepted", "decision" => enriched}} =
             DecisionApi.enrich(
               delegated.decision_id,
               %{
                 "expected_version" => 1,
                 "context" => %{"short_summary" => "Supervisor-enriched canonical context"}
               },
               api_opts
             )

    assert enriched["version"] == 2
    assert reload_view(view) =~ "Supervisor-enriched canonical context"

    assert {:ok, decided} =
             DecisionApi.decide(
               delegated.decision_id,
               supervisor_decision_payload(2),
               api_opts
             )

    action_id = decided["action"]["action_id"]
    assert decided["action"]["actor"] == %{"kind" => "supervisor", "id" => "supervising-agent", "source" => "supervisor_api"}
    assert reload_view(view) =~ "Use the canonical path"

    assert {:ok, revised} =
             DecisionApi.revise(
               delegated.decision_id,
               supervisor_revision_payload(action_id, 2),
               api_opts
             )

    assert revised["action"]["answer"]["actor"] == %{
             "kind" => "supervisor",
             "id" => "supervising-agent",
             "source" => "supervisor_api"
           }

    detail_html = reload_view(view)
    assert detail_html =~ "Use the corrected path"
    assert detail_html =~ "Original answer · preserved"
    assert detail_html =~ "Revision 1"
    refute detail_html =~ "Command not found"

    _root_html = render_patch(view, "/units")
    root_html = reload_view(view)
    refute root_html =~ "Command history"

    decisions_html = render_patch(view, "/commands")
    assert decisions_html =~ "Command history"

    _filtered_html = render_patch(view, "/commands?filter=supervisor")
    filtered_list = view |> element(".decision-list") |> render()
    assert filtered_list =~ delegated.question
    refute filtered_list =~ human.question
  end
end
