defmodule AiurWeb.OperatorControlCenterComponentsTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{
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

  test "renders delivery failure and supersession as explicit lifecycle overrides" do
    failed = render_component(&LifecycleComponents.lifecycle_stepper/1, %{lifecycle: :delivery_failed})
    superseded = render_component(&LifecycleComponents.lifecycle_stepper/1, %{lifecycle: :superseded})

    assert failed =~ "Recorded"
    assert failed =~ "Dispatch pending"
    assert failed =~ "Delivery failed"
    assert failed =~ "Acknowledged"
    assert failed =~ "Resolved"
    refute failed =~ "rolled back"

    assert superseded =~ "Superseded — replaced by a newer decision"
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

    assert html =~ ~s(aria-label="Open pending decision")
    assert html =~ ~s(aria-label="Read agent conversation")
    assert html =~ ~s(aria-label="Open tracker ticket")
    assert html =~ ~s(data-label="Ticket")
    assert html =~ ~s(data-label="Latest")
    assert html =~ ~s(data-label="Elapsed")
    assert html =~ ~s(data-label="Decisions")
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

  test "decision banner targets an open decision and hides when none await input" do
    answered = %{decision_id: "dec-answered", blocking: true, lifecycle: :resolved}
    open = %{decision_id: "dec-open", blocking: false, lifecycle: :recorded}

    html = render_component(&Overview.decisions_banner/1, %{decisions: [answered, open]})
    empty_html = render_component(&Overview.decisions_banner/1, %{decisions: [answered]})

    assert html =~ ~s(href="/decisions/dec-open")
    refute html =~ ~s(href="/decisions/dec-answered")
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

    assert html =~ "Decision history is degraded"
    refute html =~ "currently unavailable"
  end

  test "renders a writable canonical answer form with destructive confirmation" do
    decision = action_decision(reversibility: :irreversible, kind: "destructive_op")

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ ~s(name="answer[choice]")
    assert html =~ "Persisted before dispatch"
    assert html =~ "I understand this decision is irreversible or destructive."
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
    assert html =~ "Request to decision"
    assert html =~ "250 ms"
    assert html =~ "Decision to dispatch"
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

    assert missing =~ "No latency sample has been retained for this decision yet."
    refute missing =~ "provider is unavailable"
    assert unavailable =~ "Decision latency provider is unavailable."
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

  test "filters canonical undelivered, supervisor, resolved, and superseded states" do
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

    undelivered = render_inbox(decisions, :undelivered)
    supervisor = render_inbox(decisions, :supervisor)
    resolved = render_inbox(decisions, :resolved)
    superseded = render_inbox(decisions, :superseded)

    assert undelivered =~ "Question dec-undelivered"
    refute undelivered =~ "Question dec-supervisor"
    assert supervisor =~ "Question dec-supervisor"
    refute supervisor =~ "Question dec-undelivered"
    assert resolved =~ "Question dec-resolved"
    refute resolved =~ "Question dec-superseded"
    assert superseded =~ "Question dec-superseded"
    assert superseded =~ "Undelivered"
    assert superseded =~ "Supervisor"
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

  defp render_inbox(decisions, filter) do
    render_component(&DecisionInbox.decision_inbox/1, %{
      decisions: decisions,
      selected_decision_id: nil,
      filter: filter,
      now: ~U[2026-07-12 13:00:00Z],
      history: [],
      action_states: %{},
      writable: false,
      provider_health: :ok
    })
  end
end
