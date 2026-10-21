defmodule Aiur.Orchestrator.State do
  @moduledoc "Runtime state for the orchestrator polling loop. Field owners: `Aiur.Orchestrator.State.Owners`."
  alias Aiur.{AgentQueueStore, Issue, TrackerIdentity}
  alias Aiur.Orchestrator.ControlLifecycle

  @default_dispatch_recovery %{
    workspace_ownership: %{waits: %{}, ready: %{}},
    codex_thrash_budget: %{}
  }

  @type t :: %__MODULE__{
          poll_interval_ms: integer() | nil,
          effective_poll_interval_ms: integer() | nil,
          idle_poll_backoff: %{active?: boolean(), factor: float()} | nil,
          snapshot_key: GenServer.server() | nil,
          snapshot_generation: reference() | nil,
          snapshot_ready?: boolean(),
          candidate_snapshot_fresh?: boolean(),
          poll_cycles_completed: non_neg_integer(),
          tracker_tasks: %{reference() => map()},
          restack_completed: map(),
          blocker_propagations: map(),
          last_dispatch_poll_at_ms: integer() | nil,
          dispatch_cycle_started_at_ms: integer() | nil,
          dispatch_cycle_started_monotonic_ms: integer() | nil,
          dispatch_cycle_watchdog_token: reference() | nil,
          dispatch_cycle_watchdog_timer_ref: reference() | nil,
          last_dispatch_cycle_completed_at_ms: integer() | nil,
          dispatch_cycle_stalled?: boolean(),
          dispatch_cycle_stage: String.t() | nil,
          queued_demand_hints: %{String.t() => non_neg_integer()},
          max_concurrent_agents: integer() | nil,
          session_max_concurrent_agents: integer() | nil,
          effective_concurrent_agents: integer() | nil,
          priority_dispatch_reservations: %{optional(String.t()) => pos_integer()},
          load_envelope_state: map(),
          capacity_hold:
            %{
              optional(:reclaimable_cpu_percent) => float(),
              optional(:reclaimable_cpu_threshold) => float(),
              signal: :memory | :file_descriptors | :run_queue | :load | :cpu_pressure | :build | :provider | :envelope,
              measured: term(),
              threshold: term(),
              measured_at: DateTime.t(),
              held_since_ms: integer(),
              alerted?: boolean()
            }
            | nil,
          dispatch_hold:
            %{
              reason: :tracker_preflight,
              detail: atom(),
              held_since_ms: integer()
            }
            | nil,
          next_poll_due_at_ms: integer() | nil,
          poll_check_in_progress: boolean() | nil,
          poll_frozen: boolean() | nil,
          tick_timer_ref: reference() | nil,
          tick_token: reference() | nil,
          initial_dispatch_cycle: boolean() | nil,
          startup_claim_reconciliation_complete?: boolean(),
          orphaned_claim_since: map(),
          startup_claim_reconciliation_failures: map(),
          contradictory_state_label_tickets: %{optional(String.t()) => %{identifier: String.t(), labels: [String.t()], since_ms: integer()}},
          contradictory_state_label_alert_active: boolean(),
          queue_store: term(),
          last_polled_issues: map(),
          terminal_verification_attempts: %{String.t() => non_neg_integer()},
          tracker_observations: %{optional(String.t()) => DateTime.t()},
          status_observed_at: DateTime.t() | nil,
          human_review_observed_ids: MapSet.t(String.t()) | nil,
          ci_lifecycle: %{
            optional(:broker_fast_retry_pending?) => boolean(),
            approved_heads: map(),
            passed_heads: map(),
            test_failure_heads: map(),
            base_repair_invalidations: map(),
            poll_cache: map(),
            rewakes: map(),
            parked_ready_alerts: MapSet.t() | nil
          },
          todo_over_capacity_alert_active: boolean(),
          prewarm_blocked_alert_active: boolean(),
          prewarm_blocked_alert_resolution_emitted: boolean(),
          tracker_preflight_alert_signature: String.t() | nil,
          tracker_preflight_alert_resolution_emitted: boolean(),
          capacity_starvation_resolution_emitted: boolean(),
          fleet_capacity_starvation_resolution_emitted: boolean(),
          observed_error_alerts: MapSet.t(),
          active_attention_topics: MapSet.t(),
          waiting_for_human_episodes: %{optional(String.t()) => %{since: DateTime.t(), alerted?: boolean()}},
          observed_error_alert_causes: %{optional(String.t()) => atom()},
          dispatch_capacity_constraints: [map()],
          dispatch_selection_hold: map() | nil,
          dispatch_declines: %{optional(String.t()) => term()},
          dispatch_capacity_sample: %{
            optional(:cpu_pressure | :pressure_threshold | :pressure_target | :memory_mb | :memory_threshold_mb) => term(),
            optional(:load_discount_reason | :load_daemon_nice) => :enabled | :unavailable | integer(),
            optional(:gate_signal) => number() | :unavailable,
            optional(:load_sampled_at_ms) => integer() | nil,
            load: number() | :unavailable,
            load_threshold: number() | nil,
            target: number() | nil,
            schedulers: pos_integer() | nil,
            observed_at: DateTime.t() | nil
          },
          capacity_starvation: %{
            since_ms: %{optional(String.t()) => integer()},
            alert_active: boolean(),
            signature: [String.t()],
            alerted: [String.t()]
          },
          fleet_capacity_starvation: %{since_ms: integer() | nil, alert_active: boolean(), effective_cap: pos_integer() | nil},
          # Monotonic ms when the DecisionStore first read as `:unavailable`
          # while dispatchable work was queued (nil when no such hold is in
          # progress). The `system.dispatch.decision_store_unavailable` alert is
          # Raised after the capacity-starvation dwell, not a momentary blip (#2453).
          decision_store_unavailable_since_ms: integer() | nil,
          decision_store_unavailable_alert_active: boolean(),
          decision_store_unavailable_alert_resolution_emitted: boolean(),
          dependency_circular_wait: %{
            optional(String.t()) => %{identifier: String.t(), waiting_count: pos_integer(), since_ms: integer(), alerted?: boolean()}
          },
          running: %{optional(String.t()) => %{optional(:start_mode) => :ready | :optimistic, optional(:optimistic_blockers) => [String.t()], optional(atom()) => term()}},
          running_issue_cache: %{optional(String.t()) => %{etag: String.t() | nil, issue: Issue.t()}},
          completed: MapSet.t(),
          claimed: MapSet.t(),
          dispatch_recovery: %{
            workspace_ownership: %{waits: map(), ready: map()},
            codex_thrash_budget: map()
          },
          retry_attempts: map(),
          comment_rework_retries: %{{String.t(), String.t()} => {reference(), String.t() | integer(), String.t() | atom()}},
          auto_resume: %{String.t() => map()},
          budget_hold_streaks: %{String.t() => map()},
          # Claims released after retry exhaustion until dispatch re-establishes ownership.
          released_claims: %{String.t() => map()},
          fallback_backoff: %{String.t() => {pos_integer(), integer()}},
          model_fallback_waiting: MapSet.t(),
          agent_totals: map() | nil,
          agent_rate_limits: map() | nil,
          codex_totals: map() | nil,
          codex_rate_limits: map() | nil,
          # Monotonic time the CI poll last ran, used to throttle it to the
          # `:ci` class cadence (#2309). `nil` until the first run.
          last_ci_poll_started_at_ms: integer() | nil,
          pr_review_seen_at: map(),
          # What the polls know about each ticket PR's draft state, loaded from
          # `PrReadyLedgerStore` on first use (`nil` until then). See
          # `ReadyForReviewTransitions` (#2707).
          pr_ready_ledger: Aiur.PrReadyLedgerStore.ledger() | nil,
          github_connectivity: map(),
          github_poll_delays: map(),
          globally_paused: boolean(),
          # Ticket identifiers with an open blocking Command, read once per
          # dispatch cycle from `DecisionStore.blocked_ticket_ids/1`. `nil`
          # means "never computed this cycle" (treated as no gate); a `MapSet`
          # holds exactly those tickets; `:unavailable` means the decision
          # store could not be read, which the dispatch gate treats as
          # fail-closed (unknown blocks hold new work).
          blocked_ticket_ids: MapSet.t(String.t()) | :unavailable | nil,
          ci_readiness_checked: boolean() | nil,
          ci_readiness_unavailable_alerted: boolean() | nil,
          ci_readiness_check_pid: pid() | nil,
          ci_readiness_check_token: reference() | nil,
          ci_readiness_check_provider: module() | nil,
          ci_readiness_retry_at_ms: integer() | nil,
          ci_readiness_scope: term(),
          ci_readiness_result: Aiur.CodeHost.CiReadiness.result() | nil,
          global_pause: %{paused_at: DateTime.t() | nil, source: String.t() | nil},
          merged_ticket_reconciliations: MapSet.t(),
          merged_ticket_issue_cache: map(),
          merged_ticket_reconciliation_failures: MapSet.t(),
          # `{issue_id, head_sha}` -> count of times that head SHA has been
          # routed into `agent:rework`, and the `{issue_id, head_sha}`
          # signatures already alerted on. The bound turns a same-head rework
          # loop into a single attention (#2422); see `ReworkGate`.
          rework_attempts: %{{String.t(), String.t()} => pos_integer()},
          rework_attempt_alerted: MapSet.t(),
          orphaned_agent_reap_count: non_neg_integer(),
          control_lifecycle: ControlLifecycle.t(),
          # Consecutive poll ticks the prewarm gate has held dispatch for a
          # warming base. Drives the at-most-once-per-N-ticks hold log so a
          # slow/stuck base build stays visible in the daemon log without
          # spamming it (see Dispatcher.log_prewarm_hold/2).
          prewarm_hold_ticks: non_neg_integer(),
          # Monotonic ms when the current consecutive prewarm hold began (nil
          # when no hold is in progress). The `system.dispatch.prewarm_blocked`
          # alert is only raised once a hold has persisted past
          # `Dispatcher.@prewarm_blocked_alert_after_ms`, so a routine refresh
          # probe — a hold that self-clears in seconds — is never reported while
          # a genuine block still is (see Dispatcher.maybe_emit_prewarm_blocked_alert/3).
          prewarm_hold_since_ms: non_neg_integer() | nil
        }

  # Keeping the correlated control lifecycle here preserves one process/state authority.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :poll_interval_ms,
    :effective_poll_interval_ms,
    :idle_poll_backoff,
    :snapshot_key,
    :snapshot_generation,
    :max_concurrent_agents,
    :session_max_concurrent_agents,
    :effective_concurrent_agents,
    :next_poll_due_at_ms,
    :dispatch_cycle_started_at_ms,
    :last_dispatch_cycle_completed_at_ms,
    :poll_check_in_progress,
    :poll_frozen,
    :tick_timer_ref,
    :tick_token,
    :initial_dispatch_cycle,
    :ci_readiness_checked,
    :ci_readiness_unavailable_alerted,
    :ci_readiness_check_pid,
    :ci_readiness_check_token,
    :ci_readiness_check_provider,
    :ci_readiness_retry_at_ms,
    :ci_readiness_scope,
    :ci_readiness_result,
    startup_claim_reconciliation_complete?: false,
    startup_claim_reconciliation_failures: %{},
    orphaned_claim_since: %{},
    load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil, bootstrap_complete?: false},
    capacity_hold: nil,
    dispatch_hold: nil,
    queue_store: AgentQueueStore.new(),
    last_polled_issues: %{},
    terminal_verification_attempts: %{},
    tracker_observations: %{},
    status_observed_at: nil,
    human_review_observed_ids: nil,
    ci_lifecycle: %{
      approved_heads: %{},
      passed_heads: %{},
      test_failure_heads: %{},
      base_repair_invalidations: %{},
      poll_cache: %{},
      rewakes: %{},
      parked_ready_alerts: nil,
      broker_fast_retry_pending?: false
    },
    todo_over_capacity_alert_active: false,
    prewarm_blocked_alert_active: false,
    prewarm_blocked_alert_resolution_emitted: false,
    tracker_preflight_alert_signature: nil,
    tracker_preflight_alert_resolution_emitted: false,
    capacity_starvation_resolution_emitted: false,
    fleet_capacity_starvation_resolution_emitted: false,
    observed_error_alerts: MapSet.new(),
    active_attention_topics: MapSet.new(),
    waiting_for_human_episodes: %{},
    observed_error_alert_causes: %{},
    dispatch_capacity_constraints: [],
    dispatch_selection_hold: nil,
    dispatch_declines: %{},
    dispatch_capacity_sample: %{load: :unavailable, load_threshold: nil, target: nil, schedulers: nil, observed_at: nil},
    dispatch_cycle_stalled?: false,
    dispatch_cycle_stage: nil,
    dispatch_cycle_started_monotonic_ms: nil,
    dispatch_cycle_watchdog_token: nil,
    dispatch_cycle_watchdog_timer_ref: nil,
    capacity_starvation: %{since_ms: %{}, alert_active: false, signature: [], alerted: []},
    fleet_capacity_starvation: %{since_ms: nil, alert_active: false, effective_cap: nil},
    decision_store_unavailable_since_ms: nil,
    decision_store_unavailable_alert_active: false,
    decision_store_unavailable_alert_resolution_emitted: false,
    dependency_circular_wait: %{},
    # Fleet aggregate for contradictory `agent:*` labels; State keeps the orchestrator the single writer (#2366).
    contradictory_state_label_tickets: %{},
    contradictory_state_label_alert_active: false,
    running: %{},
    running_issue_cache: %{},
    tracker_tasks: %{},
    restack_completed: %{},
    blocker_propagations: %{},
    completed: MapSet.new(),
    claimed: MapSet.new(),
    dispatch_recovery: @default_dispatch_recovery,
    retry_attempts: %{},
    # In-flight comment-rework timers are cancellable and cannot fire into a successor.
    comment_rework_retries: %{},
    auto_resume: %{},
    budget_hold_streaks: %{},
    released_claims: %{},
    fallback_backoff: %{},
    model_fallback_waiting: MapSet.new(),
    agent_totals: nil,
    agent_rate_limits: nil,
    codex_totals: nil,
    codex_rate_limits: nil,
    last_ci_poll_started_at_ms: nil,
    pr_review_seen_at: %{},
    pr_ready_ledger: nil,
    github_connectivity: %{},
    github_poll_delays: %{},
    globally_paused: false,
    blocked_ticket_ids: nil,
    global_pause: %{paused_at: nil, source: nil},
    # Reconciled merge receipts prevent retained records from closing a reopened ticket.
    merged_ticket_reconciliations: MapSet.new(),
    merged_ticket_issue_cache: %{},
    # `{{issue_identifier, recent_merge_id}, reason}` signatures already alerted on, so a
    # permanently failing transition raises its attention once instead of once per poll.
    merged_ticket_reconciliation_failures: MapSet.new(),
    rework_attempts: %{},
    rework_attempt_alerted: MapSet.new(),
    snapshot_ready?: false,
    candidate_snapshot_fresh?: true,
    # Idle backoff requires a completed cycle; a fresh daemon first polls at the base interval (#2138).
    poll_cycles_completed: 0,
    last_dispatch_poll_at_ms: nil,
    # Tickets queued locally (`aiur --todo`) that the tracker poll has not yet
    # shown, keyed by identifier to the poll-cycle count until which each one
    # still counts as dispatchable demand. The idle backoff must not widen on
    # a snapshot that predates a ticket the operator just told us about (#2640).
    queued_demand_hints: %{},
    orphaned_agent_reap_count: 0,
    control_lifecycle: %ControlLifecycle{},
    prewarm_hold_ticks: 0,
    prewarm_hold_since_ms: nil,
    priority_dispatch_reservations: %{}
  ]

  @spec handle_worker_runtime_info(t(), String.t(), map()) :: {:noreply, t()}
  defdelegate handle_worker_runtime_info(state, issue_id, runtime_info), to: __MODULE__.RuntimeInfo
  @spec handle_live_conversation_restart(t(), String.t(), DateTime.t()) :: {:noreply, t()}
  defdelegate handle_live_conversation_restart(state, projection_epoch, observed_at), to: __MODULE__.RuntimeInfo
  @spec handle_repl_session_runtime(t(), String.t(), map()) :: {:noreply, t()}
  defdelegate handle_repl_session_runtime(state, issue_id, info), to: __MODULE__.RuntimeInfo
  @spec handle_session_execution_info(t(), String.t(), map()) :: {:noreply, t()}
  defdelegate handle_session_execution_info(state, issue_id, info), to: __MODULE__.RuntimeInfo
  @spec handle_session_resolved_model(t(), String.t(), String.t()) :: {:noreply, t()}
  defdelegate handle_session_resolved_model(state, issue_id, model), to: __MODULE__.RuntimeInfo
  @spec note_agent_activity(t(), String.t()) :: t()
  defdelegate note_agent_activity(state, identifier), to: __MODULE__.RuntimeInfo
  @spec alive?(term()) :: boolean()
  defdelegate alive?(name), to: __MODULE__.RuntimeInfo
  @spec maybe_put_runtime_value(term(), term(), term()) :: term()
  defdelegate maybe_put_runtime_value(entry, key, value), to: __MODULE__.RuntimeInfo
  @spec find_issue_id_for_ref(map(), term()) :: term() | nil
  defdelegate find_issue_id_for_ref(running, ref), to: __MODULE__.RunningEntries
  @spec running_entry_session_id(term()) :: String.t()
  defdelegate running_entry_session_id(entry), to: __MODULE__.RunningEntries
  @spec issue_context(Issue.t()) :: String.t()
  defdelegate issue_context(issue), to: __MODULE__.RunningEntries
  @spec active_running_count(term()) :: non_neg_integer()
  defdelegate active_running_count(running), to: __MODULE__.RunningEntries
  @spec paused_running_count(term()) :: non_neg_integer()
  defdelegate paused_running_count(running), to: __MODULE__.RunningEntries
  @spec non_reserving_pause_reason?(term()) :: boolean()
  defdelegate non_reserving_pause_reason?(reason), to: __MODULE__.RunningEntries
  @spec reserved_paused_running_count(term()) :: non_neg_integer()
  defdelegate reserved_paused_running_count(running), to: __MODULE__.RunningEntries
  @spec active_running_entry?(term()) :: boolean()
  defdelegate active_running_entry?(entry), to: __MODULE__.RunningEntries
  @spec paused_running_entry?(term()) :: boolean()
  defdelegate paused_running_entry?(entry), to: __MODULE__.RunningEntries
  @spec error_running_entry?(term()) :: boolean()
  defdelegate error_running_entry?(entry), to: __MODULE__.RunningEntries
  @spec sleeping_running_entry?(term()) :: boolean()
  defdelegate sleeping_running_entry?(entry), to: __MODULE__.RunningEntries
  @spec completed_running_entry?(term()) :: boolean()
  defdelegate completed_running_entry?(entry), to: __MODULE__.RunningEntries
  @spec completed_provenance?(term()) :: boolean()
  defdelegate completed_provenance?(entry), to: __MODULE__.RunningEntries
  @spec deactivated_running_entry?(term()) :: boolean()
  defdelegate deactivated_running_entry?(entry), to: __MODULE__.RunningEntries
  @spec find_running_key_by_identifier(map(), String.t()) :: term() | nil
  defdelegate find_running_key_by_identifier(running, identifier), to: __MODULE__.RunningEntries
  @spec apply_pause_runtime_clock(map(), atom(), atom(), term()) :: map()
  defdelegate apply_pause_runtime_clock(entry, previous, next, now), to: __MODULE__.RunningEntries
  @spec thaw_pause_clock(map(), term(), atom(), term()) :: map()
  defdelegate thaw_pause_clock(running, issue_id, previous_status, now), to: __MODULE__.RunningEntries
  @spec shift_started_at_by_pause_if(map(), atom(), term()) :: map()
  defdelegate shift_started_at_by_pause_if(entry, previous, now), to: __MODULE__.RunningEntries
  @spec shift_started_at_by_pause(map(), term()) :: map()
  defdelegate shift_started_at_by_pause(entry, now), to: __MODULE__.RunningEntries
  @spec issue_tag(term()) :: String.t() | nil
  defdelegate issue_tag(issue), to: __MODULE__.RunningEntries
  @spec find_running_by_identifier(map(), String.t()) :: map() | nil
  defdelegate find_running_by_identifier(running, issue_identifier), to: __MODULE__.RunningEntries

  @spec find_unique_running_by_identity(map(), TrackerIdentity.t()) ::
          {:ok, map(), String.t()} | {:error, :no_running_agent | :ambiguous_identifier}
  defdelegate find_unique_running_by_identity(running, identity), to: __MODULE__.RunningEntries
  @spec find_running_by_repl_pane_id(map(), term()) :: map() | nil
  defdelegate find_running_by_repl_pane_id(running, pane_id), to: __MODULE__.RunningEntries
  @spec pop_running_entry(t(), term()) :: {term(), t()}
  defdelegate pop_running_entry(state, issue_id), to: __MODULE__.RunningEntries
  @spec running_seconds(term(), term()) :: non_neg_integer()
  defdelegate running_seconds(started_at, now), to: __MODULE__.RunningEntries
  @spec effective_runtime_seconds(term(), DateTime.t()) :: non_neg_integer()
  defdelegate effective_runtime_seconds(entry, now), to: __MODULE__.RunningEntries
  @spec rework_attempt_limit() :: pos_integer()
  defdelegate rework_attempt_limit(), to: __MODULE__.RunningEntries
  @spec rework_attempt_count(t(), String.t(), String.t() | nil) :: non_neg_integer()
  defdelegate rework_attempt_count(state, issue_id, head_sha), to: __MODULE__.RunningEntries
  @spec rework_attempt_limit_reached?(t(), String.t(), String.t() | nil) :: boolean()
  defdelegate rework_attempt_limit_reached?(state, issue_id, head_sha), to: __MODULE__.RunningEntries
  @spec bump_rework_attempt(t(), String.t(), String.t() | nil) :: t()
  defdelegate bump_rework_attempt(state, issue_id, head_sha), to: __MODULE__.RunningEntries
  @spec rework_attempt_alerted?(t(), String.t(), String.t()) :: boolean()
  defdelegate rework_attempt_alerted?(state, issue_id, head_sha), to: __MODULE__.RunningEntries
  @spec mark_rework_attempt_alerted(t(), String.t(), String.t()) :: t()
  defdelegate mark_rework_attempt_alerted(state, issue_id, head_sha), to: __MODULE__.RunningEntries
end
