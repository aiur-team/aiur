defmodule Aiur.Orchestrator.StatusReport.AgentStatuses do
  @moduledoc false
  # Builds the `status`/`watch` rows for running, retrying and idle tickets.

  import Aiur.Orchestrator.StatusReport.RowFacts

  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.AutoResume
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReason
  alias Aiur.Orchestrator.WaitingReason
  alias Aiur.RepoBase
  alias Aiur.Workspace.Ownership.HoldStatus

  @repo_base_status_timeout_ms 100

  @spec agent_statuses(State.t()) :: [map()]
  def agent_statuses(%State{} = state) do
    status_fun =
      if Config.prewarm_enabled?(),
        do: &RepoBase.status/1,
        else: fn _timeout -> {:unavailable, nil} end

    agent_statuses(state, status_fun)
  end

  @doc false
  @spec agent_statuses(State.t(), (timeout() -> term())) :: [map()]
  def agent_statuses(%State{} = state, status_fun) when is_function(status_fun, 1) do
    {statuses, _state} = agent_statuses_raw(state, status_fun)
    statuses
  end

  defp agent_statuses_raw(%State{} = state, status_fun) when is_function(status_fun, 1) do
    now = DateTime.utc_now()
    prewarm_phase = prewarm_phase(status_fun)

    running_by_identifier =
      Map.new(state.running, fn {_id, entry} -> {Map.get(entry, :identifier), entry} end)

    statuses =
      (running_statuses(state, now) ++
         retry_statuses(state) ++ idle_statuses(state, running_by_identifier, prewarm_phase))
      |> Enum.sort_by(fn status -> to_string(status.identifier || status.issue_id || "") end)

    {statuses, state}
  end

  defp running_statuses(%State{} = state, %DateTime{} = now) do
    Enum.map(state.running, fn {issue_id, entry} ->
      running_status(state, issue_id, entry, now)
    end)
  end

  defp running_status(%State{} = state, issue_id, entry, now) do
    identifier = Map.get(entry, :identifier) || issue_id
    issue = Map.get(entry, :issue) || %{}
    work_state = startup_work_state(entry)
    capabilities = OM.issue_control_capabilities(state, identifier, entry)
    pause_reason = Map.get(entry, :paused_reason)
    {open_decision_count, open_decision_count_health} = open_decision_count(identifier)
    stale_for_seconds = stale_for_seconds(entry, now)

    waiting_reason =
      WaitingReason.for_running(%{
        tracker_state: Map.get(issue, :state),
        pause_reason: pause_reason,
        work_state: work_state,
        open_decision_count: open_decision_count,
        stale_for_seconds: stale_for_seconds,
        stall_timeout_seconds: stall_timeout_seconds()
      })

    %{
      issue_id: issue_id,
      identifier: identifier,
      tracker_identity: Issue.tracker_identity(issue),
      state: if(work_state == :paused, do: :paused, else: :running),
      work_state: work_state,
      tracker_state: Map.get(issue, :state),
      tracker_paused: Issue.paused?(issue),
      tag: State.issue_tag(issue),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      live_conversation: Map.get(entry, :live_conversation),
      runtime_seconds: State.running_seconds(Map.get(entry, :started_at), now),
      queue_depth: capabilities.queue_depth,
      control: capabilities,
      complexity: issue_complexity(issue),
      last_codex_timestamp: Map.get(entry, :last_codex_timestamp),
      last_codex_message: Map.get(entry, :last_codex_message),
      last_codex_event: Map.get(entry, :last_codex_event),
      reason: if(work_state == :paused, do: StatusReason.for_pause(pause_reason)),
      waiting_reason: waiting_reason,
      pause_reason: pause_reason,
      blocked_by: known_blocked_by(issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health
    }
    |> WaitingReason.attach(state, entry)
  end

  defp retry_statuses(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)

    Enum.map(state.retry_attempts, fn {issue_id, retry} ->
      issue = Map.get(visible_polled_issues(state), issue_id)
      identifier = Map.get(retry, :identifier) || Map.get(issue || %{}, :identifier) || issue_id
      due_in_ms = max(0, Map.get(retry, :due_at_ms, now_ms) - now_ms)
      retry_reason = StatusReason.for_retry(Map.get(retry, :error), due_in_ms)
      tracker_paused = tracker_paused?(issue)

      %{
        issue_id: issue_id,
        identifier: identifier,
        tracker_identity: retry_snapshot_tracker_identity(retry, issue),
        state: :paused,
        work_state: :retrying,
        tracker_state: Map.get(issue || %{}, :state),
        tracker_paused: tracker_paused,
        tag: State.issue_tag(issue),
        title: Map.get(issue || %{}, :title),
        url: Map.get(issue || %{}, :url),
        worker_host: Map.get(retry, :worker_host),
        workspace_path: Map.get(retry, :workspace_path),
        session_id: nil,
        live_conversation: nil,
        runtime_seconds: 0,
        queue_depth: idle_queue_depth(state, identifier),
        complexity: issue_complexity(issue),
        last_codex_timestamp: nil,
        last_codex_message: nil,
        last_codex_event: nil,
        error: Map.get(retry, :error),
        retry_attempt: Map.get(retry, :attempt),
        last_failure_at: Map.get(retry, :last_failure_at),
        retry_reason: retry_reason,
        waiting_reason: WaitingReason.for_retry(),
        pause_reason: if(tracker_paused, do: tracker_pause_cause(state)),
        blocked_by: known_blocked_by(issue),
        reason:
          if tracker_paused do
            StatusReason.for_paused_retry(
              tracker_pause_cause(state),
              Map.get(retry, :error),
              due_in_ms
            )
          else
            retry_reason
          end
      }
      |> WaitingReason.attach(state)
    end)
  end

  defp tracker_paused?(%Issue{} = issue), do: Issue.paused?(issue)
  defp tracker_paused?(issue) when is_map(issue), do: Map.get(issue, :paused) == true
  defp tracker_paused?(_issue), do: false

  # `Config.agent_max_dispatches_per_ticket/0` is a `WorkflowStore` GenServer
  # call that re-stats and re-reads the config file, so resolving it per idle
  # row turned one status render into one round-trip per backlog ticket, all
  # serialized inside this handle_call. That is why `status` and `agents` were
  # slow (and `alerts`, which never touches the orchestrator, was not) — #1684.
  # Read it once per snapshot.
  defp idle_statuses(%State{} = state, _running_by_identifier, prewarm_phase) do
    max_dispatches = Config.agent_max_dispatches_per_ticket()

    idle_issues =
      Enum.reject(visible_polled_issues(state), fn {issue_id, _issue} ->
        Map.has_key?(state.running, issue_id) or Map.has_key?(state.retry_attempts, issue_id)
      end)

    latch_statuses =
      Dispatcher.dispatch_latch_statuses(
        state,
        Enum.map(idle_issues, fn {issue_id, _issue} -> issue_id end)
      )

    Enum.map(idle_issues, fn {issue_id, issue} ->
      idle_status(
        state,
        issue,
        prewarm_phase,
        max_dispatches,
        Map.get(latch_statuses, issue_id, :none)
      )
    end)
  end

  defp idle_status(%State{} = state, issue, prewarm_phase, max_dispatches, latch_status) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, :id)
    {open_decision_count, open_decision_count_health} = open_decision_count(identifier)
    budget = get_in(state.dispatch_recovery, [:codex_thrash_budget, Map.get(issue, :id)]) || %{}
    prewarm_blocked? = prewarm_blocked?(prewarm_phase)

    work_state = idle_issue_work_state(issue)
    pause_reason = idle_issue_pause_reason(issue)
    release = Map.get(state.released_claims, Map.get(issue, :id))

    idle_evidence = idle_evidence(state, issue, latch_status, open_decision_count, System.monotonic_time(:millisecond))
    waiting_reason = idle_evidence_waiting_reason(idle_evidence, release)

    %{
      issue_id: Map.get(issue, :id),
      identifier: identifier,
      tracker_identity: Issue.tracker_identity(issue),
      state: if(work_state == :paused, do: :paused, else: :idle),
      work_state: work_state,
      tracker_state: Map.get(issue, :state),
      tracker_paused: Issue.paused?(issue),
      tag: State.issue_tag(issue),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      runtime_seconds: 0,
      queue_depth: idle_queue_depth(state, identifier),
      complexity: issue_complexity(issue),
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil,
      claim_released?: not is_nil(release),
      claim_release_cause: release && release.cause,
      reason:
        idle_reason(waiting_reason, identifier, fn ->
          idle_status_reason(
            work_state,
            pause_reason,
            prewarm_blocked?,
            budget,
            max_dispatches,
            latch_status,
            release && release.cause,
            idle_evidence.auto_resume_retry_in_ms
          )
        end),
      waiting_reason: waiting_reason,
      dispatch_latch: idle_evidence.dispatch_latch,
      auto_resume_retry_in_ms: idle_evidence.auto_resume_retry_in_ms,
      dispatch_hold_reason: idle_evidence.dispatch_hold_reason,
      capacity_hold_active?: idle_evidence.capacity_hold_active?,
      dispatch_decline_reason: Map.get(state.dispatch_declines, Map.get(issue, :id)),
      pause_reason: pause_reason,
      blocked_by: known_blocked_by(issue),
      open_decision_count: open_decision_count,
      open_decision_count_health: open_decision_count_health
    }
    |> WaitingReason.attach(state)
  end

  # A claim-shaped waiting reason IS the reason to show: the row has no live
  # agent and naming why beats re-deriving it from work state. Everything else
  # falls through to the ordinary reason ladder, which the caller passes as a
  # thunk so it is only computed when it is needed.
  @claim_shaped_waiting_reasons [:orphaned_claim, :stale_claim, :workspace_ownership_waiting]

  defp idle_reason(:workspace_ownership_waiting, identifier, _fallback) do
    case HoldStatus.for_ticket(identifier) do
      %{generation: generation, proof: proof} -> {:workspace_ownership_waiting, identifier, generation, proof}
      nil -> :workspace_ownership_waiting
    end
  end

  defp idle_reason(waiting_reason, _identifier, _fallback) when waiting_reason in @claim_shaped_waiting_reasons,
    do: waiting_reason

  defp idle_reason(_waiting_reason, _identifier, fallback), do: fallback.()

  @doc false
  @spec idle_evidence(State.t(), map(), term(), non_neg_integer(), integer()) :: map()
  def idle_evidence(%State{} = state, issue, latch_status, open_decision_count, now_ms) do
    auto_resume_retry_in_ms = AutoResume.retry_in_ms(state, Map.get(issue, :id), now_ms)
    dispatch_hold_reason = Map.get(state.dispatch_hold || %{}, :reason)
    capacity_hold_active? = capacity_hold_active?(state)

    %{
      dispatch_latch: latch_status,
      auto_resume_retry_in_ms: auto_resume_retry_in_ms,
      dispatch_hold_reason: dispatch_hold_reason,
      capacity_hold_active?: capacity_hold_active?,
      waiting_reason:
        WaitingReason.for_idle(
          Map.get(issue, :state),
          DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, DispatchPolicy.terminal_state_set()),
          open_decision_count,
          latched_lifetime: latch_status != :none,
          tracker_paused: Issue.paused?(issue),
          auto_resume_retry_in_ms: auto_resume_retry_in_ms,
          dispatch_hold_reason: dispatch_hold_reason,
          capacity_hold_active?: capacity_hold_active?,
          workspace_recovery?: WaitingReason.workspace_recovery?(state, Map.get(issue, :id), Map.get(issue, :identifier)),
          startup_reconciliation_complete?: state.startup_claim_reconciliation_complete?
        )
    }
  end

  # A released claim is the one idle signal that must win over every other
  # reason: ownership evaporated and the operator (or the automatic re-claim)
  # has to act. Prefer the claim-release classifier so the row never reads as a
  # plain awaiting-dispatch; the detailed cause and retry window stay in
  # `reason` (`StatusReason.render`) and `claim_release_cause`.
  @doc false
  @spec idle_evidence_waiting_reason(map(), map() | nil) :: atom()
  def idle_evidence_waiting_reason(_evidence, %{cause: cause}) when not is_nil(cause), do: :claim_released

  def idle_evidence_waiting_reason(%{waiting_reason: fallback}, _release), do: fallback

  defp idle_status_reason(
         _work_state,
         _pause_reason,
         _prewarm_blocked?,
         _budget,
         _max_dispatches,
         _latch_status,
         cause,
         retry_in_ms
       )
       when not is_nil(cause),
       do: StatusReason.for_claim_release(cause, retry_in_ms)

  defp idle_status_reason(
         _work_state,
         _pause_reason,
         _prewarm_blocked?,
         _budget,
         _max_dispatches,
         {:lifetime, lifetime, maximum},
         _cause,
         _retry_in_ms
       ),
       do: StatusReason.for_idle(false, :lifetime, lifetime, maximum)

  defp idle_status_reason(
         :paused,
         pause_reason,
         _prewarm_blocked?,
         _budget,
         _max_dispatches,
         :none,
         _cause,
         _retry_in_ms
       ),
       do: StatusReason.for_pause(pause_reason)

  defp idle_status_reason(
         _work_state,
         _pause_reason,
         prewarm_blocked?,
         budget,
         max_dispatches,
         :none,
         _cause,
         _retry_in_ms
       ) do
    StatusReason.for_idle(
      prewarm_blocked?,
      Map.get(budget, :tripped),
      Map.get(budget, :lifetime, 0),
      max_dispatches
    )
  end

  @doc false
  # A status projection must never wait behind a base build or crash while the
  # RepoBase process is restarting. Treat a timeout or process exit as an
  # unavailable snapshot; dispatch admission remains the authoritative gate.
  @spec prewarm_phase((timeout() -> term())) :: atom() | :unavailable
  def prewarm_phase(status_fun \\ &RepoBase.status/1) when is_function(status_fun, 1) do
    case status_fun.(@repo_base_status_timeout_ms) do
      {phase, _path} when is_atom(phase) -> phase
      _ -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  defp prewarm_blocked?(phase) when phase in [:cloning, :fetching, :building, :checking], do: true
  defp prewarm_blocked?(_phase), do: false

  defp idle_queue_depth(%State{} = state, identifier) when is_binary(identifier) do
    OM.queue_depth_for_issue(state, identifier)
  end

  defp idle_queue_depth(_state, _identifier), do: 0

  # A ticket with no running entry (idle or awaiting retry) carries no local
  # pause cause, so the tracker label is normally the whole story. A fleet-wide
  # pause is the one cause that is still knowable, and it explains the stall far
  # better than rendering every such row as an operator pause.
  defp tracker_pause_cause(%State{globally_paused: true}), do: :global_pause
  defp tracker_pause_cause(_state), do: :label_override
end
