defmodule AiurWeb.OperatorControlCenterComponentsTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.BuildOrderViewModel.Node

  alias AiurWeb.OperatorControlCenter.{
    BuildOrderGraph,
    BuildOrderIcon,
    DecisionAction,
    DecisionDetail,
    DecisionInbox,
    DecisionLatency,
    DecisionRevisionAction,
    FleetFilters,
    FleetTable,
    History,
    LifecycleComponents,
    Overview
  }

  test "renders semantic graph cards and preserves every dependency state in the fallback summary" do
    html =
      render_component(&BuildOrderGraph.build_order_graph/1, %{
        id: "build-order-graph",
        root_id: "root-1",
        provider_generation: 4,
        dom_generation: 8,
        layout_assets: %{client: "/client.js", worker: "/worker.js", engine: "/engine.js"},
        nodes: [
          %{id: "BO-010", title: "DOM and SVG layout", summary: "Keep cards semantic.", lane: 0, phase: 3},
          %{id: "BO-012", title: "Graph markup", lane: 1, phase: 4}
        ],
        edges: [
          %{id: "edge-cleared", source: "BO-010", target: "BO-012", state: :cleared},
          %{id: "edge-blocking", source: "BO-012", target: "BO-010", state: :blocking},
          %{id: "edge-terminal", source: "BO-010", target: "BO-404", state: :terminal_unsatisfied},
          %{id: "edge-unknown", source: "BO-404", target: "BO-010", state: :unknown},
          %{id: "edge-cycle", source: "BO-012", target: "BO-012", state: :cyclic}
        ]
      })

    assert html =~ ~s(phx-hook="DomSvgLayout")
    assert html =~ ~s(data-layout-root-id="root-1")
    assert html =~ ~s(data-layout-provider-generation="4")
    assert html =~ ~s(data-layout-dom-generation="8")
    assert html =~ ~s(data-layout-adapter-url="/aiur-dom-svg-layout-adapter.js")
    assert html =~ ~s(data-layout-node-id="BO-010")
    assert html =~ ~s(data-layout-card-header)
    assert html =~ ~s(aria-hidden="true")
    assert html =~ "Cleared"
    assert html =~ "Blocking"
    assert html =~ "Terminal unsatisfied"
    assert html =~ "Unknown"
    assert html =~ "Cyclic"
    assert html =~ "is clear of"
    assert html =~ "leaves terminally unsatisfied"
    assert html =~ "has an unknown dependency relation to"
    assert html =~ "is cyclic with"
    assert html =~ "Using readable document-flow layout."

    # BO-013 interaction + accessibility scaffolding.
    assert html =~ ~s(data-graph-viewport)
    assert html =~ ~s(data-graph-content)
    assert html =~ ~s(role="group" aria-label="Build order graph canvas")
    assert html =~ ~s(data-graph-zoom="in")
    assert html =~ ~s(data-graph-zoom="out")
    assert html =~ ~s(data-graph-zoom="fit")
    assert html =~ ~s(data-graph-zoom="reset")
    assert html =~ ~s(aria-label="Zoom graph in")
    assert html =~ ~s(data-graph-zoom-level)
    assert html =~ ~s(data-graph-announce)
    assert html =~ ~s(aria-live="polite")
    assert html =~ "Keyboard help"
    # Every card is focusable and carries a stable node identifier for the hook.
    assert html =~ ~s(tabindex="0")
    assert html =~ ~s(data-graph-node="BO-010")

    # BO-1270 parity: a visible edge legend keys the graph's cleared/blocking edges.
    assert html =~ ~s(class="bo-graph-legend")
  end

  test "renders transitive dependency-chain closures as sanitized card data attributes" do
    html =
      render_component(&BuildOrderGraph.build_order_graph/1, %{
        id: "chain-graph",
        root_id: "root-1",
        provider_generation: 1,
        dom_generation: 1,
        layout_assets: %{client: "/client.js", worker: "/worker.js", engine: "/engine.js"},
        model: chain_view_model()
      })

    # a -> b -> c (blocker -> blocked). b depends on a (upstream) and is
    # depended on by c (downstream).
    assert html =~ ~r/data-graph-node="b"[^>]*data-graph-upstream="a"[^>]*data-graph-downstream="c"/s
    assert html =~ ~r/data-graph-node="a"[^>]*data-graph-downstream="b c"/s
    # Root of the chain has no upstream attribute rendered.
    refute html =~ ~r/data-graph-node="a"[^>]*data-graph-upstream=/s
  end

  defp chain_view_model do
    %AiurWeb.BuildOrderViewModel{
      status: :ready,
      nodes: [chain_node("a"), chain_node("b"), chain_node("c")],
      edges: [],
      adjacency: %{"a" => ["b"], "b" => ["c"], "c" => []},
      reverse_adjacency: %{"a" => [], "b" => ["a"], "c" => ["b"]}
    }
  end

  defp chain_node(id) do
    %AiurWeb.BuildOrderViewModel.Node{
      key: id,
      identity: nil,
      title: "Node #{id}",
      plan: %{},
      execution: %{},
      activity: %{},
      readiness: :ready,
      lane_icon: nil,
      status_icon: nil,
      health: %{},
      observed_at: %{},
      provenance: %{planning_generation: 1, activity_generation: 1},
      diagnostics: [],
      card: %{
        identifier: id,
        lane: 0,
        phase: 1,
        status_text: nil,
        lifecycle: %{state: :open, state_reason: :none},
        execution_state: :idle,
        agent_stage: nil,
        progress: nil
      }
    }
  end

  test "renders every presenter-derived icon key through accessible local components" do
    keys = [
      :lane_plan_graph,
      :lane_runtime,
      :lane_dashboard_ui,
      :lane_accounting,
      :lane_platform,
      :lane_generic,
      :status_ready,
      :status_blocking,
      :status_terminal_unsatisfied,
      :status_unknown,
      :status_cyclic,
      :status_generic,
      :status_completed,
      :status_not_planned,
      :status_paused,
      :status_retrying,
      :status_waiting,
      :status_working
    ]

    for key <- keys do
      label = "Accessible #{key}"

      html =
        render_component(&BuildOrderIcon.build_order_icon/1, %{
          icon: %Aiur.BuildOrder.Icon{key: key, text: label}
        })

      assert html =~ ~s(data-icon-key="#{key}")
      assert html =~ ~s(aria-label="#{label}")
      assert html =~ ~s(aria-hidden="true")
    end

    fallback =
      render_component(&BuildOrderIcon.build_order_icon/1, %{
        icon: %Aiur.BuildOrder.Icon{key: :from_github_fixture, text: "unsafe fixture icon"}
      })

    assert fallback =~ ~s(data-icon-key="generic")
    assert fallback =~ ~s(aria-label="Status unavailable")
    refute fallback =~ "from_github_fixture"
    refute fallback =~ "unsafe fixture icon"
  end

  test "renders typed card progress and agent stage without replacing unknown facts" do
    known = %Node{
      key: :known,
      identity: nil,
      title: "Known activity",
      plan: %{complexity: 3},
      execution: %{},
      activity: %{},
      readiness: :ready,
      lane_icon: nil,
      status_icon: nil,
      health: %{},
      observed_at: %{},
      provenance: %{},
      card: %{
        identifier: "#1",
        lane: "dashboard-ui",
        phase: 1,
        lifecycle: %{state: :open, state_reason: :none},
        execution_state: :working,
        agent_stage: :review,
        progress: 60,
        status_text: "Working"
      }
    }

    unknown = %{
      known
      | key: :unknown,
        title: "Unknown activity",
        card: %{known.card | identifier: "#2", agent_stage: :unknown, progress: :unknown}
    }

    html =
      render_component(&BuildOrderGraph.build_order_graph/1, %{
        id: "typed-build-order-graph",
        root_id: "root-1",
        provider_generation: 1,
        dom_generation: 1,
        layout_assets: %{client: "/client.js", worker: "/worker.js", engine: "/engine.js"},
        nodes: [known, unknown],
        edges: []
      })

    assert html =~ "Agent stage"
    assert html =~ "Review"
    assert html =~ "60%"
    assert html =~ "Agent stage unavailable"
    assert html =~ "Progress unavailable"
    assert html =~ ~s(aria-label="#1 · Known activity · Working · Dashboard ui · Phase 1 · Review · 60%")

    # BO-1270 parity: complexity badge and a visual progress bar surface on the
    # node card itself, replacing the 7-row fact grid and the generation
    # provenance line.
    assert html =~ ~s(class="bo-cx")
    assert html =~ "Cx:3"
    assert html =~ ~s(class="bo-layout-card-progress")
    assert html =~ "width:60%"
    refute html =~ "planning gen"
  end

  test "renders delivery failure and supersession as explicit lifecycle overrides" do
    failed = render_component(&LifecycleComponents.lifecycle_stepper/1, %{lifecycle: :delivery_failed})
    superseded = render_component(&LifecycleComponents.lifecycle_stepper/1, %{lifecycle: :superseded})

    assert failed =~ "Recorded"
    assert failed =~ "Dispatch pending"
    assert failed =~ "Delivery failed"
    assert failed =~ "Acknowledged"
    assert failed =~ "Resolved"
    refute failed =~ "rolled back"

    assert superseded =~ "Superseded — replaced by a newer Command"
    refute superseded =~ "Resolved"
  end

  test "renders path artifacts as text and only links trusted http URLs" do
    decision = %{
      decision_id: "dec-artifacts",
      version: 1,
      ticket: %{identifier: "AIUR-987", title: "OCC", url: "javascript:alert(1)"},
      source: %{agent_id: "agent-987"},
      authority: :human_required,
      urgency: :normal,
      blocking: false,
      reversibility: :reversible,
      question: "Are links safe?",
      context: %{short: nil, long_markdown: "Recorded context"},
      options: [],
      recommendation: nil,
      consequence_of_delay: nil,
      artifacts: [
        %{kind: :path, value: "src/lib/aiur_web/router.ex"},
        %{kind: :url, value: "javascript:alert(2)"},
        %{kind: :url, value: "https://example.test/evidence"}
      ],
      created_at: ~U[2026-07-12 12:00:00Z],
      decision_status: :open,
      delivery_status: :not_dispatched,
      answer: nil,
      retryable: false,
      failure_reason: nil,
      lifecycle: :recorded
    }

    html = render_component(&DecisionDetail.decision_detail/1, %{decision: decision, history: [], writable: false})

    assert html =~ "src/lib/aiur_web/router.ex"
    assert html =~ ~s(href="https://example.test/evidence")
    refute html =~ ~s(href="javascript:alert)
  end

  test "renders OCC-6 actor and revision follow-up facts without guessing attribution" do
    entry = %{
      decision_id: "dec-history",
      ticket: %{identifier: "AIUR-983"},
      question: "What should happen after the target became terminal?",
      changed_at: ~U[2026-07-12 13:00:00Z],
      change: :follow_up_required,
      actor: %{type: :human_operator, id: "operator", label: "Executor"},
      choice: nil,
      rationale: "The revision could not be dispatched.",
      dispatch_result: :failed,
      acknowledgement_result: :pending,
      revision_result: :no_longer_applicable,
      revised?: true,
      follow_up_required: true,
      follow_up_handled: false
    }

    html = render_component(&History.history/1, %{entries: [entry], provider_health: :ok})

    assert html =~ "Executor"
    assert html =~ "Follow-up required"
    assert html =~ "dispatch: Failed"
    assert html =~ "revision: No longer applicable"
    refute html =~ "supervising agent"
  end

  test "gives fleet icon actions accessible names" do
    fleet = %{
      running: [
        %{
          issue_identifier: "AIUR-987",
          title: "Operator Control Center",
          state: "in-progress",
          work_state: :working,
          waiting_reason: :active,
          last_message: "Reviewing the dashboard",
          runtime_seconds: 60,
          open_decision_count: 1,
          url: "https://example.test/issues/987"
        }
      ],
      retrying: [],
      idle: []
    }

    decisions = [%{decision_id: "dec-accessible", ticket: %{identifier: "AIUR-987"}}]

    html =
      render_component(&FleetTable.fleet_table/1, %{
        fleet: fleet,
        decisions: decisions,
        now: ~U[2026-07-12 13:00:00Z]
      })

    assert html =~ ~s(aria-label="Open pending Command")
    assert html =~ ~s(aria-label="Read agent conversation")
    assert html =~ ~s(aria-label="Open tracker ticket")
    assert html =~ ~s(data-label="Ticket")
    assert html =~ ~s(data-label="Latest")
    assert html =~ ~s(data-label="Elapsed")
    assert html =~ ~s(data-label="Commands")
  end

  test "filters real fleet states cumulatively with the latest responsive overview" do
    fleet = %{
      running: [
        fleet_row("AIUR-1", :active),
        fleet_row("AIUR-2", :waiting_for_human),
        fleet_row("AIUR-3", :paused)
      ],
      retrying: [fleet_row("AIUR-4", :backing_off)],
      idle: [fleet_row("AIUR-5", :active, state: "done")]
    }

    default_html =
      render_component(&FleetTable.fleet_table/1, %{
        fleet: fleet,
        decisions: [],
        now: ~U[2026-07-12 13:00:00Z]
      })

    assert default_html =~ "AIUR-1"
    assert default_html =~ "AIUR-2"
    assert default_html =~ "AIUR-3"
    assert default_html =~ "AIUR-4"
    refute default_html =~ "AIUR-5"
    assert default_html =~ ~s(phx-value-filter="finished")
    assert default_html =~ ~s(aria-label="Fleet filters")

    filters = FleetFilters.default() |> FleetFilters.toggle(:running) |> FleetFilters.toggle(:finished)

    filtered_html =
      render_component(&FleetTable.fleet_table/1, %{
        fleet: fleet,
        decisions: [],
        now: ~U[2026-07-12 13:00:00Z],
        filters: filters
      })

    refute filtered_html =~ "AIUR-1"
    assert filtered_html =~ "AIUR-2"
    assert filtered_html =~ "AIUR-5"
  end

  test "decision banner uses canonical retained counts and hides when none await input" do
    answered = %{decision_id: "dec-answered", blocking: true, lifecycle: :resolved}
    open = %{decision_id: "dec-open", blocking: false, lifecycle: :recorded}

    html =
      render_component(&Overview.decisions_banner/1, %{
        decisions: [answered, open],
        retained_counts: %{open: 1, blocking: 0, health: %{status: :available}}
      })

    empty_html =
      render_component(&Overview.decisions_banner/1, %{
        decisions: [answered],
        retained_counts: %{open: 0, blocking: 0, health: %{status: :available}}
      })

    assert html =~ ~s(href="/decisions")
    assert html =~ "1 Command is awaiting you"
    refute empty_html =~ "decisions-banner"
  end

  defp fleet_row(identifier, waiting_reason, attrs \\ []) do
    Map.merge(
      %{
        issue_identifier: identifier,
        title: "Ticket #{identifier}",
        state: "in-progress",
        work_state: :working,
        waiting_reason: waiting_reason,
        runtime_seconds: 60,
        open_decision_count: 0
      },
      Map.new(attrs)
    )
  end

  test "distinguishes degraded decision history from an unavailable provider" do
    html = render_component(&History.history/1, %{entries: [], provider_health: :degraded})

    assert html =~ "Command history is degraded"
    refute html =~ "currently unavailable"
  end

  test "Commands inbox exposes only the four primary filters with canonical retained counts" do
    html =
      render_inbox(
        [inbox_decision("dec-overview-only")],
        :all,
        %{total: 701, open: 503, blocking: 401}
      )

    assert html =~ ~r/All\s+<span class="count num">701<\/span>/
    assert html =~ ~r/Open\s+<span class="count num">503<\/span>/
    assert html =~ ~r/Blocking\s+<span class="count num">401<\/span>/
    assert html =~ "Commands inbox"
    assert html =~ "Resolved"
    refute html =~ ~r/>Undelivered\s+<span class="count num">/
    refute html =~ ~r/>Supervisor\s+<span class="count num">/
    refute html =~ ~r/>Superseded\s+<span class="count num">/
  end

  test "renders a writable canonical answer form with destructive confirmation" do
    decision = action_decision(reversibility: :irreversible, kind: "destructive_op")

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ ~s(name="answer[choice]")
    assert html =~ "Persisted before dispatch"
    assert html =~ "I understand this Command is irreversible or destructive."
    assert html =~ "Record answer"
  end

  test "renders canonical answer evidence and gates failed-delivery retry by writable mode" do
    answer = %{
      action_id: "act-dashboard",
      decision_version: 1,
      selected_option_id: "ship",
      custom_response: nil,
      rationale: "Checks are green",
      actor: %{kind: :operator, id: "dashboard"},
      accepted_at: ~U[2026-07-12 13:00:00Z]
    }

    decision =
      action_decision(
        decision_status: :decided,
        delivery_status: :failed,
        lifecycle: :delivery_failed,
        answer: answer,
        retryable: true,
        failure_reason: "target_agent_unavailable"
      )

    writable = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})
    readonly = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: false})

    assert writable =~ "Checks are green"
    assert writable =~ "Delivery · Failed"
    assert writable =~ ~s(phx-click="retry-decision")
    assert writable =~ "Target agent unavailable"
    refute readonly =~ ~s(phx-click="retry-decision")
    refute readonly =~ ~s(phx-submit="answer-decision")
  end

  test "renders canonical OCC-9 latency with accessible labels and honest pending fields" do
    latency = %{
      status: :available,
      snapshot: %{
        request_to_decision_ms: 250,
        decision_to_dispatch_ms: 1_500,
        dispatch_to_delivery_ms: nil,
        delivery_to_ack_ms: nil,
        blocked_time_ms: 1_750,
        reminder_count: 2,
        attention_count: 3,
        actor: "human",
        revised: true
      }
    }

    html = render_component(&DecisionLatency.decision_latency/1, %{latency: latency})

    assert html =~ ~s(aria-labelledby="decision-latency-title")
    assert html =~ "Request to Command"
    assert html =~ "250 ms"
    assert html =~ "Command to dispatch"
    assert html =~ "1.5 s"
    assert html =~ "Dispatch to delivery"
    assert html =~ "Pending"
    assert html =~ "Blocked time"
    assert html =~ "2 reminders"
    assert html =~ "3 attentions"
    assert html =~ "Human"
    assert html =~ "Revised"
  end

  test "distinguishes a missing latency sample from an unavailable provider" do
    missing = render_component(&DecisionLatency.decision_latency/1, %{latency: %{status: :missing, snapshot: nil}})

    unavailable =
      render_component(&DecisionLatency.decision_latency/1, %{
        latency: %{status: :unavailable, snapshot: nil}
      })

    assert missing =~ "No latency sample has been retained for this Command yet."
    refute missing =~ "provider is unavailable"
    assert unavailable =~ "Command latency provider is unavailable."
  end

  test "renders an append-only revision chain and gates its parent follow-up" do
    original = action_answer(:operator)

    revised = %{
      original
      | action_id: "act-revision",
        selected_option_id: nil,
        custom_response: "Hold the rollout",
        rationale: "New production evidence"
    }

    decision =
      action_decision(
        decision_status: :decided,
        delivery_status: :not_dispatched,
        answer: revised,
        original_answer: original,
        active_action_id: revised.action_id,
        revision_sequence: 1,
        revisions: [
          %{
            sequence: 1,
            action_id: revised.action_id,
            prior_action_id: original.action_id,
            answer: revised,
            reason: "New production evidence",
            result: :no_longer_applicable
          }
        ],
        revision_follow_ups: %{
          revised.action_id => %{
            action_id: revised.action_id,
            question: "What should happen next?",
            handled_at: nil
          }
        }
      )

    writable =
      render_component(&DecisionRevisionAction.decision_revision_action/1, %{
        decision: decision,
        state: %{},
        writable: true
      })

    readonly =
      render_component(&DecisionRevisionAction.decision_revision_action/1, %{
        decision: decision,
        state: %{},
        writable: false
      })

    assert writable =~ "Original answer · preserved"
    assert writable =~ "Hold the rollout"
    assert writable =~ "No longer applicable"
    assert writable =~ "does not claim earlier effects were rolled back"
    assert writable =~ "Executor follow-up required"
    assert writable =~ ~s(phx-submit="revise-decision")
    assert writable =~ ~s(phx-submit="handle-revision-follow-up")
    assert readonly =~ "Original answer · preserved"
    assert readonly =~ "Executor follow-up required"
    refute readonly =~ ~s(phx-submit="revise-decision")
    refute readonly =~ ~s(phx-submit="handle-revision-follow-up")
  end

  test "keeps every secondary lifecycle state visible under the primary All filter" do
    operator_answer = action_answer(:operator)
    supervisor_answer = action_answer(:supervisor)

    decisions = [
      inbox_decision("dec-open"),
      inbox_decision("dec-undelivered",
        decision_status: :decided,
        delivery_status: :queued,
        lifecycle: :dispatch_pending,
        answer: operator_answer
      ),
      inbox_decision("dec-supervisor",
        decision_status: :decided,
        delivery_status: :delivered,
        lifecycle: :delivered,
        answer: supervisor_answer
      ),
      inbox_decision("dec-resolved",
        decision_status: :resolved,
        delivery_status: :delivered,
        lifecycle: :resolved,
        answer: operator_answer
      ),
      inbox_decision(
        "dec-superseded",
        decision_status: :decided,
        delivery_status: :delivered,
        lifecycle: :delivered,
        answer: operator_answer,
        superseded?: true
      )
    ]

    all = render_inbox(decisions, :all)
    resolved = render_inbox(decisions, :resolved)

    assert all =~ "Question dec-undelivered"
    assert all =~ "Question dec-supervisor"
    assert all =~ "Question dec-superseded"
    assert all =~ "Dispatch pending"
    assert all =~ "Supervisor answer"
    assert all =~ "Superseded"
    assert resolved =~ "Question dec-resolved"
    refute resolved =~ "Question dec-superseded"
  end

  test "renders trusted provenance, exact confidence, and bounded option previews without prose inference" do
    decision =
      inbox_decision("dec-provenance",
        options: [
          %{id: "one", label: "First option", description: "One", risk: "low"},
          %{id: "two", label: "Second option", description: "Two", risk: "medium"},
          %{id: "three", label: "Hidden third option", description: "Three", risk: "high"}
        ],
        answer:
          action_answer(:supervisor)
          |> Map.put(:selected_option_id, "two")
          |> Map.put(:supervisor_basis, %{confidence: 0}),
        provenance: %{
          agent_family: "codex",
          backend: "codex",
          requested_model: "requested-model",
          resolved_model: "resolved-model"
        }
      )

    html = render_inbox([decision], :all)

    assert html =~ "codex · resolved-model"
    assert html =~ "0% confidence"
    assert html =~ "Selected · Second option"
    assert html =~ "First option"
    assert html =~ "Second option"
    refute html =~ "Hidden third option"
  end

  test "Command detail renders canonical runtime provenance and exact supervisor confidence" do
    answer = action_answer(:supervisor) |> Map.put(:supervisor_basis, %{"confidence" => 37})

    decision =
      inbox_decision("dec-detail-provenance",
        answer: answer,
        decision_status: :decided,
        delivery_status: :queued,
        lifecycle: :dispatch_pending,
        provenance: %{
          agent_family: "codex",
          backend: "codex-app-server",
          requested_model: "gpt-requested",
          resolved_model: "gpt-resolved",
          attempt_id: "attempt-37",
          captured_at: ~U[2026-07-12 13:00:00Z]
        }
      )

    html =
      render_component(&DecisionDetail.decision_detail/1, %{
        decision: decision,
        history: [],
        writable: false
      })

    assert html =~ "Command metadata"
    assert html =~ "Supervisor confidence"
    assert html =~ "37%"
    assert html =~ "codex-app-server"
    assert html =~ "gpt-resolved"
    assert html =~ "attempt-37"
    refute html =~ "Runtime provenance was not recorded"
  end

  defp action_decision(attrs) do
    defaults = %{
      decision_id: "dec-action",
      version: 1,
      kind: "architecture",
      reversibility: :reversible,
      decision_status: :open,
      delivery_status: :not_dispatched,
      lifecycle: :recorded,
      options: [%{id: "ship", label: "Ship it", description: "Proceed", risk: "low"}],
      recommendation: %{option_id: "ship", reason: "Smallest safe change"},
      answer: nil,
      retryable: false,
      failure_reason: nil
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp action_answer(kind) do
    %{
      action_id: "act-#{kind}",
      decision_version: 1,
      selected_option_id: "ship",
      custom_response: nil,
      rationale: nil,
      actor: %{kind: kind, id: Atom.to_string(kind)},
      accepted_at: ~U[2026-07-12 13:00:00Z]
    }
  end

  defp inbox_decision(decision_id, attrs \\ []) do
    defaults = %{
      decision_id: decision_id,
      version: 1,
      ticket: %{identifier: "AIUR-987", title: "OCC"},
      source: %{agent_id: "agent-987"},
      kind: "architecture",
      authority: :human_required,
      urgency: :normal,
      blocking: false,
      reversibility: :reversible,
      question: "Question #{decision_id}",
      context: %{short: nil, long_markdown: nil},
      options: [%{id: "ship", label: "Ship it", description: "Proceed", risk: "low"}],
      recommendation: nil,
      consequence_of_delay: nil,
      artifacts: [],
      created_at: ~U[2026-07-12 12:00:00Z],
      decision_status: :open,
      delivery_status: :not_dispatched,
      answer: nil,
      retryable: false,
      failure_reason: nil,
      superseded?: false,
      lifecycle: :recorded
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp render_inbox(decisions, filter, retained_counts \\ nil) do
    retained_counts =
      retained_counts ||
        %{
          total: length(decisions),
          open: Enum.count(decisions, &(&1.decision_status == :open)),
          blocking: Enum.count(decisions, &(&1.blocking and &1.decision_status == :open))
        }

    render_component(&DecisionInbox.decision_inbox/1, %{
      decisions: decisions,
      selected_decision_id: nil,
      filter: filter,
      now: ~U[2026-07-12 13:00:00Z],
      history: [],
      action_states: %{},
      writable: false,
      provider_health: :ok,
      retained_counts: retained_counts
    })
  end
end
