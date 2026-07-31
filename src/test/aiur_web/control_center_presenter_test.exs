defmodule AiurWeb.ControlCenterPresenterTest do
  use Aiur.TestSupport

  alias Aiur.{Decision, DecisionAnswer, DecisionHistory}
  alias AiurWeb.ControlCenterPresenter

  test "composes real decision and fleet projections without inventing lifecycle data" do
    decisions = [
      decision("dec-normal", blocking: false, urgency: :normal),
      decision("dec-blocking", blocking: true, urgency: :critical)
    ]

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
        recent_merges_fun: fn ->
          %{merges: [], health: :ready, reconciliation: %{status: :complete, partial?: false}}
        end,
        decision_metrics_fun: fn -> exit(:decision_metrics_down) end
      )

    assert payload.decisions == []
    assert payload.history == []
    assert payload.recent_outcomes == []
    assert payload.provider_health.decisions == :unavailable
    assert payload.provider_health.history == :unavailable
    assert payload.provider_health.recent_outcomes == :ok
    assert payload.provider_health.decision_latency == :unavailable
    assert payload.fleet.running != []
  end

  test "the unavailable fleet contract contains no synthetic financial facts" do
    payload =
      ControlCenterPresenter.state_payload(:unused, 10,
        fleet_fun: fn -> exit(:fleet_down) end,
        decisions_fun: fn -> [] end,
        history_fun: fn -> [] end,
        recent_merges_fun: fn ->
          %{merges: [], health: :ready, reconciliation: %{status: :complete, partial?: false}}
        end,
        decision_metrics_fun: fn -> %{} end
      )

    assert payload.fleet.agent_totals == %{seconds_running: 0}
    refute Map.has_key?(payload.fleet, :rate_limits)
  end

  test "associates canonical latency by exact decision id and distinguishes missing samples" do
    decisions = [
      decision("dec-with-latency", blocking: true, urgency: :critical),
      decision("dec-without-latency", blocking: false, urgency: :normal)
    ]

    latency = %{
      "dec-with-latency" => %{
        decision_id: "dec-with-latency",
        request_to_decision_ms: 1_000,
        decision_to_dispatch_ms: 250,
        dispatch_to_delivery_ms: 500,
        delivery_to_ack_ms: 125,
        blocked_time_ms: 1_875,
        reminder_count: 1,
        attention_count: 2,
        actor: "human",
        revised: false
      },
      "dec-unrelated" => %{decision_id: "dec-unrelated", blocked_time_ms: 9_999}
    }

    payload =
      ControlCenterPresenter.state_payload(:unused, 10,
        fleet_fun: fn -> fleet_payload() end,
        decisions_fun: fn -> decisions end,
        history_fun: fn -> [] end,
        recent_merges_fun: fn ->
          %{merges: [], health: :ready, reconciliation: %{status: :complete, partial?: false}}
        end,
        decision_metrics_fun: fn -> latency end
      )

    assert [with_latency, without_latency] = payload.decisions
    assert with_latency.decision_id == "dec-with-latency"
    assert with_latency.latency == %{status: :available, snapshot: latency["dec-with-latency"]}
    assert without_latency.decision_id == "dec-without-latency"
    assert without_latency.latency == %{status: :missing, snapshot: nil}
    assert payload.provider_health.decision_latency == :ok
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
        actor: %{type: :human_operator, id: "operator", label: "Executor"},
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
          repository: "aiur-team/aiur",
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

  test "preserves trusted canonical history provenance, confidence, and supersession" do
    supervisor_basis = %{
      confidence: 0,
      alternatives_considered: ["Wait"],
      reversibility_belief: :reversible,
      policy_basis: %{
        authority: :supervisor_allowed,
        kind: "architecture",
        reversibility: :reversible,
        checks: %{authority_delegable: true, kind_allowed: true, reversibility_allowed: true},
        allow_non_reversible: false
      }
    }

    history = [
      DecisionHistory.project_record(%{
        decision_id: "dec-canonical-history",
        ticket: %{identifier: "AIUR-1113", title: "Commands", url: nil},
        question: "Use the canonical history projection?",
        change_kind: :superseded,
        created_at: ~U[2026-07-15 12:00:00Z],
        superseded_by: "action-replacement",
        provenance: %{
          schema_version: 1,
          source: "agent_runner",
          captured_at: "2026-07-15T11:59:00Z",
          agent_family: "codex",
          backend: "codex-app-server",
          requested_model: "gpt-requested",
          resolved_model: "gpt-resolved"
        },
        answer: %{
          action_id: "action-original",
          actor: %{kind: :supervisor, id: "supervising-agent"},
          supervisor_basis: supervisor_basis,
          accepted_at: ~U[2026-07-15 12:00:00Z]
        }
      })
    ]

    payload =
      ControlCenterPresenter.compose(
        fleet_payload(),
        [],
        history,
        %{merges: [], health: :ready, reconciliation: %{status: :complete, partial?: false}}
      )

    assert [entry] = payload.history
    assert entry.provenance["backend"] == "codex-app-server"
    assert entry.provenance["resolved_model"] == "gpt-resolved"
    assert entry.supervisor_basis["confidence"] == 0
    assert entry.superseded_by == "action-replacement"
    assert entry.change == :superseded
  end

  test "maps OCC-3 semantic and delivery axes into an honest display lifecycle" do
    decision = decision("dec-delivery", blocking: true, urgency: :critical)

    assert {:ok, answer} =
             DecisionAnswer.normalize(
               %{
                 "idempotency_key" => "dashboard-submit",
                 "expected_version" => 1,
                 "option_id" => "ship",
                 "rationale" => "Checks are green"
               },
               decision_id: decision.decision_id,
               decision_version: decision.version,
               options: decision.options,
               actor: %{kind: :operator, id: "dashboard"},
               now: ~U[2026-07-12 12:05:00Z]
             )

    failed = %{
      decision
      | answer: answer,
        active_action_id: answer.action_id,
        decision_status: :decided,
        delivery_status: :failed,
        dispatch_attempts: [
          %{
            action_id: answer.action_id,
            attempt_id: "attempt-1",
            queue_item_id: nil,
            run_id: "run-1",
            status: :failed,
            attempted_at: ~U[2026-07-12 12:05:00Z],
            queued_at: nil,
            delivered_at: nil,
            restored_at: nil,
            consumed_at: nil,
            failed_at: ~U[2026-07-12 12:05:01Z],
            failure_reason_class: "target_agent_unavailable"
          }
        ]
    }

    payload =
      ControlCenterPresenter.compose(
        fleet_payload(),
        [failed],
        [],
        %{merges: [], health: :ready, reconciliation: %{status: :complete, partial?: false}}
      )

    assert [row] = payload.decisions
    assert row.lifecycle == :delivery_failed
    assert row.decision_status == :decided
    assert row.delivery_status == :failed
    assert row.answer.action_id == answer.action_id
    assert row.answer.selected_option_id == "ship"
    assert row.retryable
    assert row.failure_reason == "target_agent_unavailable"
    assert payload.overview.blocking_decisions == 0

    assert :delivered == display_lifecycle(%{failed | delivery_status: :consumed})
    assert :acknowledged == display_lifecycle(%{failed | delivery_status: :delivered, decision_status: :acknowledged})
    assert :resolved == display_lifecycle(%{failed | delivery_status: :delivered, decision_status: :resolved})
  end

  test "isolates malformed provider elements without blacking out healthy panels" do
    valid_decision = decision("dec-valid", blocking: false, urgency: :normal)
    history = [nil, %{decision_id: "dec-valid", question: "Healthy history"}]
    merges = %{merges: [nil, %{repository: "aiur-team/aiur", number: 987}], health: :ready}

    payload = ControlCenterPresenter.compose(fleet_payload(), [nil, valid_decision], history, merges)

    assert Enum.map(payload.decisions, & &1.decision_id) == ["dec-valid"]
    assert Enum.map(payload.history, & &1.decision_id) == ["dec-valid"]
    assert Enum.map(payload.recent_outcomes, & &1.number) == [987]
    assert payload.fleet.running != []
  end

  test "keeps blocking-first ordering when a non-blocking delivery has failed" do
    blocking = decision("dec-blocking-low", blocking: true, urgency: :low)

    failed = %{
      decision("dec-failed-critical", blocking: false, urgency: :critical)
      | decision_status: :decided,
        delivery_status: :failed
    }

    payload =
      ControlCenterPresenter.compose(
        fleet_payload(),
        [failed, blocking],
        [],
        %{merges: [], health: :ready, reconciliation: %{status: :complete, partial?: false}}
      )

    assert Enum.map(payload.decisions, & &1.decision_id) == ["dec-blocking-low", "dec-failed-critical"]
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
      context: %{
        short_summary: "A real projected decision",
        long_context_markdown: "**Context stays text until the component escapes it.**"
      },
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

  defp display_lifecycle(decision) do
    decision
    |> then(fn current ->
      ControlCenterPresenter.compose(
        fleet_payload(),
        [current],
        [],
        %{merges: [], health: :ready, reconciliation: %{}}
      )
    end)
    |> Map.fetch!(:decisions)
    |> hd()
    |> Map.fetch!(:lifecycle)
  end
end
