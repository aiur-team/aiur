defmodule AiurWeb.OperatorControlCenterComponentsTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.BuildOrder.{Diagnostic, Icon, ProviderHealth}
  alias AiurWeb.BuildOrder.RouteState
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}

  alias AiurWeb.OperatorControlCenter.{
    BuildOrderGraph,
    BuildOrderIcon,
    BuildOrderSelected,
    DecisionAction,
    DecisionCard,
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
    assert html =~ ~s(class="bo-epic-count">60% partial<)
    assert html =~ ~s(class="bo-wave-seg-pct">60% partial<)

    # Unresolved-progress cards expose neither a false percentage nor a zero-width bar.
    assert html =~ ~s(data-bo-card="#2")
    assert html =~ "Blocked"
    assert html =~ ~s(data-progress-state="unresolved">unresolved<)

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
      idle: [
        fleet_row("AIUR-5", :active, state: "done"),
        fleet_row("AIUR-6", :tracker_unavailable)
      ]
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
    assert default_html =~ "AIUR-6"
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
    assert filtered_html =~ "AIUR-6"
  end

  test "decision banner uses canonical retained counts and hides when none await input" do
    answered = %{decision_id: "dec-answered", blocking: true, lifecycle: :resolved}
    open = %{decision_id: "dec-open", blocking: false, lifecycle: :recorded}

    html =
      render_component(&Overview.decisions_banner/1, %{
        decisions: [answered, open],
        retained_counts: %{open: 1, blocking: 0, awaiting: 1, awaiting_blocking: 0, health: %{status: :available}}
      })

    empty_html =
      render_component(&Overview.decisions_banner/1, %{
        decisions: [answered],
        retained_counts: %{open: 0, blocking: 0, awaiting: 0, awaiting_blocking: 0, health: %{status: :available}}
      })

    assert html =~ ~s(href="/commands")
    assert html =~ "1 unit awaiting commands"
    refute empty_html =~ "decisions-banner"
  end

  test "decision banner count equals the open Commands list even when only some block" do
    html =
      render_component(&Overview.decisions_banner/1, %{
        decisions: [],
        retained_counts: %{open: 3, blocking: 1, awaiting: 3, awaiting_blocking: 1, health: %{status: :available}}
      })

    assert html =~ "3 units awaiting commands"
    refute html =~ "1 unit awaiting commands"
  end

  test "the unavailable-counts banner states only what is true on every route" do
    html =
      render_component(&Overview.decisions_banner/1, %{
        retained_counts: %{
          open: nil,
          blocking: nil,
          awaiting: nil,
          awaiting_blocking: nil,
          health: %{status: :unavailable}
        }
      })

    assert html =~ "Command counts unavailable"
    assert html =~ "cannot show how many units are awaiting commands"

    # This banner is on Analytics, Build Order and Stream Deck too, and none of
    # them has a priority overview to fall back to. A degraded surface that
    # names a wrong reason is worse than one that only says the number is gone.
    refute html =~ "priority overview"
  end

  test "surfaces DRAFT so a draft PR is never indistinguishable from a blocked one" do
    fleet = %{
      running: [
        fleet_row("AIUR-42", :active,
          title: "Drafting ticket",
          state: "human-review",
          review: :awaiting,
          ci: %{decision: :passed, pr_number: 77, head_sha: "head-77", draft?: true}
        )
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

    assert html =~ "PR #77"
    assert html =~ "DRAFT"
    assert html =~ "Review awaiting"

    ready_fleet = put_in(fleet, [:running, Access.at(0), :ci, :draft?], false)

    ready_html =
      render_component(&FleetTable.fleet_table/1, %{
        fleet: ready_fleet,
        decisions: [],
        now: ~U[2026-07-12 13:00:00Z]
      })

    refute ready_html =~ "DRAFT"
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
    html = render_component(&History.history/1, %{rows: [], provider_health: :degraded, time_zone: "Etc/UTC"})

    assert html =~ "Showing a partial Command history"
    refute html =~ "currently unavailable"
  end

  test "renders answered and dismissed Commands once as green history table rows" do
    answered = inbox_decision("dec-history-answered", decision_status: :decided, answer: action_answer(:operator))
    dismissed = inbox_decision("dec-history-dismissed", decision_status: :dismissed)

    html = render_history([answered, dismissed])

    assert html =~ ~s(<table id="command-history-table" class="history-table")
    assert html =~ ~s(data-severity="good")
    assert html =~ "Answered"
    assert html =~ "Closed without a recorded answer"
    refute html =~ ~s(class="decision-card)
  end

  test "renders expired Commands as non-actionable history with no decision to report" do
    expired = inbox_decision("dec-history-expired", decision_status: :expired)

    html = render_history([expired])

    assert html =~ "Expired"
    assert html =~ ~s(<td class="history-decision" data-sort-value="N/A">N/A</td>)
    assert html =~ ~s(data-severity="attn")
    refute html =~ ~s(class="decision-card)
  end

  test "quotes the answer the operator actually recorded in the Decision column" do
    custom =
      inbox_decision("dec-history-custom",
        decision_status: :decided,
        answer: action_answer(:operator, custom_response: "it is the executor's job to review", selected_option_id: nil)
      )

    chosen = inbox_decision("dec-history-option", decision_status: :decided, answer: action_answer(:operator))

    html = render_history([custom, chosen])

    assert html =~ ~s(<th scope="col" data-sort-key="decision">Decision</th>)
    refute html =~ "Outcome</th>"
    assert html =~ "“it is the executor&#39;s job to review”"
    assert html =~ "“Ship it”"
  end

  test "stacks each history result with its raised timestamp in one column" do
    answered = inbox_decision("dec-history-stacked", decision_status: :decided, answer: action_answer(:operator))

    document =
      [answered]
      |> render_history()
      |> Floki.parse_document!()

    timestamp = DateTime.to_iso8601(answered.created_at)

    assert Floki.find(document, ".history-table thead th") |> Enum.map(&Floki.text/1) == ["Command", "Decision", "Result"]
    assert [result_cell] = Floki.find(document, ".history-row > td.history-result-cell:has(.history-result):has(.history-when)")
    assert Floki.attribute(result_cell, "data-sort-value") == [timestamp]
    assert Floki.attribute(result_cell, ".history-when time", "datetime") == [timestamp]
    assert Floki.text(result_cell |> Floki.find(".history-when") |> List.first()) =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/
    assert render_history([answered], expanded_id: answered.decision_id) =~ ~s(<td colspan="3">)
  end

  test "quotes only what somebody actually said, never a status sentence or a blank answer" do
    deferred = inbox_decision("dec-quote-deferred", decision_status: :deferred)
    dismissed = inbox_decision("dec-quote-dismissed", decision_status: :dismissed)
    expired = inbox_decision("dec-quote-expired", decision_status: :expired)

    blank =
      inbox_decision("dec-quote-blank",
        decision_status: :decided,
        answer: action_answer(:operator, custom_response: "   ", selected_option_id: nil)
      )

    html = render_history([deferred, dismissed, expired, blank])

    # These are the component describing a lifecycle, not repeating an answer,
    # so none of them may wear quotation marks.
    assert html =~ ~s(<td class="history-decision" data-sort-value="Handed to the Executor">Handed to the Executor</td>)

    assert html =~
             ~s(<td class="history-decision" data-sort-value="Closed without a recorded answer">Closed without a recorded answer</td>)

    assert html =~ ~s(<td class="history-decision" data-sort-value="N/A">N/A</td>)
    assert html =~ ~s(<td class="history-decision" data-sort-value="">—</td>)
    refute html =~ "“”"
  end

  test "opens a history row as an accordion in place instead of a top-of-page panel" do
    answered =
      inbox_decision("dec-history-open",
        decision_status: :decided,
        answer: action_answer(:operator),
        context: %{short: "Reviewer capacity", long_markdown: "The queue is full."}
      )

    collapsed = render_history([answered])
    expanded = render_history([answered], expanded_id: "dec-history-open")

    # The whole row is the click target, and the control inside it is a real
    # button carrying aria-expanded — not a link that only a mouse can reach.
    assert collapsed =~ ~s(phx-click)
    assert collapsed =~ ~s(class="history-row-toggle" aria-expanded="false")
    refute collapsed =~ ">Open</a>"
    refute collapsed =~ "history-detail-row"

    assert expanded =~ ~s(aria-expanded="true")

    assert expanded =~
             ~s(<tr id="history-detail-history-dec-history-open" class="history-detail-row" data-sort-detail-for="history-dec-history-open">)

    assert expanded =~ "The queue is full."
    assert expanded =~ "Event timeline"
  end

  test "keeps deferred, expired and answered outcomes visually distinct in history" do
    rows = [
      inbox_decision("dec-answered", decision_status: :decided, answer: action_answer(:operator)),
      inbox_decision("dec-deferred", decision_status: :deferred),
      inbox_decision("dec-expired", decision_status: :expired)
    ]

    html = render_history(rows)

    assert html =~ "Deferred to Executor"
    assert html =~ "Handed to the Executor"
    assert html =~ "Expired"
    assert html =~ "Answered"
    assert html =~ ~s(data-severity="attention")
  end

  test "offers load more only while the store reports another page, and never guesses a total" do
    rows = Enum.map(1..10, &inbox_decision("dec-#{&1}", decision_status: :decided, answer: action_answer(:operator)))

    more = render_history(rows, has_more: true, total: 34)
    final = render_history(rows, has_more: false, total: nil)

    assert more =~ ~s(phx-click="load-more-history")
    assert more =~ "10 of 34"
    refute final =~ ~s(phx-click="load-more-history")
    assert final =~ "10 loaded"
  end

  test "Commands inbox exposes only the four primary filters with canonical retained counts" do
    html =
      render_inbox(
        [inbox_decision("dec-overview-only")],
        :all,
        %{total: 701, open: 503, awaiting: 503, blocking: 401, awaiting_blocking: 401}
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

  test "renders a writable canonical answer form without a confirmation footer" do
    decision = action_decision(reversibility: :irreversible, kind: "destructive_op")

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ ~s(name="answer[choice]")
    refute html =~ "Persisted before dispatch"
    refute html =~ "Durable command"
    refute html =~ "Answer this Command"
    refute html =~ "Rationale"
    refute html =~ "I understand this Command is irreversible or destructive."
    refute html =~ "Choose an option"
    assert html =~ ">Decision</button>"
  end

  test "renders recommended card-face choices with Decision and Defer-to-Executor actions" do
    decision = action_decision([])

    html =
      render_component(&DecisionAction.decision_action/1, %{
        decision: decision,
        state: %{},
        writable: true,
        compact: true
      })

    assert html =~ ~s(class="decision-action compact")
    assert html =~ ~s(value="option:ship")
    assert html =~ ~s(checked)
    assert html =~ "Recommended"
    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ ~s(phx-click="defer-decision")
    assert html =~ "Defer to Executor"
    assert html =~ ">Decision</button>"
  end

  test "free-form attention offers a dismiss alongside the response form" do
    decision = action_decision(options: [], recommendation: nil)

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-click="dismiss-decision")
    refute html =~ ">Acknowledge</button>"
    assert html =~ ~s(phx-submit="answer-decision")
  end

  test "optioned command offers a dismiss alongside the choice list" do
    decision = action_decision([])

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-click="dismiss-decision")
    refute html =~ ">Acknowledge</button>"
  end

  test "blocking legacy attention offers an operator dismiss X" do
    decision = action_decision(blocking: true, legacy_attention: %{slug: "scope-question", topic: "ticket.1.attention"})

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-click="dismiss-decision")
    assert html =~ ~s(aria-label="Dismiss blocker")
    assert html =~ ">×</button>"
  end

  test "any open command offers a dismiss control" do
    # The store still refuses an agent-filed blocking Command with no legacy
    # attention, but the UI offers the control so the operator can attempt it;
    # the store answers with the honest refusal.
    decision = action_decision(blocking: true, legacy_attention: nil)

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-click="dismiss-decision")
  end

  test "command footer renders defer, dismiss and submit for an open command" do
    blocking =
      action_decision(blocking: true, legacy_attention: %{slug: "scope-question", topic: "ticket.1.attention"})

    free_form = action_decision(options: [], recommendation: nil)

    for decision <- [blocking, free_form] do
      html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

      buttons = html |> Floki.parse_document!() |> Floki.find(".decision-action-buttons button")
      assert length(buttons) == 3
    end
  end

  test "dismissed historic card offers a change choice answer without another dismiss" do
    decision = action_decision(decision_status: :dismissed)

    html =
      render_component(&DecisionAction.decision_action/1, %{
        decision: decision,
        state: %{},
        writable: true,
        compact: true
      })

    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ "Change choice"
    refute html =~ ~s(phx-click="defer-decision")
  end

  test "deferred card stays answerable with a distinct Executor badge" do
    decision =
      action_decision(decision_status: :deferred)
      |> Map.merge(%{
        created_at: ~U[2026-07-30 12:00:00Z],
        ticket: %{identifier: "1380", title: "Deferred decision", url: nil},
        context: %{short: nil, long_markdown: nil},
        question: "Which release train should ship?",
        urgency: :normal,
        source: %{agent_id: nil},
        blocking: false,
        artifacts: [],
        revision_sequence: 0,
        superseded?: false,
        provenance: nil
      })

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true, compact: true})

    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ "Change choice"
    assert html =~ ~s(phx-click="defer-decision")
    assert html =~ "Notify Executor again"

    card_html =
      render_component(&DecisionCard.decision_card/1, %{
        decision: decision,
        writable: true,
        now: ~U[2026-07-30 12:00:00Z]
      })

    assert card_html =~ "Deferred to Executor"
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
    assert writable =~ "Delivery failed"
    assert writable =~ ~s(phx-click="retry-decision")
    assert writable =~ "Target agent unavailable"
    refute readonly =~ ~s(phx-click="retry-decision")
    refute readonly =~ ~s(phx-submit="answer-decision")
  end

  test "labels executor answers distinctly while retaining supervisor answer labels" do
    operator = inbox_decision("dec-operator-answer", decision_status: :decided, answer: action_answer(:operator))
    executor = inbox_decision("dec-executor-answer", decision_status: :decided, answer: action_answer(:executor))
    supervisor = inbox_decision("dec-supervisor-answer", decision_status: :decided, answer: action_answer(:supervisor))

    operator_card =
      render_component(&DecisionCard.decision_card/1, %{
        decision: operator,
        writable: false,
        now: ~U[2026-07-12 13:00:00Z]
      })

    executor_card =
      render_component(&DecisionCard.decision_card/1, %{
        decision: executor,
        writable: false,
        now: ~U[2026-07-12 13:00:00Z]
      })

    supervisor_card =
      render_component(&DecisionCard.decision_card/1, %{
        decision: supervisor,
        writable: false,
        now: ~U[2026-07-12 13:00:00Z]
      })

    operator_history = render_history([operator])
    executor_history = render_history([executor])
    supervisor_history = render_history([supervisor])

    executor_latency =
      render_component(&DecisionLatency.decision_latency/1, %{
        latency: %{status: :available, snapshot: %{actor: "executor"}}
      })

    assert operator_card =~ "Operator answer"
    refute operator_card =~ "Executor answer"
    refute operator_card =~ "Supervisor answer"
    assert executor_card =~ "Executor answer"
    refute executor_card =~ "Operator answer"
    refute executor_card =~ "Supervisor answer"
    assert supervisor_card =~ "Supervisor answer"
    refute supervisor_card =~ "Operator answer"
    refute supervisor_card =~ "Executor answer"
    assert operator_history =~ "Operator answer"
    assert executor_history =~ "Executor answer"
    assert supervisor_history =~ "Supervisor answer"
    assert executor_latency =~ "Executor"
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

    assert missing =~ "No latency recorded for this Command yet."
    refute missing =~ "provider is unavailable"
    assert unavailable =~ "Command latency is unavailable right now."
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
    assert writable =~ "Revise Command"
    assert writable =~ "Revising sets new direction — it does not undo what already happened."
    assert writable =~ "Executor follow-up required"
    assert writable =~ ~s(phx-submit="revise-decision")
    assert writable =~ ~s(phx-submit="handle-revision-follow-up")
    assert readonly =~ "Original answer · preserved"
    assert readonly =~ "Executor follow-up required"
    refute readonly =~ ~s(phx-submit="revise-decision")
    refute readonly =~ ~s(phx-submit="handle-revision-follow-up")
  end

  test "moves answered and dismissed Commands out of the inbox into history" do
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
      inbox_decision("dec-dismissed",
        decision_status: :dismissed,
        delivery_status: :not_dispatched,
        lifecycle: :resolved
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

    assert all =~ "Question dec-open"
    refute all =~ "Question dec-undelivered"
    refute all =~ "Question dec-supervisor"
    refute all =~ "Question dec-resolved"
    refute all =~ "Question dec-dismissed"
    refute all =~ "Question dec-superseded"
    assert resolved =~ "Resolved Commands are shown in Command history below."
    refute resolved =~ ~s(class="decision-card)
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

    assert html =~ ">Codex</span>"
    assert html =~ ">resolved-model</span>"
    assert html =~ "0% confidence"
    assert html =~ "Selected · Second option"
    assert html =~ "First option"
    assert html =~ "Second option"
    refute html =~ "Hidden third option"
  end

  test "Command detail prioritizes context and events over diagnostic metadata" do
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

    assert html =~ "Context"
    assert html =~ "Event timeline"
    refute html =~ "Command metadata"
    refute html =~ "Command latency"
    refute html =~ "Runtime provenance"
    refute html =~ "Links &amp; artifacts"
  end

  test "an unfetched Build Order renders one copyable provider-failure state and no graph regions" do
    html =
      render_selected(%{
        unresolved_model(:provider_unavailable)
        | diagnostics: [Diagnostic.new(:provider_unavailable)]
      })

    {:ok, document} = Floki.parse_document(html)

    assert [_card] = Floki.find(document, ".bo-state-card")
    assert html =~ "Could not read the plan"
    assert html =~ ~s(phx-hook="CopyToClipboard")
    assert html =~ "Investigate why Build Order #1567&#39;s plan could not be read."
    assert html =~ "`provider_unavailable`"
    assert html =~ "graph counts are unresolved"

    # Unknown stays unknown, but the page-level failure suppresses the metric
    # strip instead of repeating that fact in five cells and three panels.
    refute html =~ "Build Order graph summary"
    refute html =~ "Unresolved"
    refute html =~ "Plan distribution"
    refute html =~ "Analytics unavailable"
    refute html =~ "Usage and cost unavailable"
    refute html =~ "GitHub planning data is unavailable"
  end

  test "a fetched malformed Build Order renders one structural-failure state with its observed count" do
    html =
      render_selected(%{
        unresolved_model(:structurally_invalid)
        | summary: resolved_summary(),
          diagnostics: [Diagnostic.new(:invalid_root)]
      })

    {:ok, document} = Floki.parse_document(html)

    assert [_card] = Floki.find(document, ".bo-state-card")
    assert html =~ "The plan is unreadable"
    assert html =~ "Investigate why Build Order #1567&#39;s plan is unreadable."
    assert html =~ "`invalid_root`"
    assert html =~ "`members: 0`"
    refute html =~ "Build Order graph summary"
    refute html =~ "Unresolved"
    refute html =~ "Plan distribution"
    refute html =~ ">Analytics<"
    refute html =~ "Usage and cost"
    refute html =~ "Root data is unavailable"
  end

  # A malformed graph carries no structural diagnostic when the root summary
  # itself is the defect, so the verdict is the only honest code left.
  test "a malformed Build Order with no structural diagnostic falls back to the structural verdict" do
    html = render_selected(%{unresolved_model(:structurally_invalid) | summary: resolved_summary()})

    assert html =~ "The plan is unreadable"
    assert html =~ "`structurally_invalid`"
  end

  # `SelectedRoot.availability/2` lets a producer fail closed on a structural
  # defect by marking provider health failed, and says that marking "must not be
  # read as an outage". Sourcing the reported fault from health told the operator
  # a graph was malformed *because of* `rate_limited` and sent the debug prompt
  # after an outage that was not the reason for anything.
  test "a malformed Build Order never reports its provider health failure as the structural fault" do
    html =
      render_selected(%{
        unresolved_model(:structurally_invalid)
        | summary: resolved_summary(),
          planning_health: %ProviderHealth{generation: 9, state: :unavailable, failure: :rate_limited},
          diagnostics: [Diagnostic.new(:duplicate_identity)]
      })

    {:ok, document} = Floki.parse_document(html)

    assert [card] = Floki.find(document, ".bo-state-card")
    card_text = Floki.text(card)

    assert html =~ "The plan is unreadable"
    # The code shown is the observed structural defect, not the fetch fault.
    assert card_text =~ "Reported fault: duplicate_identity"
    assert html =~ "The selected-root provider reports `duplicate_identity`"
    refute card_text =~ "rate_limited"
  end

  # Collapsing restatements of one fault is the ask; a graph that is malformed
  # *and* genuinely unreachable has two faults, and the outage must survive.
  test "a malformed Build Order still reports a concurrent provider outage" do
    html =
      render_selected(%{
        unresolved_model(:structurally_invalid)
        | summary: resolved_summary(),
          diagnostics: [Diagnostic.new(:duplicate_identity), Diagnostic.new(:provider_unavailable)]
      })

    assert html =~ "The selected-root provider reports `duplicate_identity`"
    assert html =~ "also reported: `provider_unavailable`"
  end

  # The fallback used to restate the card's own message word for word, which is
  # the restatement pattern this state exists to remove.
  test "a malformed Build Order with unresolved counts adds no restated observation" do
    html = render_selected(%{unresolved_model(:structurally_invalid) | diagnostics: [Diagnostic.new(:invalid_root)]})

    assert html =~ "The selected-root provider reports `invalid_root`."
    refute html =~ "the fetched response failed structural validation"
  end

  # #1808 stopped `failure_class/1` laundering every read fault into
  # `provider_unavailable`. The one error card must report the code the provider
  # actually gave, or the debug prompt sends an agent after the wrong problem.
  test "the single failure state names the specific reported fault, not a generic outage" do
    html =
      render_selected(%{
        unresolved_model(:provider_unavailable)
        | planning_health: %ProviderHealth{generation: 9, state: :unavailable, failure: :rate_limited}
      })

    {:ok, document} = Floki.parse_document(html)

    assert [_card] = Floki.find(document, ".bo-state-card")
    assert html =~ "Reported fault:"
    assert html =~ "`rate_limited`"
    refute html =~ "provider_unavailable"
  end

  # Collapsing restatements of one fault is the point; hiding a second, genuinely
  # different fault would trade a wall of text for a confident wrong reason.
  test "the single failure state still reports genuinely distinct faults" do
    html =
      render_selected(%{
        unresolved_model(:provider_unavailable)
        | planning_health: %ProviderHealth{generation: 9, state: :unavailable, failure: :rate_limited},
          diagnostics: [Diagnostic.new(:provider_unavailable), Diagnostic.new(:pagination_mismatch)]
      })

    {:ok, document} = Floki.parse_document(html)

    assert [_card] = Floki.find(document, ".bo-state-card")
    assert html =~ "also reported: `pagination_mismatch`"
    # `provider_unavailable` here restates the reported fault rather than adding one.
    refute html =~ "provider_unavailable"
  end

  defp render_selected(model) do
    {route_state, _effects} = RouteState.new("mount-1") |> RouteState.navigate("1567")

    render_component(&BuildOrderSelected.build_order_selected/1, %{
      route_state: route_state,
      model: model,
      now: ~U[2026-08-10 12:00:00Z],
      analytics_scope: %{state: :none},
      usage_scope: %{state: :none}
    })
  end

  defp unresolved_model(status) do
    %BuildOrderViewModel{status: status, summary: unresolved_summary()}
  end

  defp unresolved_summary, do: %{resolved_summary() | resolved?: false}

  defp resolved_summary do
    %{resolved?: true, members: 0, edges: 0, external_edges: 0, lanes: %{}, phases: %{}}
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

  defp action_answer(kind, attrs \\ []) do
    defaults = %{
      action_id: "act-#{kind}",
      decision_version: 1,
      selected_option_id: "ship",
      custom_response: nil,
      rationale: nil,
      actor: %{kind: kind, id: Atom.to_string(kind)},
      accepted_at: ~U[2026-07-12 13:00:00Z]
    }

    Map.merge(defaults, Map.new(attrs))
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

  defp render_history(decisions, opts \\ []) do
    render_component(&History.history/1, %{
      rows: decisions,
      loaded: length(decisions),
      total: Keyword.get(opts, :total),
      has_more: Keyword.get(opts, :has_more, false),
      provider_health: :ok,
      expanded_id: Keyword.get(opts, :expanded_id),
      writable: Keyword.get(opts, :writable, false),
      time_zone: Keyword.get(opts, :time_zone, "Etc/UTC")
    })
  end

  defp render_inbox(decisions, filter, retained_counts \\ nil) do
    awaiting = Enum.count(decisions, &(&1.decision_status == :open))

    retained_counts =
      retained_counts ||
        %{
          total: length(decisions),
          open: awaiting,
          awaiting: awaiting,
          blocking: Enum.count(decisions, &(&1.blocking and &1.decision_status == :open)),
          awaiting_blocking: Enum.count(decisions, &(&1.blocking and &1.decision_status == :open))
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

  # --- Build Order grid fixtures ---------------------------------------------

  defp sample_view_model do
    nodes = [
      node(:bo010, "BO-010", "plan-graph", 3,
        complexity: 3,
        status_icon: %Icon{key: :status_completed, text: "Completed"},
        progress: :unknown
      ),
      node(:bo012, "BO-012", "plan-graph", 4,
        complexity: 4,
        status_icon: %Icon{key: :status_working, text: "Agent working"},
        progress: 40
      ),
      node(:dash1, "DASH-001", "dashboard-ui", 3,
        complexity: 3,
        status_icon: %Icon{key: :status_ready, text: "Ready"}
      ),
      node(:dash2, "DASH-002", "dashboard-ui", 4,
        complexity: 2,
        status_icon: %Icon{key: :status_blocking, text: "Blocked by an open dependency"}
      )
    ]

    edges = [
      edge("e-cleared", :bo010, :bo012, :cleared),
      edge("e-blocking", :dash2, :bo010, :blocking)
    ]

    %AiurWeb.BuildOrderViewModel{status: :ready, nodes: nodes, edges: edges}
  end

  defp node(key, identifier, lane, phase, opts) do
    %Node{
      key: key,
      identity: nil,
      title: Keyword.get(opts, :title, "Node #{identifier}"),
      plan: %{complexity: Keyword.get(opts, :complexity, :unknown)},
      execution: %{},
      activity: %{},
      readiness: :ready,
      lane_icon: nil,
      status_icon: Keyword.get(opts, :status_icon),
      health: %{},
      observed_at: %{},
      provenance: %{},
      diagnostics: [],
      card: %{
        identifier: identifier,
        lane: lane,
        phase: phase,
        status_text: Keyword.get(opts, :status_text),
        lifecycle: %{state: :open, state_reason: :none},
        execution_state: :idle,
        agent_stage: nil,
        progress: Keyword.get(opts, :progress, :unknown)
      }
    }
  end

  defp edge(id, source_key, target_key, state) do
    %Edge{
      id: id,
      source: nil,
      target: nil,
      source_key: source_key,
      target_key: target_key,
      kind: :native,
      state: state,
      source_connection: nil,
      text: nil,
      diagnostics: []
    }
  end
end
