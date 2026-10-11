defmodule Aiur.Orchestrator.StatusReport.SnapshotPayload do
  @moduledoc false
  # Builds the dashboard/CLI snapshot payload from one state copy.

  import Aiur.Orchestrator.StatusReport.AgentStatuses, only: [idle_evidence: 5, idle_evidence_waiting_reason: 2]
  import Aiur.Orchestrator.StatusReport.Progress, only: [activity_by_identity: 0, activity_stage: 2, progress_facts: 2]
  import Aiur.Orchestrator.StatusReport.RowFacts

  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.Orchestrator.CapacityBinding
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusObservation
  alias Aiur.Orchestrator.WaitingReason
  alias Aiur.PollCadence

  @doc false
  @spec snapshot_payload(State.t()) :: map()
  def snapshot_payload(%State{} = state) do
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)
    stall_timeout_seconds = stall_timeout_seconds()
    activity_by_identity = activity_by_identity()

    running =
      Enum.map(
        state.running,
        &running_snapshot(state, &1, now, stall_timeout_seconds, activity_by_identity)
      )

    retrying =
      Enum.map(state.retry_attempts, &retry_snapshot(state, &1, now_ms, activity_by_identity))

    idle = idle_snapshot(state, now_ms, activity_by_identity)

    %{
      running: running,
      retrying: retrying,
      idle: idle,
      # Build CLI rows on demand on the reader, not on every publish (#1837).
      agent_totals: state.agent_totals,
      capacity: Slots.max_concurrent_agent_status(state),
      capacity_hold: capacity_hold_payload(state, now_ms),
      dispatch_hold: dispatch_hold_payload(state, now_ms),
      orphaned_agent_reap_count: state.orphaned_agent_reap_count,
      globally_paused: state.globally_paused == true,
      global_pause: %{
        globally_paused: state.globally_paused == true,
        paused_at: Map.get(state.global_pause, :paused_at),
        source: Map.get(state.global_pause, :source)
      },
      rate_limits: Map.get(state, :agent_rate_limits),
      polling: %{
        last_dispatch_poll_age_ms: dispatch_poll_age_ms(state.last_dispatch_poll_at_ms, now_ms),
        checking?: state.poll_check_in_progress == true,
        next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
        poll_interval_ms: state.poll_interval_ms,
        effective_interval_ms: state.effective_poll_interval_ms || state.poll_interval_ms,
        idle_backoff: state.idle_poll_backoff,
        tracker_snapshot_fresh?: state.candidate_snapshot_fresh?,
        class_intervals: PollCadence.effective_intervals()
      }
    }
    |> StatusObservation.attach(state, now)
  end

  defp dispatch_poll_age_ms(last_ms, now_ms) when is_integer(last_ms), do: max(now_ms - last_ms, 0)
  defp dispatch_poll_age_ms(_last_ms, _now_ms), do: nil

  defp capacity_hold_payload(%State{} = state, now_ms) do
    case state.capacity_hold do
      %{signal: signal, measured: measured, threshold: threshold, held_since_ms: held_since_ms} = hold ->
        %{
          held?: true,
          signal: signal,
          measured: measured,
          detail: Map.get(hold, :detail),
          threshold: threshold,
          held_for_seconds: max(div(now_ms - held_since_ms, 1_000), 0),
          # How long the hold has lasted and how old its measurement is are
          # different quantities: a hold extended without a fresh probe keeps
          # ageing while `held_for_seconds` grows too, and only this one says
          # whether the figure beside it still describes the host (#2527).
          sample_age_seconds: CapacityBinding.sample_age_seconds(hold)
        }

      _other ->
        %{
          held?: false,
          signal: nil,
          measured: nil,
          detail: nil,
          threshold: nil,
          held_for_seconds: 0,
          sample_age_seconds: nil
        }
    end
  end

  defp dispatch_hold_payload(state, now_ms), do: Slots.dispatch_hold_status(state, now_ms)

  defp running_snapshot(
         %State{} = state,
         {issue_id, metadata},
         now,
         stall_timeout_seconds,
         activity_by_identity
       ) do
    capabilities = OM.issue_control_capabilities(state, metadata.identifier, metadata)
    work_state = startup_work_state(metadata)
    pause_reason = Map.get(metadata, :paused_reason)
    started_at = Map.get(metadata, :started_at)
    stale_for_seconds = stale_for_seconds(metadata, now)
    {open_decision_count, open_decision_count_health} = open_decision_count(metadata.identifier)

    waiting_reason =
      WaitingReason.for_running(%{
        tracker_state: metadata.issue.state,
        pause_reason: pause_reason,
        work_state: work_state,
        open_decision_count: open_decision_count,
        stale_for_seconds: stale_for_seconds,
        stall_timeout_seconds: stall_timeout_seconds
      })

    %{
      issue_id: issue_id,
      identifier: metadata.identifier,
      tracker_identity: Issue.tracker_identity(metadata.issue),
      state: metadata.issue.state,
      tag: State.issue_tag(metadata.issue),
      title: Map.get(metadata.issue, :title),
      url: Map.get(metadata.issue, :url),
      worker_host: Map.get(metadata, :worker_host),
      workspace_path: Map.get(metadata, :workspace_path),
      session_id: Map.get(metadata, :session_id),
      live_conversation: Map.get(metadata, :live_conversation),
      codex_app_server_pid: Map.get(metadata, :codex_app_server_pid),
      agent_input_tokens: Map.get(metadata, :agent_input_tokens, 0),
      agent_output_tokens: Map.get(metadata, :agent_output_tokens, 0),
      agent_total_tokens: Map.get(metadata, :agent_total_tokens, 0),
      context_usage: Map.get(metadata, :context_usage),
      telemetry_attempt_id: Map.get(metadata, :telemetry_attempt_id),
      turn_count: Map.get(metadata, :turn_count, 0),
      turn_count_observed?: Map.has_key?(metadata, :turn_count),
      started_at: started_at,
      last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
      last_codex_message: Map.get(metadata, :last_codex_message),
      last_codex_event: Map.get(metadata, :last_codex_event),
      work_state: work_state,
      pause_reason: pause_reason,
      tracker_paused: Issue.paused?(metadata.issue),
      queue_depth: capabilities.queue_depth,
      pending_operator_messages: OM.pending_operator_messages_for_issue(state, metadata.identifier),
      control: capabilities,
      runtime_seconds: State.running_seconds(started_at, now),
      stale_for_seconds: stale_for_seconds,
      waiting_reason: waiting_reason,
      blocked_by: known_blocked_by(metadata.issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health,
      priority: Map.get(metadata.issue, :priority),
      activity_stage: activity_stage(Issue.tracker_identity(metadata.issue), activity_by_identity),
      ci_result: cached_ci_result(state, metadata.identifier)
    }
    |> Map.merge(progress_facts(Issue.tracker_identity(metadata.issue), activity_by_identity))
    |> Map.merge(running_execution_facts(metadata))
    |> WaitingReason.attach(state, metadata)
  end

  defp retry_snapshot(
         %State{} = state,
         {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry},
         now_ms,
         activity_by_identity
       ) do
    identifier = Map.get(retry, :identifier)
    issue = Map.get(visible_polled_issues(state), issue_id)
    tracker_identity = retry_snapshot_tracker_identity(retry, issue)
    {open_decision_count, open_decision_count_health} = open_decision_count(identifier)

    %{
      issue_id: issue_id,
      attempt: attempt,
      due_in_ms: max(0, due_at_ms - now_ms),
      identifier: identifier,
      tracker_identity: tracker_identity,
      state: issue && issue.state,
      tag: issue && State.issue_tag(issue),
      title: issue && issue.title,
      url: issue && issue.url,
      error: Map.get(retry, :error),
      last_failure_at: Map.get(retry, :last_failure_at),
      work_state: :retrying,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      waiting_reason: WaitingReason.for_retry(),
      blocked_by: known_blocked_by(issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health,
      priority: Map.get(issue || %{}, :priority) || Map.get(retry, :priority),
      activity_stage: activity_stage(tracker_identity, activity_by_identity),
      ci_result: cached_ci_result(state, identifier)
    }
    |> Map.merge(progress_facts(tracker_identity, activity_by_identity))
    |> Map.merge(issue_execution_facts(issue))
    |> WaitingReason.attach(state)
  end

  defp idle_snapshot(%State{} = state, now_ms, activity_by_identity) do
    running_issue_ids = MapSet.new(Map.keys(state.running))

    # Also exclude issues already shown in the retry-backoff bucket — they're
    # tracker-active (still in `last_polled_issues`) but not in `running`,
    # so without this they'd double up as a contradictory second row here.
    retrying_issue_ids = MapSet.new(Map.keys(state.retry_attempts))

    excluded_issue_ids = MapSet.union(running_issue_ids, retrying_issue_ids)
    terminal_states = DispatchPolicy.terminal_state_set()

    idle_issues =
      visible_polled_issues(state)
      |> Enum.reject(fn {issue_id, _issue} -> MapSet.member?(excluded_issue_ids, issue_id) end)

    # One durable-store read for the whole board, not one per idle ticket.
    latch_statuses =
      Dispatcher.dispatch_latch_statuses(state, Enum.map(idle_issues, fn {id, _} -> id end))

    Enum.map(idle_issues, fn {_issue_id, issue} ->
      idle_issue_snapshot(
        state,
        issue,
        terminal_states,
        now_ms,
        latch_statuses,
        activity_by_identity
      )
    end)
  end

  defp idle_issue_snapshot(
         %State{} = state,
         %Issue{} = issue,
         _terminal_states,
         now_ms,
         latch_statuses,
         activity_by_identity
       ) do
    identifier = issue.identifier || issue.id
    {open_decision_count, open_decision_count_health} = open_decision_count(identifier)
    latch = Map.get(latch_statuses, issue.id, :none)
    release = Map.get(state.released_claims, issue.id)
    idle_evidence = idle_evidence(state, issue, latch, open_decision_count, now_ms)

    %{
      issue_id: issue.id,
      identifier: identifier,
      tracker_identity: Issue.tracker_identity(issue),
      state: issue.state,
      work_state: idle_issue_work_state(issue),
      pause_reason: idle_issue_pause_reason(issue),
      tag: State.issue_tag(issue),
      title: issue.title,
      url: issue.url,
      tracker_paused: Issue.paused?(issue),
      queue_depth: OM.queue_depth_for_issue(state, identifier),
      # #1453 supplies the idle-reason evidence; #1457 renders it.
      dispatch_latch: idle_evidence.dispatch_latch,
      auto_resume_retry_in_ms: idle_evidence.auto_resume_retry_in_ms,
      dispatch_hold_reason: idle_evidence.dispatch_hold_reason,
      capacity_hold_active?: idle_evidence.capacity_hold_active?,
      dispatch_decline_reason: Map.get(state.dispatch_declines, issue.id),
      waiting_reason: idle_evidence_waiting_reason(idle_evidence, release),
      claim_released?: not is_nil(release),
      claim_release_cause: release && release.cause,
      blocked_by: known_blocked_by(issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health,
      priority: Map.get(issue, :priority),
      activity_stage: activity_stage(Issue.tracker_identity(issue), activity_by_identity),
      ci_result: cached_ci_result(state, identifier)
    }
    |> Map.merge(progress_facts(Issue.tracker_identity(issue), activity_by_identity))
    |> Map.merge(issue_execution_facts(issue))
    |> WaitingReason.attach(state)
  end

  defp issue_execution_facts(%Issue{} = issue) do
    backend = CodingAgent.backend_for(issue)

    %{
      backend: backend,
      agent_family: CodingAgent.family_for(backend),
      requested_model: CodingAgent.model_for(issue),
      effort: CodingAgent.effort_for(issue)
    }
    |> Map.merge(issue_classification_facts(issue))
  end

  defp issue_execution_facts(_issue), do: %{}

  defp running_execution_facts(entry) do
    execution = session_execution(entry)
    backend = Map.get(execution, :backend)

    %{
      backend: backend,
      agent_family: CodingAgent.family_for(backend),
      requested_model: Map.get(execution, :requested_model),
      resolved_model: Map.get(execution, :resolved_model),
      effort: Map.get(execution, :effort),
      account: Map.get(execution, :account),
      account_selection_reason: Map.get(execution, :account_selection_reason)
    }
    |> Map.merge(issue_classification_facts(Map.get(entry, :issue)))
  end

  defp issue_classification_facts(%Issue{} = issue) do
    %{
      complexity: issue_complexity(issue),
      labels: Issue.label_names(issue)
    }
  end

  defp issue_classification_facts(_issue), do: %{}

  defp cached_ci_result(%State{} = state, identifier) do
    state.ci_lifecycle
    |> Map.get(:poll_cache, %{})
    |> Map.get(identifier)
  end

  @spec next_poll_in_ms(integer() | nil, integer()) :: non_neg_integer() | nil
  def next_poll_in_ms(nil, _now_ms), do: nil

  def next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end
end
