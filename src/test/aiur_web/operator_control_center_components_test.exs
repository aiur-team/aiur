defmodule AiurWeb.OperatorControlCenterComponentsTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.BuildOrder.Icon

  alias AiurWeb.OperatorControlCenter.{BuildOrderGraph, BuildOrderIcon, DecisionDetail, FleetTable, LifecycleComponents}

  import AiurWeb.OperatorControlCenterComponentsFixtures

  test "renders the epic-by-wave grid with cards, legend, and zoom controls" do
    html =
      render_component(&BuildOrderGraph.build_order_graph/1, %{
        id: "build-order-graph",
        root_id: "root-1",
        provider_generation: 4,
        dom_generation: 8,
        model: sample_view_model()
      })

    # New grid hook replaces the ELK DomSvgLayout hook.
    assert html =~ ~s(phx-hook="BuildOrderGrid")
    refute html =~ "DomSvgLayout"

    # Epic column headers with counts (Metadata lane order).
    assert html =~ "Plan graph"
    assert html =~ "Dashboard UI"
    assert html =~ ~s(class="bo-epic-count">2<)

    # Wave rows.
    assert html =~ ~s(class="bo-wave-n">W3<)
    assert html =~ ~s(class="bo-wave-n">W4<)

    # Cards carry a stable id and state class; merged forces 100%.
    assert html =~ ~s(data-bo-card="BO-010")
    assert html =~ ~s(class="bo-node is-merged")
    assert html =~ "Cx 3"
    assert html =~ "merged"
    assert html =~ "agent live"
    assert html =~ "dependency-ready"

    # Edges are handed to the hook as sanitized source/target/state data.
    assert html =~ ~s(data-bo-edge-source="BO-010")
    assert html =~ ~s(data-bo-edge-target="BO-012")
    assert html =~ ~s(data-bo-edge-state="cleared")
    assert html =~ ~s(data-bo-edge-state="blocking")

    # Legend keys the four states the prototype shows.
    assert html =~ "agent live"
    assert html =~ ">cleared<"
    assert html =~ ">blocking<"

    # Zoom controls: out / in / fit only. No Reset, no Keyboard help.
    assert html =~ ~s(data-bo-zoom="out")
    assert html =~ ~s(data-bo-zoom="in")
    assert html =~ ~s(data-bo-zoom="fit")
    refute html =~ ~s(data-bo-zoom="reset")
    refute html =~ "Keyboard help"

    assert html =~ ~s(data-bo-grid-viewport)
    assert html =~ ~s(data-bo-zoom-level)
  end

  test "places an Ad Hoc overlay column beside the planning lanes" do
    adhoc = %{
      status: :ready,
      total: 1,
      rows: [
        %{
          identifier: "1247",
          title: "Runtime restart gate",
          href: nil,
          lifecycle: :closed,
          phase: 3,
          complexity: 4,
          running?: false,
          progress: nil
        }
      ]
    }

    html =
      render_component(&BuildOrderGraph.build_order_graph/1, %{
        id: "adhoc-graph",
        root_id: "root-1",
        provider_generation: 1,
        dom_generation: 1,
        model: sample_view_model(),
        adhoc: adhoc
      })

    assert html =~ "Ad Hoc"
    # Closed ad hoc ticket renders merged at 100%.
    assert html =~ ~s(data-bo-card="1247")
    assert html =~ ~s(class="bo-epic-count">1<)
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

  test "renders typed card progress, complexity, and a progress bar" do
    known =
      node(:known, "#1", "dashboard-ui", 1,
        title: "Known activity",
        complexity: 3,
        status_icon: %Icon{key: :status_working, text: "Agent working"},
        progress: 60,
        status_text: "Working"
      )

    unknown = %{
      known
      | key: :unknown,
        title: "Unknown activity",
        status_icon: %Icon{key: :status_blocking, text: "Blocked"},
        card: %{
          known.card
          | identifier: "#2",
            lifecycle: %{state: :unknown, state_reason: :unknown},
            progress: :unknown,
            status_text: "Blocked"
        }
    }

    html =
      render_component(&BuildOrderGraph.build_order_graph/1, %{
        id: "typed-build-order-graph",
        root_id: "root-1",
        provider_generation: 1,
        dom_generation: 1,
        model: %AiurWeb.BuildOrderViewModel{status: :ready, nodes: [known, unknown], edges: []}
      })

    # Known-progress card surfaces its percent, an "agent live" word, a cx badge
    # and a visual progress bar.
    assert html =~ "60%"
    assert html =~ "agent live"
    assert html =~ ~s(class="bo-node-cx")
    assert html =~ "Cx 3"
    assert html =~ ~s(class="bo-node-blocks")
    assert html =~ "width:60%"
    assert html =~ ~r/class="bo-epic-count"[^>]*>30% partial</
    assert html =~ ~r/class="bo-wave-seg-pct"[^>]*>30% partial</

    # Unresolved-progress cards expose neither a false percentage nor a zero-width bar.
    assert html =~ ~s(data-bo-card="#2")
    assert html =~ "Blocked"
    assert html =~ ~r/data-progress-state="unresolved"[^>]*>unresolved</

    {:ok, document} = Floki.parse_document(html)
    [unknown_aria] = Floki.attribute(document, ~s([data-bo-card="#2"]), "aria-label")
    assert unknown_aria =~ "unresolved"
    refute unknown_aria =~ "0%"
    assert Floki.find(document, ~s([data-bo-card="#2"] .bo-node-bar)) == []
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

  test "omits links and artifacts from the focused Command detail" do
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

    assert html =~ "Recorded context"
    refute html =~ "src/lib/aiur_web/router.ex"
    refute html =~ ~s(href="https://example.test/evidence")
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

    decision = inbox_decision("dec-history", decision_status: :decided, answer: action_answer(:operator))

    html =
      render_component(&DecisionDetail.decision_detail/1, %{
        decision: decision,
        history: [entry],
        writable: false
      })

    assert html =~ "Executor"
    assert html =~ "Follow-up required"
    assert html =~ "dispatch: Failed"
    assert html =~ "revision: No longer applicable"
    refute html =~ "supervising agent"
  end

  test "names the model a fleet row is running, titled with the raw id" do
    # Units and Fleet are two views of the same agents; a model named on one
    # and missing on the other makes an operator cross-check to answer "what
    # is this actually running on".
    fleet = %{
      running: [
        %{
          issue_identifier: "AIUR-987",
          title: "Operator Control Center",
          state: "in-progress",
          work_state: :working,
          waiting_reason: :active,
          runtime_seconds: 60,
          open_decision_count: 0,
          backend: "claude",
          requested_model: "opus",
          resolved_model: "claude-opus-5-1"
        }
      ],
      retrying: [],
      idle: []
    }

    html =
      render_component(&FleetTable.fleet_table/1, %{
        fleet: fleet,
        decisions: [],
        now: ~U[2026-07-12 13:00:00Z]
      })

    assert html =~ ~s(class="u-pill u-model" title="claude-opus-5-1">OPUS 5.1</span>)
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
end
