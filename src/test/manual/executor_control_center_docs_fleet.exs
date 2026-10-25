defmodule Aiur.Docs.ControlCenterFixture.Fleet do
  import Aiur.Docs.ControlCenterFixture.Data

  alias Aiur.{Decision, DecisionAnswer, RecentMerge}

  @port String.to_integer(System.get_env("AIUR_DOCS_PORT", "4099"))

  @doc false
  # The emulator's grid comes from this snapshot, in the same bucket shape the
  # orchestrator publishes. Every bucket is populated so each key face state —
  # alert, stuck, running, paused, queued — is visible in one capture.
  def streamdeck_snapshot do
    %{
      running: [
        streamdeck_agent("EX-142", "Prepare example release", "codex", progress_percent: 62),
        streamdeck_agent("EX-146", "Add example rate limiting", "claude", progress_percent: 41),
        streamdeck_agent("EX-147", "Render the example usage view", "codex", progress_percent: 18)
      ],
      retrying: [streamdeck_agent("EX-144", "Validate example webhook", "codex", work_state: :error, progress_percent: 100)],
      idle: [
        streamdeck_agent("EX-143", "Review retry policy", "claude", open_decision_count: 1),
        streamdeck_agent("EX-145", "Publish example changelog", "codex", work_state: :paused),
        streamdeck_agent("EX-148", "Seed the example dataset", "codex", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-149", "Export example rollups", "claude", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-150", "Cache example catalogue reads", "codex", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-151", "Add example soak coverage", "codex", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-152", "Localise the example shell", "claude", waiting_reason: :waiting_for_dependency),
        streamdeck_agent("EX-153", "Write the example runbook", "codex", waiting_reason: :waiting_for_dependency)
      ]
    }
  end

  @doc false
  # The capture never presses a key; this only keeps the control facade total.
  def streamdeck_noop(identifier), do: {:ok, to_string(identifier)}

  def streamdeck_agent(identifier, title, backend, attrs) do
    Map.merge(
      %{
        identifier: identifier,
        title: title,
        backend: backend,
        work_state: :working,
        open_decision_count: 0,
        waiting_reason: :active,
        tracker_paused: false,
        progress_percent: 50,
        priority: nil
      },
      Map.new(attrs)
    )
  end

  def fleet_snapshot do
    %{
      running: [
        running("EX-142", "Prepare example release", :active, 1, "Drafting the release checklist"),
        running("EX-143", "Review retry policy", :waiting_for_human, 1, "Waiting for a rollout decision"),
        running("EX-146", "Add example rate limiting", :active, 0, "Running the contract suite"),
        running("EX-147", "Render the example usage view", :active, 0, "Wiring the usage chart"),
        running("EX-148", "Seed the example dataset", :waiting_for_dependency, 0, "Waiting on the migration runner")
      ],
      retrying: [
        retrying("EX-144", "Validate example webhook", 2, 42_000, "Synthetic upstream timeout"),
        retrying("EX-151", "Add example soak coverage", 1, 118_000, "Synthetic sandbox restart")
      ],
      idle: [
        idle("EX-145", "Publish example changelog", "human-review", %{decision: :pass, pr_number: 145, head_sha: "example145"}),
        idle("EX-149", "Export example rollups", "human-review", %{decision: :fail, pr_number: 149, head_sha: "example149"}),
        idle("EX-150", "Cache example catalogue reads", "todo", nil),
        idle("EX-152", "Localise the example shell", "todo", nil),
        idle("EX-153", "Write the example runbook", "todo", nil)
      ],
      agent_totals: %{input_tokens: 128_400, output_tokens: 31_180, total_tokens: 159_580, seconds_running: 7_860},
      rate_limits: %{primary: %{remaining_percent: 72}}
    }
  end

  def retrying(identifier, title, attempt, due_in_ms, error) do
    %{
      issue_id: "example-#{identifier}",
      identifier: identifier,
      tracker_identity: unit_identity(identifier),
      state: "in-progress",
      title: title,
      url: "https://example.test/tickets/#{identifier}",
      attempt: attempt,
      due_in_ms: due_in_ms,
      error: error,
      waiting_reason: :backing_off,
      open_decision_count: 0,
      ci_result: nil
    }
  end

  def idle(identifier, title, state, ci_result) do
    %{
      issue_id: "example-#{identifier}",
      identifier: identifier,
      tracker_identity: unit_identity(identifier),
      state: state,
      title: title,
      url: "https://example.test/tickets/#{identifier}",
      tracker_paused: false,
      waiting_reason: :active,
      open_decision_count: 0,
      ci_result: ci_result
    }
  end

  def running(identifier, title, waiting_reason, open_count, message) do
    %{
      issue_id: "example-#{identifier}",
      identifier: identifier,
      tracker_identity: unit_identity(identifier),
      state: "in-progress",
      title: title,
      url: "https://example.test/tickets/#{identifier}",
      session_id: "example-session-#{identifier}",
      turn_count: 3,
      runtime_seconds: 840,
      work_state: :working,
      last_codex_event: "agent_message",
      last_codex_message: message,
      last_codex_timestamp: DateTime.add(now(), -35, :second),
      started_at: DateTime.add(now(), -840, :second),
      stale_for_seconds: 35,
      waiting_reason: waiting_reason,
      open_decision_count: open_count,
      ci_result: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
      agent_input_tokens: 4_200,
      agent_output_tokens: 980,
      agent_total_tokens: 5_180
    }
  end

  def decisions do
    [
      decision("dec-example-blocking", "EX-143", "Choose the rollout window", :critical, true),
      decision("dec-example-recorded", "EX-142", "Which release note should lead?", :normal, false),
      answered("dec-example-pending", "EX-146", "Approve the staged retry policy?", :queued, :decided),
      answered("dec-example-delivered", "EX-147", "Use the synthetic canary cohort?", :delivered, :decided),
      answered("dec-example-acknowledged", "EX-148", "Continue after the example audit?", :consumed, :acknowledged),
      answered("dec-example-resolved", "EX-149", "Close the sample migration?", :consumed, :resolved),
      answered("dec-example-failed", "EX-150", "Retry the example notification?", :failed, :decided)
    ] ++ resolved_backlog()
  end

  # A run's Commands surface is mostly history. The fixture carries enough of it
  # to show what the operator actually faces, and to make a page that renders
  # every past Command obvious.
  def resolved_backlog do
    Enum.map(1..24, fn index ->
      id = "dec-example-past-#{index}"
      ticket = "EX-#{200 + index}"

      {status, delivery} =
        case rem(index, 4) do
          0 -> {:resolved, :consumed}
          1 -> {:decided, :delivered}
          2 -> {:acknowledged, :consumed}
          3 -> {:deferred, :queued}
        end

      base = answered(id, ticket, "Synthetic past Command #{index}?", delivery, status)
      %{base | created_at: DateTime.add(now(), -1_800 - index * 600, :second)}
    end)
  end

  def decision(id, ticket, question, urgency, blocking) do
    %Decision{
      decision_id: id,
      version: 1,
      ticket: %{identifier: ticket, title: "Synthetic ticket #{ticket}", url: "https://example.test/tickets/#{ticket}"},
      source: %{agent_id: "example-agent-#{ticket}"},
      authority: :human_required,
      urgency: urgency,
      blocking: blocking,
      reversibility: :reversible,
      question: question,
      context: %{
        short_summary: "Example-only context for the documentation fixture.",
        long_context_markdown: "This decision uses synthetic agents, tickets, and outcomes."
      },
      options: [
        %{id: "morning", label: "Morning window", description: "Use the example morning window.", benefits: ["More coverage"], drawbacks: ["Slower start"], risk: :low},
        %{id: "evening", label: "Evening window", description: "Use the example evening window.", benefits: ["More preparation"], drawbacks: ["Smaller crew"], risk: :medium}
      ],
      artifacts: [%{kind: :url, value: "https://example.test/evidence/#{id}"}],
      recommendation: %{option_id: "morning", reason: "Lowest-risk synthetic option."},
      consequence_of_delay: "The example agent remains paused.",
      created_at: DateTime.add(now(), -900, :second),
      content_hash: "example-hash-#{id}"
    }
  end

  def answered(id, ticket, question, delivery_status, decision_status) do
    base = decision(id, ticket, question, :normal, false)

    {:ok, answer} =
      DecisionAnswer.normalize(
        %{idempotency_key: "example-#{id}", expected_version: 1, option_id: "morning", rationale: "Synthetic rationale for the docs."},
        decision_id: id,
        decision_version: 1,
        options: base.options,
        actor: %{kind: :operator, id: "example-operator"},
        now: DateTime.add(now(), -600, :second)
      )

    attempts =
      if delivery_status == :failed do
        [%{action_id: answer.action_id, status: :failed, failure_reason_class: :target_unavailable}]
      else
        []
      end

    %{
      base
      | answer: answer,
        active_action_id: answer.action_id,
        decision_status: decision_status,
        delivery_status: delivery_status,
        dispatch_attempts: attempts,
        acknowledgement: acknowledgement(decision_status),
        resolution: resolution(decision_status)
    }
  end

  def acknowledgement(status) when status in [:acknowledged, :resolved],
    do: %{actor: %{kind: :agent, id: "example-agent"}, acknowledged_at: DateTime.add(now(), -300, :second)}

  def acknowledgement(_status), do: nil

  def resolution(:resolved),
    do: %{actor: %{kind: :agent, id: "example-agent"}, resolved_at: DateTime.add(now(), -120, :second)}

  def resolution(_status), do: nil

  def history do
    [
      %{
        decision_id: "dec-example-resolved",
        ticket: %{identifier: "EX-149"},
        question: "Close the sample migration?",
        changed_at: DateTime.add(now(), -120, :second),
        event_kind: :resolved,
        actor: %{type: :ticket_agent, id: "example-agent", label: "Ticket agent"},
        choice: "Morning window",
        rationale: "All synthetic checks passed.",
        dispatch_result: :delivered,
        acknowledgement_result: :acknowledged
      },
      %{
        decision_id: "dec-example-pending",
        ticket: %{identifier: "EX-146"},
        question: "Approve the staged retry policy?",
        changed_at: DateTime.add(now(), -520, :second),
        event_kind: :answered,
        actor: %{type: :human_operator, id: "example-operator", label: "Executor"},
        choice: "Morning window",
        rationale: "Synthetic rationale for the docs.",
        dispatch_result: :queued
      }
    ]
  end

  def metrics(decisions) do
    Map.new(decisions, fn decision ->
      {decision.decision_id,
       %{
         requested_at: DateTime.add(now(), -900, :second),
         answered_at: if(decision.answer, do: DateTime.add(now(), -600, :second)),
         delivered_at: if(decision.delivery_status in [:delivered, :consumed], do: DateTime.add(now(), -450, :second)),
         acknowledged_at: if(decision.decision_status in [:acknowledged, :resolved], do: DateTime.add(now(), -300, :second)),
         resolved_at: if(decision.decision_status == :resolved, do: DateTime.add(now(), -120, :second))
       }}
    end)
  end

  def recent_merges do
    [
      recent_merge(318, "Publish synthetic retry guide", "EX-142", DateTime.add(now(), -1_800, :second)),
      recent_merge(317, "Add example release checks", "EX-145", DateTime.add(now(), -4_200, :second))
    ]
  end

  def recent_merge(number, title, ticket, merged_at) do
    %RecentMerge{
      id: "example/repository##{number}",
      repository: "example/repository",
      number: number,
      url: "https://example.test/pulls/#{number}",
      title: title,
      summary: "Synthetic merged outcome used only for documentation.",
      ticket_id: ticket,
      merged_at: merged_at,
      observation_source: :github_events,
      backfilled?: false,
      live_observed?: true,
      observed_run_id: "example-run",
      first_observed_at: merged_at,
      last_observed_at: merged_at,
      content_hash: "example-merge-hash-#{number}"
    }
  end

  def synthetic_workflow(tmp) do
    """
    tracker:
      kind: memory
      active_states: [todo, in-progress]
      terminal_states: [done]
    agent:
      kind: codex
      max_concurrent_agents: 1
      max_turns: 1
    polling:
      interval_seconds: 30
    workspace:
      root: #{Path.join(tmp, "workspaces")}
    observability:
      dashboard_enabled: true
      dashboard_writable: false
    server:
      host: 127.0.0.1
      port: #{@port}
    """
  end
end
