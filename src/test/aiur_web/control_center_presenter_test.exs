defmodule AiurWeb.ControlCenterPresenterTest do
  use Aiur.TestSupport

  alias Aiur.Decision
  alias AiurWeb.ControlCenterPresenter

  test "composes real decision and fleet projections without inventing lifecycle data" do
    decisions = [decision("dec-normal", blocking: false, urgency: :normal), decision("dec-blocking", blocking: true, urgency: :critical)]

    payload =
      ControlCenterPresenter.compose(
        fleet_payload(),
        decisions,
        [],
        %{merges: [], health: :ready, reconciliation: %{status: :complete, partial?: false}}
      )

    assert payload.overview == %{
             blocking_decisions: 1,
             running: 1,
             queued_or_retrying: 1,
             recent_repository_merges: 0
           }

    assert [blocking, normal] = payload.decisions
    assert blocking.decision_id == "dec-blocking"
    assert blocking.lifecycle == :recorded
    assert blocking.context.long_markdown == "**Context stays text until the component escapes it.**"
    assert blocking.recommendation == %{option_id: "ship", reason: "Smallest safe change"}

    assert blocking.options == [
             %{
               id: "ship",
               label: "Ship it",
               description: "Proceed with the bounded change",
               benefits: "Keeps the agent moving",
               drawbacks: "Needs review",
               risk: "low"
             }
           ]

    assert normal.decision_id == "dec-normal"
    assert {:ok, ^blocking} = ControlCenterPresenter.find_decision(payload, "dec-blocking")
    assert :error = ControlCenterPresenter.find_decision(payload, "missing")
  end

  test "degrades each unavailable domain provider independently" do
    payload =
      ControlCenterPresenter.state_payload(:unused, 10,
        fleet_fun: fn -> fleet_payload() end,
        decisions_fun: fn -> exit(:decision_store_down) end,
        history_fun: fn -> raise "history unavailable" end,
        recent_merges_fun: fn -> %{merges: [], health: :ready, reconciliation: %{status: :complete, partial?: false}} end
      )

    assert payload.decisions == []
    assert payload.history == []
    assert payload.recent_outcomes == []
    assert payload.provider_health.decisions == :unavailable
    assert payload.provider_health.history == :unavailable
    assert payload.provider_health.recent_outcomes == :ok
    assert payload.fleet.running != []
  end

  test "normalizes the stable OCC-6 history and recent-outcomes contracts without inferring causality" do
    history = [
      %{
        decision_id: "dec-history",
        ticket: %{identifier: "AIUR-983"},
        question: "Which provider should the dashboard use?",
        source_version: 2,
        changed_at: ~U[2026-07-12 13:00:00Z],
        change: :revision_no_longer_applicable,
        actor: %{type: :human_operator, id: "operator", label: "Human operator"},
        choice: "Option B",
        rationale: "The target is terminal.",
        dispatch_result: :failed,
        acknowledgement_result: :pending,
        revision_of: "action-1",
        superseded_by: nil,
        revised?: true,
        follow_up: %{required?: true, handled?: false, slug: "decision-revision-follow-up"}
      }
    ]

    recent_merges = %{
      merges: [
        %{
          repository: "its-everdred/aiur",
          number: 971,
          title: "Operator Control Center PRD",
          summary: "Defines the OCC surfaces.",
          url: "https://example.test/pulls/971",
          head_ref: "occ-prd",
          head_sha: "abc123",
          ticket_id: "971",
          merged_by: "operator",
          merged_at: ~U[2026-07-12 13:30:00Z],
          backfilled?: false,
          live_observed?: true,
          observed_run_id: "run-1"
        }
      ],
      health: :ready,
      reconciliation: %{status: :complete, partial?: false}
    }

    payload = ControlCenterPresenter.compose(fleet_payload(), [], history, recent_merges)

    assert [entry] = payload.history
    assert entry.follow_up_required
    refute entry.follow_up_handled
    assert entry.dispatch_result == :failed

    assert [outcome] = payload.recent_outcomes
    assert outcome.merged_by == "operator"
    assert outcome.live_observed?
    refute Map.has_key?(outcome, :agent)
    assert payload.overview.recent_repository_merges == 1
    assert payload.recent_outcomes_reconciliation == %{status: :complete, partial?: false}
  end

  defp fleet_payload do
    %{
      generated_at: "2026-07-12T12:00:00Z",
      counts: %{running: 1, retrying: 1, idle: 0},
      running: [%{issue_identifier: "AIUR-987", waiting_reason: :active}],
      retrying: [%{issue_identifier: "AIUR-988", waiting_reason: :backing_off}],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

  defp decision(decision_id, attrs) do
    now = ~U[2026-07-12 12:00:00Z]

    defaults = %{
      decision_id: decision_id,
      source_id: decision_id,
      version: 1,
      ticket: %{identifier: "AIUR-987", title: "Operator Control Center", url: "https://example.test/issues/987"},
      source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-987"},
      kind: "architecture",
      authority: :human_required,
      urgency: :high,
      blocking: true,
      reversibility: :reversible,
      question: "Should the bounded change ship?",
      context: %{short_summary: "A real projected decision", long_context_markdown: "**Context stays text until the component escapes it.**"},
      options: [
        %{
          id: "ship",
          label: "Ship it",
          description: "Proceed with the bounded change",
          benefits: "Keeps the agent moving",
          drawbacks: "Needs review",
          risk: "low"
        }
      ],
      recommendation: %{option_id: "ship", reason: "Smallest safe change"},
      consequence_of_delay: "The agent remains paused.",
      artifacts: [%{kind: :path, value: "src/lib/aiur_web/live/dashboard_live.ex"}],
      created_at: now,
      source_created_at: now,
      content_hash: "hash-#{decision_id}"
    }

    struct!(Decision, Map.merge(defaults, Map.new(attrs)))
  end
end
