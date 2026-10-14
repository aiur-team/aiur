defmodule AiurWeb.OperatorControlCenterComponentsAnalyticsCardsTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.BuildOrder.Diagnostic

  alias AiurWeb.OperatorControlCenter.{DecisionDetail, DecisionLatency, DecisionRevisionAction}

  import AiurWeb.OperatorControlCenterComponentsFixtures

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
end
