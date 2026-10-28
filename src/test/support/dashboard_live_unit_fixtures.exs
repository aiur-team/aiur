defmodule AiurWeb.DashboardLiveSupport.UnitFixtures do
  @moduledoc false

  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1, record: 3]

  alias Aiur.BuildOrder.Lifecycle
  alias Aiur.OpenTicketSource.Snapshot, as: OpenTicketSnapshot
  alias Aiur.TrackerIdentity
  alias Aiur.Usage.Headless.Codex.ThreadUsage

  def open_ticket_snapshot(tickets) do
    %OpenTicketSnapshot{
      status: :available,
      generation: 1,
      observed_at: ~U[2026-07-17 12:00:00Z],
      tickets: tickets
    }
  end

  def open_ticket(identifier, labels, overrides \\ %{}) do
    Map.merge(
      %{
        identity: units_identity(provider_id: "NODE-#{identifier}", database_id: nil, identifier: identifier),
        identifier: identifier,
        title: "Unrouted backlog ticket",
        body_excerpt: nil,
        url: "https://github.com/its-everdred/aiur/issues/#{identifier}",
        state: "Todo",
        labels: labels,
        assignee: nil,
        created_at: ~U[2026-07-16 12:00:00Z],
        updated_at: ~U[2026-07-17 11:00:00Z]
      },
      Map.new(overrides)
    )
  end

  def units_identity(overrides \\ []) do
    struct!(
      TrackerIdentity,
      Keyword.merge(
        [
          status: :joinable,
          kind: :github,
          owner: "its-everdred",
          repository: "aiur",
          provider_id: "NODE-1110",
          database_id: 1110,
          identifier: "1110",
          reason: nil
        ],
        overrides
      )
    )
  end

  def attempt_usage_cells(identity) do
    relationship_revision = ThreadUsage.relationship_revision()
    ticket = TrackerIdentity.github_key(identity)

    for {attempt_id, values} <- [
          {"attempt-1110", %{input: 150, cached_input: 40, output: 30}},
          {"attempt-other", %{input: 900, cached_input: 600, output: 200}}
        ],
        {dimension, amount} <- values,
        into: %{} do
      dims = %{provider: :codex, attempt_id: attempt_id, ticket: ticket, relationship_revision: relationship_revision}
      {{dims, {:token, dimension}}, amount}
    end
  end

  def attempt_usage_record(identity) do
    thread_usage = ThreadUsage

    usage_envelope =
      envelope(%{
        idempotency_key: "dashboard-attempt-usage",
        source: thread_usage.source(),
        source_version: thread_usage.source_version(),
        source_event_id: "dashboard-attempt-usage",
        source_sequence: 1,
        relationship_revision: thread_usage.relationship_revision(),
        measurement_kind: :absolute,
        counter_scope: :thread,
        update_kind: :full,
        attribution: %{
          run_id: "run-1110",
          tracker_identity: identity,
          attempt_id: "attempt-1110",
          session_id: "session-1110",
          thread_id: "thread-1110",
          turn_id: nil,
          request_id: nil
        },
        tokens: %{
          input: 150,
          cached_input: 40,
          cache_creation_input: nil,
          output: 30,
          reasoning_output: nil,
          provider_reported_total: nil
        }
      })

    record(1, usage_envelope, %{tokens: usage_envelope.tokens})
  end

  def context_subscription(test_pid, event, identity) do
    send(test_pid, {event, identity})
    :ok
  end

  def units_membership(identity) do
    observed_at = ~U[2026-07-17 12:00:00Z]

    %{
      run_id: "run-units",
      generation: 1,
      health: :healthy,
      health_message: nil,
      freshness: %{status: :fresh, observed_at: observed_at},
      members: [
        %{
          identity: identity,
          lifecycle: :active,
          terminal?: false,
          first_observed_at: observed_at,
          last_observed_at: observed_at
        }
      ],
      truncated?: false
    }
  end

  def units_activity(identity) do
    %{
      generation: 1,
      health: :healthy,
      freshness: %{status: :fresh},
      entries: [
        %{
          identity: identity,
          progress: %{status: :known, percent: 50, source: :checkin, freshness: :fresh},
          latest_evidence: %{status: :known, source: %{kind: :branch, name: "feature pushed"}}
        }
      ]
    }
  end

  def units_orchestrator_snapshot(identity) do
    %{
      running: [
        %{
          issue_id: "issue-1110",
          identifier: "1110",
          tracker_identity: identity,
          state: "in-progress",
          title: "Responsive Units interface",
          url: "https://github.com/its-everdred/aiur/issues/1110",
          labels: ["complexity:3", "build-lane:L2"],
          backend: :codex,
          agent_family: :codex,
          requested_model: "gpt-5.6-terra",
          resolved_model: nil,
          effort: :high,
          complexity: 3,
          build_lane: "L2",
          session_id: "session-1110",
          started_at: ~U[2026-07-17 11:00:00Z],
          last_codex_timestamp: ~U[2026-07-17 11:59:00Z],
          last_codex_event: :progress,
          last_codex_message: "Building responsive Units",
          runtime_seconds: 3_600,
          work_state: :working,
          tracker_paused: false,
          waiting_reason: :active,
          open_decision_count: 0,
          open_decision_count_health: :available,
          control: %{},
          ci_result: nil
        }
      ],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 3_600},
      rate_limits: nil
    }
  end

  def conversation_handle_value(seed) when is_binary(seed) do
    "conversation:" <> String.duplicate(seed, 43)
  end

  def units_conversation_snapshot(identity, handle) do
    snapshot = units_orchestrator_snapshot(identity)

    running =
      snapshot.running
      |> hd()
      |> Map.put(:live_conversation, %{
        generation_handle: handle,
        state: :live,
        health: :healthy,
        freshness: :current,
        observed_at: ~U[2026-07-17 12:00:00Z],
        reason: nil
      })

    %{snapshot | running: [running]}
  end

  def conversation_snapshot(handle, overrides \\ []) do
    body = Keyword.get(overrides, :message_body, "Reviewing the drawer")
    state = Keyword.get(overrides, :state, :live)

    %{
      version: 1,
      projection_epoch: "epoch-1",
      revision: 1,
      source_revision: 1,
      generation_handle: handle,
      source: %{run_id: "run-units", session_id: "opaque-session", worker_generation: 4},
      state: state,
      health: :healthy,
      freshness: :current,
      messages: [
        %{
          id: "m1",
          role: "agent",
          title: "Assistant",
          body: body,
          occurred_at: ~U[2026-07-17 12:00:00Z],
          observed_at: ~U[2026-07-17 12:00:00Z]
        }
      ],
      observed_at: ~U[2026-07-17 12:00:00Z],
      diagnostic_counts: %{},
      truncated?: false,
      evicted_count: 0
    }
  end

  def units_ticket_detail(identity, title) do
    observed_at = ~U[2026-07-17 12:00:00Z]

    %Aiur.BuildOrder.TicketDetail.State{
      identity: identity,
      generation: 1,
      health: :healthy,
      detail: %Aiur.BuildOrder.TicketDetail.Snapshot{
        identity: identity,
        title: title,
        description: "Bounded reusable ticket context",
        lifecycle: Lifecycle.from_github("OPEN", nil),
        url: "https://github.com/its-everdred/aiur/issues/#{identity.identifier}",
        created_at: observed_at,
        updated_at: observed_at,
        observed_at: observed_at
      },
      last_success_at: observed_at,
      last_attempt_at: observed_at
    }
  end

  def units_ticket_history(identity) do
    %Aiur.BuildOrder.TicketHistory.Snapshot{
      identity: identity,
      generation: 1,
      health: :available,
      status_label: "Current activity",
      progress: %{status: :known, percent: 50, source: :checkin, observed_at: ~U[2026-07-17 12:00:00Z]},
      latest_evidence: %{
        status: :known,
        source: %{kind: :branch, name: "feature pushed"},
        observed_at: ~U[2026-07-17 12:00:00Z]
      },
      entries: [],
      truncated?: false,
      observed_at: ~U[2026-07-17 12:00:00Z],
      freshness: :fresh,
      source_health: %{activity: :available, history: :available}
    }
  end
end
