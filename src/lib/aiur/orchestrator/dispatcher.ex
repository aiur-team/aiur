defmodule Aiur.Orchestrator.Dispatcher do
  @moduledoc """
  Dispatch entry: the poll cycle and the choose loop.
  Tracker work executes outside the owner; guarded results apply inside it.
  """

  alias Aiur.GitHub.CycleFetchCache
  alias Aiur.Issue
  alias Aiur.Orchestrator.AutoResume
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CommandScan
  alias Aiur.Orchestrator.CommentPolling
  alias Aiur.Orchestrator.DispatchBatch
  alias Aiur.Orchestrator.DispatchCandidates
  alias Aiur.Orchestrator.DispatchCycleCompletion
  alias Aiur.Orchestrator.DispatchCycleLiveness
  alias Aiur.Orchestrator.Dispatcher.Budgets
  alias Aiur.Orchestrator.Dispatcher.BudgetTrip
  alias Aiur.Orchestrator.Dispatcher.Candidates
  alias Aiur.Orchestrator.Dispatcher.Capacity
  alias Aiur.Orchestrator.Dispatcher.CiReadinessAdmission
  alias Aiur.Orchestrator.Dispatcher.HoldsAndAlerts
  alias Aiur.Orchestrator.Dispatcher.Launch
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.Lifecycle
  alias Aiur.Orchestrator.MergedTicketReconciler
  alias Aiur.Orchestrator.PausedCandidatePoll
  alias Aiur.Orchestrator.PollTiming
  alias Aiur.Orchestrator.PrAnchored
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.StartupClaimReconciler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.Orchestrator.TrackedSet
  alias Aiur.Orchestrator.TrackerHealth
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.RepoBase

  # Stable entry points; each responsibility lives under dispatcher/.
  @doc false
  defdelegate maybe_warn_ci_readiness(state), to: CiReadinessAdmission
  @doc false
  defdelegate start_initial_ci_readiness_check(state, kind, base_branch, check_fun), to: CiReadinessAdmission
  @doc false
  defdelegate handle_ci_readiness_result(state, token, result), to: CiReadinessAdmission
  @doc false
  defdelegate handle_ci_readiness_timeout(state, token), to: CiReadinessAdmission
  @doc false
  defdelegate check_initial_ci_readiness(state, kind, base_branch, check_fun, emit_fun), to: CiReadinessAdmission
  @doc false
  defdelegate refresh_blocked_ticket_ids(state), to: Candidates
  @doc false
  defdelegate refresh_blocked_ticket_ids(state, store), to: Candidates
  @doc false
  defdelegate fetch_candidate_issues(state), to: Candidates
  @doc false
  defdelegate fetch_candidate_issues(state, opts), to: Candidates
  @doc false
  defdelegate dispatch_or_hold(state, issues), to: HoldsAndAlerts
  @doc false
  defdelegate dispatch_or_hold(state, issues, trigger_fun), to: HoldsAndAlerts
  @doc false
  defdelegate dispatch_or_hold(state, issues, trigger_fun, opts), to: HoldsAndAlerts
  @doc false
  defdelegate maybe_emit_prewarm_blocked_alert(state, phase), to: HoldsAndAlerts
  @doc false
  defdelegate maybe_emit_prewarm_blocked_alert(state, phase, now_fun), to: HoldsAndAlerts
  @doc false
  defdelegate emit_prewarm_blocked_alert(state, phase), to: HoldsAndAlerts
  @doc false
  defdelegate clear_prewarm_blocked_alert(state), to: HoldsAndAlerts
  @doc false
  defdelegate clear_prewarm_blocked_alert(state, phase), to: HoldsAndAlerts
  @doc false
  defdelegate emit_tracker_preflight_alert(state, reason), to: HoldsAndAlerts
  @doc false
  defdelegate clear_tracker_preflight_alert(state), to: HoldsAndAlerts
  @doc false
  defdelegate maybe_choose_under_load(state, issues), to: Capacity
  @doc false
  defdelegate maybe_choose_under_load(state, issues, choose_fun), to: Capacity
  @doc false
  defdelegate maybe_choose_under_load(state, issues, choose_fun, opts), to: Capacity
  @doc false
  defdelegate auto_resume_admission(state), to: Capacity
  @doc false
  defdelegate dispatch_prevalidated_issue(state, issue), to: Launch
  @doc false
  defdelegate dispatch_with_dependency_gate(state, refreshed_issue, attempt, preferred_worker_host, opts), to: Candidates
  @doc false
  defdelegate default_blocked_by_hydrator(issue), to: Candidates
  @doc false
  defdelegate github_tracker_kind?(), to: Candidates
  @doc false
  defdelegate do_dispatch_issue(state, issue, attempt, preferred_worker_host), to: Launch
  @doc false
  defdelegate do_dispatch_issue(state, issue, attempt, preferred_worker_host, opts), to: Launch
  @doc false
  defdelegate redispatch_ready?(state, issue, preferred_worker_host), to: Budgets
  @doc false
  defdelegate redispatch_ready?(state, issue, preferred_worker_host, opts), to: Budgets
  @doc false
  defdelegate admit_redispatch(state, issue, preferred_worker_host), to: Budgets
  @doc false
  defdelegate admit_redispatch(state, issue, preferred_worker_host, opts), to: Budgets
  @doc false
  defdelegate check_thrash_budget(state, issue_id, now_ms), to: Budgets
  @doc false
  defdelegate record_dispatch_committed(state, issue_id), to: Budgets
  @doc false
  defdelegate reset_thrash_budget(state, issue_id), to: Budgets
  @doc false
  defdelegate reset_lifetime_budget(state, issue_id), to: Budgets
  @doc false
  defdelegate dispatch_latch_status(state, issue_id), to: Budgets
  @doc false
  defdelegate dispatch_latch_statuses(state, issue_ids), to: Budgets
  @doc false
  defdelegate revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states), to: Launch
  @doc false
  defdelegate revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states, opts), to: Launch
  @doc false
  defdelegate retry_dispatch_ready?(issue, state, worker_host), to: Launch
  @doc false
  defdelegate log_prewarm_hold(state, phase), to: HoldsAndAlerts
  @doc false
  defdelegate log_prewarm_hold(state, phase, log_fun), to: HoldsAndAlerts
  @doc false
  defdelegate persist_lifetime_trip(state, issue, update_state_fun), to: BudgetTrip
  @doc false
  defdelegate handle_pending_answer_delivery(message), to: Launch

  @spec run_poll_cycle(State.t()) :: {:noreply, State.t()}
  def run_poll_cycle(%State{} = state) do
    if TrackerTasks.running?(state, :startup_workspace_cleanup),
      do: {:noreply, Lifecycle.schedule_tick(state, 100)},
      else: state |> DispatchCycleLiveness.start() |> continue_poll_cycle()
  end

  defp continue_poll_cycle(state) do
    if dispatch_chain_pending?(state) or dispatch_poll_running?(state) do
      {:noreply, Lifecycle.schedule_tick(state, 100)}
    else
      start_and_watch_poll_cycle(state)
    end
  end

  defp start_and_watch_poll_cycle(state) do
    case start_poll_cycle(state) do
      {:noreply, next} = result ->
        if dispatch_poll_running?(next),
          do: {:noreply, Lifecycle.schedule_tick(next, 100)},
          else: result
    end
  end

  defp dispatch_poll_running?(state),
    do: TrackerTasks.running?(state, :dispatch_poll) or TrackerTasks.running?(state, :ci_poll)

  defp start_poll_cycle(state) do
    cond do
      dispatch_chain_pending?(state) ->
        {:noreply, Lifecycle.schedule_tick(state, 100)}

      TrackerTasks.running?(state, :dispatch_poll) or TrackerTasks.running?(state, :ci_poll) ->
        {:noreply, state}

      true ->
        state = Lifecycle.refresh_runtime_config(state)
        state = Reconciler.reconcile_running_lifecycle(state)

        {:noreply,
         TrackerTasks.start(state, :dispatch_poll, &TrackerHealth.tracker_preflight/0, fn current, result ->
           case result do
             :ok -> current |> HoldsAndAlerts.clear_tracker_preflight_alert() |> start_poll_reads()
             {:error, reason} -> current |> HoldsAndAlerts.emit_tracker_preflight_alert(reason) |> finish_poll_cycle()
           end
         end)}
    end
  end

  defp dispatch_chain_pending?(state) do
    Enum.any?(state.tracker_tasks, fn
      {_ref, %{key: {:dispatch, _id}}} -> true
      _ -> false
    end)
  end

  @doc false
  @spec finish_poll_cycle(State.t()) :: State.t()
  defdelegate finish_poll_cycle(state), to: DispatchCycleCompletion, as: :finish

  defp start_poll_reads(state) do
    state
    |> CiReadinessAdmission.maybe_warn_ci_readiness()
    |> TrackedSet.refresh()
    |> CommentPolling.start_firehose(&after_firehose/1, &TrackerTasks.start/4)
  end

  defp after_firehose(state) do
    state
    |> CommentPolling.start_async()
    |> CiLifecycle.start_poll(fn current ->
      current |> Candidates.refresh_blocked_ticket_ids() |> start_candidate_poll(&Candidates.default_candidate_fetch/1)
    end)
  end

  @doc false
  @spec start_candidate_poll(State.t(), (map() -> term())) :: State.t()
  def start_candidate_poll(%State{globally_paused: true} = state, fetch_fun),
    do: PausedCandidatePoll.start(state, fetch_fun, &Candidates.note_candidate_fetch_success/2, &Candidates.mark_candidate_snapshot_unavailable/2, &monitor_without_candidates/1, &finish_poll_cycle/1)

  def start_candidate_poll(%State{} = state, fetch_fun) do
    cache = Candidates.candidate_list_cache(state)

    TrackerTasks.start(state, :dispatch_poll, fn -> fetch_fun.(cache) end, fn current, result ->
      current
      |> dispatch_candidate_poll(fetch_candidate_issues_fun: &Candidates.apply_candidate_result(&1, result))
      |> PollTiming.complete(result)
      |> finish_poll_cycle()
    end)
  end

  @spec maybe_dispatch(State.t()) :: State.t()
  def maybe_dispatch(%State{} = state) do
    CycleFetchCache.start_cycle()

    try do
      maybe_dispatch(state, &do_maybe_dispatch/1)
    after
      CycleFetchCache.end_cycle()
    end
  end

  @doc false
  @spec maybe_dispatch(State.t(), (State.t() -> State.t())) :: State.t()
  def maybe_dispatch(%State{} = state, dispatch_fun) when is_function(dispatch_fun, 1) do
    maybe_dispatch(state, dispatch_fun, &TrackerHealth.ensure_tracker_preflight/1)
  end

  @doc false
  @spec maybe_dispatch(
          State.t(),
          (State.t() -> State.t()),
          (State.t() -> {:ok, State.t()} | {:error, term(), State.t()})
        ) :: State.t()
  def maybe_dispatch(%State{} = state, dispatch_fun, preflight_fun)
      when is_function(dispatch_fun, 1) and is_function(preflight_fun, 1) do
    state = Reconciler.reconcile_running_lifecycle(state)

    case preflight_fun.(state) do
      {:ok, state} ->
        state
        |> HoldsAndAlerts.clear_tracker_preflight_alert()
        |> dispatch_fun.()

      {:error, reason, state} ->
        HoldsAndAlerts.emit_tracker_preflight_alert(state, reason)
    end
  end

  defp do_maybe_dispatch(%State{} = state) do
    state |> prepare_candidate_poll() |> dispatch_candidate_poll()
  end

  defp prepare_candidate_poll(%State{} = state) do
    state = CiReadinessAdmission.maybe_warn_ci_readiness(state)
    state = TrackedSet.refresh(state)
    state = CommentPolling.poll_github_firehose(state)
    # Issued, not awaited: the Orchestrator was captured parked in this poll's
    # `Task.async_stream` fan-out with 5,729 messages behind it on an idle host
    # (#1837). The answer arrives as `{:github_comments_polled, ...}`.
    state = CommentPolling.start_async(state)
    state = CiLifecycle.poll_github_ci(state)
    # Reconciliation needs current holds before stopping blocked workers;
    # admission refreshes again after tracker work because answers can arrive during the poll.
    state = Candidates.refresh_blocked_ticket_ids(state)

    state
  end

  @doc false
  @spec dispatch_candidate_poll(State.t(), keyword()) :: State.t()
  def dispatch_candidate_poll(%State{} = state, opts \\ []) when is_list(opts) do
    fetch_candidates = Keyword.get(opts, :fetch_candidate_issues_fun, &Candidates.fetch_candidate_issues/1)
    monitor_without_candidates = Keyword.get(opts, :monitor_without_candidates_fun, &monitor_without_candidates/1)
    stranded_reconciliation = Keyword.get(opts, :stranded_reconciliation_fun, &IssueSync.sync_stranded_ticket_reconciliation/2)

    case fetch_candidates.(state) do
      {:paused, state} ->
        monitor_without_candidates.(state)

      {:ok, issues, state} ->
        {state, issues} = reconcile_merged_tickets(state, issues)

        # Heal any polled ticket that transiently carries two `agent:*` state
        # labels (a broken lifecycle state from a writer stamping `rework`
        # without a review verdict, #2075) before anything consumes the list:
        # the dispatch guard no longer silently drops the pair, and this rewrite
        # makes GitHub stop carrying it so the ticket stays dispatchable.
        {state, issues} = IssueSync.reconcile_contradictory_state_labels(state, issues)

        # Reconciliation runs against the snapshot this poll just revalidated,
        # so a ticket relabelled since the previous poll is judged on its
        # current labels rather than a stale cached copy (#1682).
        state = Reconciler.refresh_running_issue_states(state, issues)
        # Tracker claims survive a daemon restart, while the runtime registry
        # does not. Once both views are fresh, release only claims with no
        # positive current-generation runtime evidence before normal dispatch.
        {state, issues} = StartupClaimReconciler.reconcile(state, issues, Keyword.get(opts, :startup_claim_opts, []))
        state = CommandScan.scan_pr_commands(state)
        state = PrAnchored.maybe_stop_closed_pr_anchored_agents(state)

        state =
          state
          |> IssueSync.sync_polled_issue_state(issues)
          |> IssueSync.sync_todo_capacity_alert(issues)

        state = %{state | snapshot_ready?: true}

        # Publish all rows, including claims still within the recovery grace period.
        StatusReport.notify_dashboard(state)
        issues = StartupClaimReconciler.Observation.dispatch_candidates(state, issues)

        # Re-dispatch tickets parked on a transient pause/error whose backoff
        # has elapsed (#1453). Runs before normal dispatch so a restored ticket
        # is claimed and won't double-dispatch below.
        state = AutoResume.maybe_resume(state, System.monotonic_time(:millisecond))

        state =
          state
          |> HoldsAndAlerts.dispatch_or_hold(issues)
          |> IssueSync.sync_dependency_circular_wait_alert(issues)
          |> IssueSync.sync_capacity_starvation_alert(issues)
          |> IssueSync.sync_fleet_capacity_starved_alert(issues)
          |> IssueSync.sync_decision_store_unavailable_alert(issues)
          # After dispatch has had its chance to claim every eligible ticket,
          # re-queue open non-terminal tickets that still have no live owner and
          # no scheduled claim (a released claim with no recovery, or a
          # degenerate zero-label ticket) so a strand never sits unowned and
          # invisible to the label checks (#2361, #2420).
          |> stranded_reconciliation.(issues)

        %{state | initial_dispatch_cycle: false}

      {:error, reason, state} ->
        state = monitor_without_candidates.(state)
        TrackerHealth.log_tracker_fetch_error(reason)
        state
    end
  end

  @doc false
  @spec monitor_without_candidates(State.t(), keyword()) :: State.t()
  def monitor_without_candidates(%State{} = state, opts \\ []) when is_list(opts) do
    refresh_running = Keyword.get(opts, :refresh_running_fun, &Reconciler.refresh_running_issue_states/1)
    scan_commands = Keyword.get(opts, :scan_commands_fun, &CommandScan.scan_pr_commands/1)
    stop_closed_pr_agents = Keyword.get(opts, :stop_closed_pr_agents_fun, &PrAnchored.maybe_stop_closed_pr_anchored_agents/1)
    notify_dashboard = Keyword.get(opts, :notify_dashboard_fun, &StatusReport.notify_dashboard/1)

    state = refresh_running.(state)
    state = scan_commands.(state)
    state = stop_closed_pr_agents.(state)
    _ = notify_dashboard.(state)
    state
  end

  # Runs before anything else consumes the polled candidates: a ticket already
  # closed by a merged pull request must not be state-synced, counted towards
  # capacity, or dispatched as though it were still open. The returned list is
  # the candidates that survived reconciliation.
  @doc false
  @spec reconcile_merged_tickets(State.t(), [Issue.t()], keyword()) :: {State.t(), [Issue.t()]}
  def reconcile_merged_tickets(%State{} = state, issues, opts \\ []) when is_list(issues) and is_list(opts) do
    MergedTicketReconciler.reconcile(state, issues, opts)
  end

  @spec choose_issues(State.t(), [Issue.t()], keyword()) :: State.t()
  def choose_issues(state, issues, opts \\ []) when is_list(opts) do
    active_states = DispatchPolicy.active_state_set()
    terminal_states = DispatchPolicy.terminal_state_set()
    initial_dispatch_cycle? = state.initial_dispatch_cycle == true
    visible_issue_ids = MapSet.new(issues, & &1.id)
    state = %{state | dispatch_declines: Map.take(state.dispatch_declines, MapSet.to_list(visible_issue_ids))}

    {candidates, held} =
      DispatchCandidates.partition(issues, terminal_states, Map.values(state.last_polled_issues))

    state = Candidates.hold_cached_dependencies(state, held, active_states, terminal_states)
    choose_issues_in_order(state, candidates, opts, active_states, terminal_states, initial_dispatch_cycle?, 0)
  end

  defp choose_issues_in_order(%State{globally_paused: true} = state, _issues, opts, _active, _terminal, _initial, _index),
    do: DispatchBatch.finish(state, opts, nil)

  defp choose_issues_in_order(state, [], opts, _active, _terminal, _initial, _index), do: DispatchBatch.finish(state, opts, nil)

  defp choose_issues_in_order(state, [issue | rest] = remaining, opts, active, terminal, initial, index) do
    DispatchBatch.advance(state, remaining, opts, fn -> choose_ready_issue(state, issue, rest, opts, active, terminal, initial, index) end, fn current, resume_opts ->
      choose_issues_in_order(current, remaining, resume_opts, active, terminal, initial, index)
    end)
  end

  defp choose_ready_issue(state, issue, rest, opts, active, terminal, initial, index) do
    {state, decision} = Launch.recover_orphaned_claim(state, issue, active, terminal)

    case decision do
      :dispatch ->
        was_claimed? = MapSet.member?(state.claimed, issue.id)

        completion = fn current ->
          next_index = maybe_schedule_startup_todo_alert(was_claimed?, current, issue, index, initial)
          choose_issues_in_order(current, rest, opts, active, terminal, initial, next_index)
        end

        dispatch_issue(state, issue, nil, nil, Keyword.put(opts, :dispatch_result_fun, completion))

      {:skip, reason} ->
        state |> Candidates.maybe_emit_dispatch_decline(issue, reason) |> choose_issues_in_order(rest, opts, active, terminal, initial, index)
    end
  end

  @spec dispatch_issue(State.t(), term(), term(), term()) :: State.t()
  def dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    dispatch_issue(state, issue, attempt, preferred_worker_host, [])
  end

  @doc false
  @spec dispatch_issue(State.t(), term(), term(), term(), keyword()) :: State.t()
  def dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, opts)
      when is_list(opts) do
    Candidates.start_dispatch_validation(state, issue, attempt, preferred_worker_host, opts)
  end

  @doc false
  @spec trigger_and_status() :: term()
  def trigger_and_status do
    RepoBase.refresh_for_dispatch()
  end

  @doc false
  @spec maybe_choose(State.t(), [Issue.t()]) :: State.t()
  def maybe_choose(state, issues), do: maybe_choose(state, issues, [])

  @doc false
  @spec maybe_choose(State.t(), [Issue.t()], keyword()) :: State.t()
  def maybe_choose(state, issues, opts) do
    if Slots.available_slots(state) > 0, do: choose_issues(state, issues, opts), else: DispatchBatch.finish(state, opts, nil)
  end

  defp maybe_schedule_startup_todo_alert(
         was_claimed?,
         next_state,
         %Issue{} = issue,
         index,
         true
       ) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "todo" and
         not was_claimed? and
         MapSet.member?(next_state.claimed, issue.id) do
      delay_ms = index * 1_000
      worker_host = State.WorkerHost.running_worker_host(next_state, issue.id)
      topic = "ticket.#{issue.identifier}.issue.label.added.agent.todo"
      Process.send_after(self(), {:emit_system_alert, topic, issue, worker_host}, delay_ms)
      index + 1
    else
      index
    end
  end

  defp maybe_schedule_startup_todo_alert(
         _was_claimed?,
         _next_state,
         _issue,
         index,
         _initial_dispatch_cycle?
       ),
       do: index
end
