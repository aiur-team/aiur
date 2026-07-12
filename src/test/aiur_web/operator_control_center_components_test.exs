defmodule AiurWeb.OperatorControlCenterComponentsTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{DecisionDetail, FleetTable, History, LifecycleComponents, Overview}

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
      actor: %{type: :human_operator, id: "operator", label: "Human operator"},
      choice: nil,
      rationale: "The revision could not be dispatched.",
      dispatch_result: :failed,
      acknowledgement_result: :pending,
      revised?: true,
      follow_up_required: true,
      follow_up_handled: false
    }

    html = render_component(&History.history/1, %{entries: [entry], provider_health: :ok})

    assert html =~ "Human operator"
    assert html =~ "Follow-up required"
    assert html =~ "dispatch: Failed"
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
    html = render_component(&FleetTable.fleet_table/1, %{fleet: fleet, decisions: decisions, now: ~U[2026-07-12 13:00:00Z]})

    assert html =~ ~s(aria-label="Open pending decision")
    assert html =~ ~s(aria-label="Read agent conversation")
    assert html =~ ~s(aria-label="Open tracker ticket")
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

  test "distinguishes degraded decision history from an unavailable provider" do
    html = render_component(&History.history/1, %{entries: [], provider_health: :degraded})

    assert html =~ "Decision history is degraded"
    refute html =~ "currently unavailable"
  end
end
