defmodule Aiur.Orchestrator.Reconciler do
  @moduledoc """
  Per-poll reconciliation of running entries against refreshed tracker states.
  Tracker reads run in tasks; their results reconcile the current runtime.
  """

  require Logger

  alias Aiur.{CurrentRunMembership, Issue, Orchestrator, Tracker, TrackerIdentity}
  alias Aiur.Orchestrator.Reconciler.{Divergence, Nonterminal, Reactivation}

  alias Aiur.Orchestrator.{LifecycleFenceExpiry, PushRouting, RuntimeWatchdog}

  alias Aiur.Orchestrator.{
    DispatchPolicy,
    LifecycleFence,
    MembershipLifecycle,
    RateLimitFallback,
    State,
    TrackerTasks
  }

  @spec reconcile_running_lifecycle(State.t()) :: State.t()
  def reconcile_running_lifecycle(%State{} = state) do
    state = state |> LifecycleFenceExpiry.reconcile() |> RuntimeWatchdog.reconcile_runtime_health()
    state = RuntimeWatchdog.reconcile_stalled_running_issues(state)
    state = RuntimeWatchdog.reconcile_overrunning_agents(state)
    state = PushRouting.reconcile_pending_auto_resumes(state)
    RateLimitFallback.reconcile(state)
  end

  # Two independent read-reduction strategies meet on this path (#1674):
  #
  #   1. Reuse. The poll has already fetched the candidate list, so a running
  #      ticket visible in that snapshot needs no request at all.
  #   2. Revalidation. Whatever is left — running tickets absent from the
  #      candidate snapshot — is fetched with `If-None-Match`, so an unchanged
  #      ticket costs a 304 (free against the GitHub rate limit) instead of a
  #      full read.
  #
  # They compose: reuse eliminates requests, revalidation makes the
  # irreducible remainder cheap. The ETag/issue pairs live in
  # `State.running_issue_cache`, threaded through `fetch_fun`.
  #
  # `fetch_fun` is deliberately arity-polymorphic rather than a second
  # `is_list/1`-guarded arity-2 clause: an arity-1 fun is the legacy
  # cache-free contract, an arity-2 fun is the conditional one. The arity is
  # what distinguishes them, so no two clauses can shadow each other.
  @typedoc false
  @type fetch_fun ::
          ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()})
          | ([String.t()], map() ->
               {:ok, [Issue.t()], map()} | {:error, term()} | {:error, term(), map()})

  @spec refresh_running_issue_states(State.t()) :: State.t()
  def refresh_running_issue_states(%State{} = state) do
    running_ids = Map.keys(state.running)
    refresh_running_issue_ids(state, running_ids, "running", default_fetch_fun())
  end

  @spec refresh_running_issue_states(State.t(), [Issue.t()]) :: State.t()
  def refresh_running_issue_states(%State{} = state, candidate_issues)
      when is_list(candidate_issues) do
    refresh_running_issue_states(state, candidate_issues, default_fetch_fun())
  end

  @doc false
  @spec refresh_running_issue_states(State.t(), [Issue.t()], fetch_fun()) :: State.t()
  def refresh_running_issue_states(%State{} = state, candidate_issues, fetch_fun)
      when is_list(candidate_issues) and (is_function(fetch_fun, 1) or is_function(fetch_fun, 2)) do
    running_ids = Map.keys(state.running)
    running_id_set = MapSet.new(running_ids)

    visible_running_issues =
      Enum.filter(candidate_issues, fn
        %Issue{id: issue_id} -> MapSet.member?(running_id_set, issue_id)
        _ -> false
      end)

    visible_running_ids = MapSet.new(visible_running_issues, & &1.id)
    missing_ids = Enum.reject(running_ids, &MapSet.member?(visible_running_ids, &1))

    state = reconcile_running_issue_states(visible_running_issues, state)
    refresh_running_issue_ids(state, missing_ids, "missing running", fetch_fun)
  end

  defp default_fetch_fun, do: &Tracker.fetch_issue_states_by_ids_conditional/2

  # Nothing to fetch: every running ticket was served from the polled
  # snapshot. Still drop cache entries for tickets that stopped running, so
  # the cache cannot outgrow `state.running`.
  defp refresh_running_issue_ids(state, [], _context, _fetch_fun), do: prune_running_issue_cache(state)

  defp refresh_running_issue_ids(state, issue_ids, context, fetch_fun) do
    inputs = Map.new(issue_ids, &{&1, issue_input(state, &1)})
    cache = state.running_issue_cache

    TrackerTasks.run(state, :running_issue_refresh, fn -> apply_fetch_fun(fetch_fun, issue_ids, cache) end, fn current, result ->
      eligible_ids = Enum.filter(issue_ids, &(issue_input(current, &1) == inputs[&1]))
      apply_running_refresh(current, eligible_ids, context, result)
    end)
  end

  @doc false
  @spec issue_input(State.t(), String.t()) :: tuple()
  def issue_input(state, issue_id) do
    entry = Map.get(state.running, issue_id)
    runtime = if is_map(entry), do: Map.take(entry, [:pid, :ref, :control, :lifecycle_fence, :issue]), else: entry
    {runtime, Map.get(state.last_polled_issues, issue_id), Map.get(state.retry_attempts, issue_id), MapSet.member?(state.claimed, issue_id)}
  end

  defp apply_running_refresh(state, issue_ids, context, result) do
    case result do
      {:ok, issues, cache} ->
        issues = Enum.filter(issues, &(&1.id in issue_ids))

        state
        |> merge_running_issue_cache(cache, issue_ids)
        |> reconcile_refreshed_running_issues(issues)
        |> reconcile_missing_running_issue_ids(issue_ids, issues)
        |> prune_running_issue_cache()

      # Conditional fetchers surface the cache even on failure: ETags learned
      # before the error are still valid, and discarding them would force a
      # full re-read of every running ticket on the next poll.
      {:error, reason, cache} ->
        log_refresh_failure(state, issue_ids, context, reason)

        state
        |> merge_running_issue_cache(cache, issue_ids)
        |> prune_running_issue_cache()

      {:error, reason} ->
        log_refresh_failure(state, issue_ids, context, reason)
        state
    end
  end

  # An arity-1 `fetch_fun` is the cache-free contract; normalize its reply to
  # the three-element shape with `nil` standing for "cache untouched".
  defp apply_fetch_fun(fetch_fun, issue_ids, _cache) when is_function(fetch_fun, 1) do
    case fetch_fun.(issue_ids) do
      {:ok, issues} -> {:ok, issues, nil}
      other -> other
    end
  end

  defp apply_fetch_fun(fetch_fun, issue_ids, cache) when is_function(fetch_fun, 2) do
    fetch_fun.(issue_ids, cache)
  end

  defp reconcile_refreshed_running_issues(state, issues) do
    reconcile_running_issue_states(
      issues,
      state,
      DispatchPolicy.active_state_set(),
      DispatchPolicy.terminal_state_set()
    )
  end

  defp merge_running_issue_cache(state, nil, _issue_ids), do: state

  defp merge_running_issue_cache(state, cache, issue_ids) when is_map(cache),
    do: %{state | running_issue_cache: Map.merge(state.running_issue_cache, Map.take(cache, issue_ids))}

  defp prune_running_issue_cache(%State{running_issue_cache: cache} = state) when map_size(cache) == 0, do: state

  defp prune_running_issue_cache(%State{} = state) do
    %{state | running_issue_cache: Map.take(state.running_issue_cache, Map.keys(state.running))}
  end

  defp log_refresh_failure(state, issue_ids, context, reason) do
    issue_context = refresh_issue_context(state, issue_ids)

    Logger.debug("Failed to refresh #{context} issue states for #{inspect(issue_context)}: #{inspect(reason)}; keeping active workers")
  end

  defp refresh_issue_context(state, issue_ids) do
    Enum.map(issue_ids, fn issue_id ->
      {issue_id, get_in(state.running, [issue_id, :identifier])}
    end)
  end

  @spec reconcile_running_issue_states([Issue.t()], State.t()) :: State.t()
  def reconcile_running_issue_states(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(
      issues,
      state,
      DispatchPolicy.active_state_set(),
      DispatchPolicy.terminal_state_set()
    )
  end

  @spec reconcile_running_issue_states([Issue.t()], State.t(), MapSet.t(), MapSet.t()) ::
          State.t()
  def reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  def reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  @spec reconcile_issue_state(Issue.t() | term(), State.t(), MapSet.t(), MapSet.t()) :: State.t()
  def reconcile_issue_state(issue, state, active_states, terminal_states) do
    reconcile_issue_state(
      issue,
      state,
      active_states,
      terminal_states,
      &MembershipLifecycle.observe/2,
      &CurrentRunMembership.mark_reconciled/1
    )
  end

  @doc false
  @spec reconcile_issue_state(
          Issue.t() | term(),
          State.t(),
          MapSet.t(),
          MapSet.t(),
          (TrackerIdentity.t(), atom() -> term())
        ) :: State.t()
  def reconcile_issue_state(
        %Issue{} = issue,
        state,
        active_states,
        terminal_states,
        observe_membership_fun
      )
      when is_function(observe_membership_fun, 2) do
    reconcile_issue_state(
      issue,
      state,
      active_states,
      terminal_states,
      observe_membership_fun,
      &CurrentRunMembership.mark_reconciled/1
    )
  end

  def reconcile_issue_state(
        _issue,
        state,
        _active_states,
        _terminal_states,
        _observe_membership_fun
      ),
      do: state

  @doc false
  @spec reconcile_issue_state(
          Issue.t() | term(),
          State.t(),
          MapSet.t(),
          MapSet.t(),
          (TrackerIdentity.t(), atom() -> term()),
          (:fresh | :unavailable -> term())
        ) :: State.t()
  def reconcile_issue_state(
        %Issue{} = issue,
        state,
        active_states,
        terminal_states,
        observe_membership_fun,
        mark_reconciled_fun
      )
      when is_function(observe_membership_fun, 2) and is_function(mark_reconciled_fun, 1) do
    if DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) do
      case LifecycleFence.reconcile_observed_state(state, issue, terminal_states) do
        :admit ->
          # Resolve any open divergence attention before the entry is removed,
          # so a terminal ticket never leaves a stuck alert behind. A fenced
          # issue is still running, so its divergence state is left intact.
          state
          |> Divergence.clear_reported_divergence(issue.id, issue.identifier)
          |> Nonterminal.reconcile_terminal_issue_state(
            issue,
            observe_membership_fun,
            mark_reconciled_fun
          )

        {:fenced, next_state} ->
          next_state
      end
    else
      state
      |> report_label_divergence(issue)
      |> Nonterminal.reconcile_nonterminal_issue_state(
        issue,
        active_states,
        terminal_states,
        observe_membership_fun
      )
    end
  end

  def reconcile_issue_state(
        _issue,
        state,
        _active_states,
        _terminal_states,
        _observe_membership_fun,
        _mark_reconciled_fun
      ),
      do: state

  @doc false
  @spec report_label_divergence(State.t(), Issue.t()) :: State.t()
  def report_label_divergence(%State{} = state, %Issue{} = issue) do
    Divergence.report_label_divergence(state, issue)
  end

  @doc false
  @spec resolve_orphaned_divergence_attentions(State.t()) :: State.t()
  def resolve_orphaned_divergence_attentions(%State{} = state) do
    Divergence.resolve_orphaned_divergence_attentions(state)
  end

  @spec maybe_reactivate_or_refresh(State.t(), Issue.t()) :: State.t()
  def maybe_reactivate_or_refresh(%State{} = state, %Issue{} = issue) do
    Reactivation.maybe_reactivate_or_refresh(state, issue)
  end

  @spec reconcile_missing_running_issue_ids(State.t(), [String.t()], [Issue.t() | term()]) ::
          State.t()
  def reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
      when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)

        state_acc
        |> Divergence.clear_reported_divergence(issue_id)
        |> Orchestrator.terminate_running_issue(issue_id, false)
      end
    end)
  end

  def reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  @spec refresh_running_issue_state(State.t(), Issue.t()) :: State.t()
  def refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    Reactivation.refresh_running_issue_state(state, issue)
  end

  @spec refresh_running_entry_issue(State.t(), Issue.t(), map()) :: State.t()
  def refresh_running_entry_issue(%State{} = state, %Issue{} = issue, running_entry)
      when is_map(running_entry) do
    Reactivation.refresh_running_entry_issue(state, issue, running_entry)
  end

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info([
          "Issue no longer visible during running-state refresh: issue_id=",
          issue_id,
          " issue_identifier=",
          inspect(identifier),
          "; stopping active agent"
        ])

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok
end
