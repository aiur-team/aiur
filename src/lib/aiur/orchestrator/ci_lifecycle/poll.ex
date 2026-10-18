defmodule Aiur.Orchestrator.CiLifecycle.Poll do
  @moduledoc """
  Fetches CI observations outside the orchestrator and applies them to current state.
  """

  alias Aiur.CIApprovalStore
  alias Aiur.Events.GithubCIPoller
  alias Aiur.GitHub.{CIPollBatch, Client, MergeQueue}
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Outcome
  alias Aiur.Orchestrator.CiLifecycle.ParkedReadyAlert
  alias Aiur.Orchestrator.CiLifecycle.ResultProjection
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.DraftAlertLifecycle
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.LifecycleFence
  alias Aiur.Orchestrator.RestackScheduler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerHealth
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.StartTrigger.ProgressStore
  require Logger

  @ci_wait_state "ci-wait"

  @human_review_state "human-review"

  @ci_poll_states [@ci_wait_state, @human_review_state]

  @doc false
  @spec launch_ci_poll(State.t(), term(), term(), term()) :: term()
  def launch_ci_poll(state, opts, continue, launch) do
    cache = issue_list_cache(state)
    generations = Map.new(state.running, fn {id, entry} -> {id, ci_generation(entry)} end)
    {baseline, invalidations} = {state.ci_lifecycle, Map.get(state.ci_lifecycle, :base_repair_invalidations, %{})}

    launch.(state, :ci_poll, fn -> fetch_ci_poll(cache, invalidations, opts) end, fn current, result ->
      current |> apply_ci_poll(result, generations, baseline, opts) |> continue.()
    end)
  end

  defp fetch_ci_poll(cache, invalidations, opts) do
    case fetch_ci_issues(cache, opts) do
      {:ok, issues, cache} ->
        issues_by_target = ci_issues_by_target(issues)
        targets = Map.keys(issues_by_target)
        poll_opts = Keyword.put(opts, :base_repair_invalidations, invalidations)
        poller = Keyword.get(opts, :ci_poller, &GithubCIPoller.poll/2)

        observation = observe_ci_targets(targets, issues_by_target, poll_opts, poller)

        {:ok, issues, cache, observation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp observe_ci_targets([], _issues_by_target, _poll_opts, _poller), do: :no_targets

  defp observe_ci_targets(targets, issues_by_target, poll_opts, poller) do
    started_at = System.monotonic_time(:millisecond)

    result =
      case put_ci_batch(poll_opts, targets, issues_by_target) do
        {:ok, poll_opts} -> poller.(targets, poll_opts)
        {:skip, _} -> :held
      end

    {started_at, result}
  end

  defp fetch_ci_issues(cache, opts) do
    case Keyword.fetch(opts, :ci_issue_fetcher) do
      {:ok, fetcher} ->
        case fetcher.(@ci_poll_states) do
          {:ok, issues} when is_list(issues) -> {:ok, issues, cache}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_ci_targets, other}}
        end

      :error ->
        Client.fetch_issues_by_states_conditional(@ci_poll_states, cache, opts)
    end
  end

  defp issue_list_cache(%State{ci_lifecycle: ci_lifecycle}) do
    ci_lifecycle |> Map.get(:poll_cache, %{}) |> Map.get(:issue_list_cache, %{})
  end

  defp put_issue_list_cache(%State{} = state, cache) do
    update_in(state.ci_lifecycle.poll_cache, &Map.put(&1 || %{}, :issue_list_cache, cache))
  end

  defp apply_ci_poll(state, {:ok, issues, cache, observation}, generations, baseline, opts) do
    state = if Keyword.has_key?(opts, :ci_issue_fetcher), do: state, else: put_issue_list_cache(state, cache)
    state = state |> prune_ci_lifecycle_state(issues, opts, baseline) |> IssueSync.observe_human_review_handoffs(issues)

    current_issues =
      Enum.filter(issues, fn issue ->
        Map.get(generations, issue.id) == ci_generation(Map.get(state.running, issue.id))
      end)

    issues_by_target = ci_issues_by_target(current_issues)

    case observation do
      :no_targets ->
        complete_no_target_poll(state)

      {started_at, :held} ->
        Logger.warning("GithubCIPoller held by local budget; retaining the normal poll cadence")
        state |> Map.put(:last_ci_poll_started_at_ms, started_at) |> clear_broker_retry_pending()

      {started_at, result} ->
        state = %{state | last_ci_poll_started_at_ms: started_at}
        apply_ci_observation(state, result, Map.keys(ci_issues_by_target(issues)), issues_by_target, opts)
    end
  end

  defp apply_ci_poll(state, {:error, reason}, _generations, _baseline, _opts) do
    state = schedule_ci_retry(state, reason, "target refresh")

    TrackerHealth.note_github_connectivity_failure(state, :ci, reason)
  end

  defp apply_ci_observation(state, {:ok, %{results: results, errors: errors}}, targets, issues_by_target, opts)
       when is_list(results) and is_list(errors) do
    state
    |> merge_journaled_base_repairs()
    |> note_ci_poll_connectivity(targets, errors)
    |> log_ci_poll_errors(errors)
    |> apply_ci_poll_results(results, issues_by_target, opts)
    |> RestackScheduler.reconcile(Map.values(issues_by_target))
    |> retry_ci_poll_on_errors(errors)
  end

  defp apply_ci_observation(state, {:error, reason}, _targets, _issues, _opts) do
    state = schedule_ci_retry(state, reason, "poll")

    TrackerHealth.note_github_connectivity_failure(state, :ci, reason)
  end

  defp apply_ci_observation(state, other, _targets, _issues, _opts) do
    Logger.warning("GithubCIPoller returned unexpected value=#{inspect(other)}")
    state
  end

  defp ci_generation(nil), do: nil
  defp ci_generation(entry), do: Map.take(entry, [:pid, :ref, :session_id, :control, :paused_reason])

  @doc false
  @spec run_ci_effect(State.t(), term(), term(), term(), term()) :: term()
  def run_ci_effect(state, issue, key, fetch, apply_result) do
    generation = ci_generation(Map.get(state.running, issue.id))

    TrackerTasks.run(state, {:ci, issue.id, key}, fetch, fn current, result ->
      if generation == ci_generation(Map.get(current.running, issue.id)) and
           (key in [:rewake_fetch, :terminal_fetch] or not LifecycleFence.handoff_blocked?(current, issue)) do
        apply_result.(current, result)
      else
        current
      end
    end)
  end

  defp put_ci_batch(opts, targets, issues_by_target) when is_list(opts) do
    if Keyword.has_key?(opts, :ci_poller), do: {:ok, opts}, else: put_ci_batch_fetch(opts, targets, issues_by_target)
  end

  defp put_ci_batch_fetch(opts, targets, issues_by_target) do
    fetcher = Keyword.get(opts, :ci_batch_fetcher, &CIPollBatch.fetch/2)

    opts =
      opts
      |> Keyword.put_new(:branch_names_by_target, ci_branch_names_by_target(issues_by_target))
      |> Keyword.put_new(:titles_by_target, ci_titles_by_target(issues_by_target))

    case fetcher.(targets, opts) do
      {:ok, batch} when is_map(batch) ->
        {:ok, Keyword.put(opts, :ci_batch, batch)}

      {:error, {:aiur, :locally_held, _hold} = reason} ->
        Logger.info("Github CI GraphQL batch locally held; skipping REST fallback reason=#{inspect(reason)}")
        {:skip, reason}

      {:error, reason} ->
        Logger.warning("Github CI GraphQL batch failed; falling back to REST reads reason=#{inspect(reason)}")
        {:ok, opts}

      other ->
        Logger.warning("Github CI GraphQL batch returned unexpected value; falling back to REST reads value=#{inspect(other)}")
        {:ok, opts}
    end
  end

  # GitHub issues have no branch name, so the batch derives the generated
  # `aiur/<id>-<slug>` branch from the title the same way TicketBranch does when
  # the branch is created.
  defp ci_titles_by_target(issues_by_target) do
    Enum.reduce(issues_by_target, %{}, fn
      {target, %Issue{title: title}}, acc when is_binary(title) and title != "" -> Map.put(acc, target, title)
      {_target, _issue}, acc -> acc
    end)
  end

  defp ci_branch_names_by_target(issues_by_target) do
    Enum.reduce(issues_by_target, %{}, fn
      {target, %Issue{branch_name: branch_name}}, acc when is_binary(branch_name) and branch_name != "" ->
        Map.put(acc, target, branch_name)

      {_target, _issue}, acc ->
        acc
    end)
  end

  defp ci_issues_by_target(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{} = issue, acc ->
        case CiLifecycle.ci_target_for_issue(issue) do
          nil -> acc
          target -> Map.put_new(acc, target, issue)
        end

      _other, acc ->
        acc
    end)
  end

  defp note_ci_poll_connectivity(state, targets, errors) do
    if errors == [] or not all_ci_targets_failed?(targets, errors) do
      TrackerHealth.note_github_connectivity_success(state, :ci)
    else
      TrackerHealth.note_github_connectivity_failure(state, :ci, List.first(errors))
    end
  end

  defp log_ci_poll_errors(state, []), do: state

  defp log_ci_poll_errors(state, errors) do
    Logger.warning("GithubCIPoller partial failures; reason=#{inspect(errors)}")
    state
  end

  defp retry_ci_poll_on_errors(state, []), do: clear_broker_retry_pending(state)

  defp retry_ci_poll_on_errors(state, errors) do
    if Enum.any?(errors, &broker_timeout_error?/1) do
      if Map.get(state.ci_lifecycle, :broker_fast_retry_pending?, false) do
        Logger.warning("GithubCIPoller broker timeout repeated after immediate retry; retaining the normal poll cadence")
        clear_broker_retry_pending(state)
      else
        Logger.warning("GithubCIPoller broker timeout; retrying the full target set once on the next orchestrator tick after #{length(errors)} target failure(s)")
        state |> Map.put(:last_ci_poll_started_at_ms, nil) |> put_broker_retry_pending(true)
      end
    else
      Logger.warning("GithubCIPoller partial failures; retaining the normal poll cadence count=#{length(errors)}")
      clear_broker_retry_pending(state)
    end
  end

  defp schedule_ci_retry(state, reason, stage) do
    if broker_timeout_error?(reason) do
      if Map.get(state.ci_lifecycle, :broker_fast_retry_pending?, false) do
        Logger.warning("GithubCIPoller #{stage} broker timeout repeated after immediate retry; retaining the normal poll cadence reason=#{inspect(reason)}")

        state
        |> ensure_ci_poll_timestamp()
        |> clear_broker_retry_pending()
      else
        Logger.warning("GithubCIPoller #{stage} broker timeout; retrying once on the next orchestrator tick reason=#{inspect(reason)}")
        state |> Map.put(:last_ci_poll_started_at_ms, nil) |> put_broker_retry_pending(true)
      end
    else
      Logger.warning("GithubCIPoller #{stage} failed; retaining the normal poll cadence reason=#{inspect(reason)}")

      state
      |> Map.put(:last_ci_poll_started_at_ms, System.monotonic_time(:millisecond))
      |> clear_broker_retry_pending()
    end
  end

  defp put_broker_retry_pending(state, pending?) do
    %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :broker_fast_retry_pending?, pending?)}
  end

  defp clear_broker_retry_pending(state), do: put_broker_retry_pending(state, false)

  defp complete_no_target_poll(state) do
    if Map.get(state.ci_lifecycle, :broker_fast_retry_pending?, false) do
      state
      |> Map.put(:last_ci_poll_started_at_ms, System.monotonic_time(:millisecond))
      |> clear_broker_retry_pending()
    else
      state
    end
  end

  defp ensure_ci_poll_timestamp(%{last_ci_poll_started_at_ms: nil} = state),
    do: %{state | last_ci_poll_started_at_ms: System.monotonic_time(:millisecond)}

  defp ensure_ci_poll_timestamp(state), do: state

  defp broker_timeout_error?(:github_budget_broker_timeout), do: true

  defp broker_timeout_error?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&broker_timeout_error?/1)

  defp broker_timeout_error?(term) when is_map(term),
    do: term |> Map.values() |> Enum.any?(&broker_timeout_error?/1)

  defp broker_timeout_error?(term) when is_list(term),
    do: Enum.any?(term, &broker_timeout_error?/1)

  defp broker_timeout_error?(_term), do: false

  defp apply_ci_poll_results(state, results, issues_by_target, opts) do
    Enum.reduce(results, state, fn result, state_acc ->
      apply_ci_poll_result_for_target(state_acc, result, issues_by_target, opts)
    end)
  end

  # Repair markers are journaled from concurrent poll tasks before GitHub is
  # mutated. Merge the durable ledger back into the GenServer snapshot before
  # any result transition can persist the lifecycle-wide document; otherwise
  # the first result could overwrite another task's already-durable marker.
  defp merge_journaled_base_repairs(%State{} = state) do
    persisted = CIApprovalStore.load()
    current = Map.get(state.ci_lifecycle, :base_repair_invalidations, %{})
    journaled = Map.get(persisted, :base_repair_invalidations, %{})
    merged = Map.merge(current, journaled)

    if merged == current do
      state
    else
      ci_lifecycle = Map.put(state.ci_lifecycle, :base_repair_invalidations, merged)
      %{state | ci_lifecycle: ci_lifecycle}
    end
  end

  defp apply_ci_poll_result_for_target(state, result, issues_by_target, opts) do
    case Map.get(issues_by_target, Map.get(result, :target)) do
      %Issue{} = issue ->
        if Map.get(result, :delivered) do
          # Webhook-displaced reads have no effects; held bodies never answer CI (R10).
          state
        else
          result = classify_merge_queue_departure(state, issue, result)
          ProgressStore.ci_identity(CiLifecycle.ci_target_for_issue(issue), result)

          state
          |> then(&DraftAlertLifecycle.reconcile(&1, issue, result, Transition.effective_ci_state(issue) == @ci_wait_state, opts))
          |> ParkedReadyAlert.reconcile_parked_ready_alert(issue, result, opts)
          |> ResultProjection.reconcile_base_repair_invalidation(issue, result)
          |> ResultProjection.publish_ready_for_review_transition(issue, result)
          |> ResultProjection.stash_last_ci_result(issue, result)
          |> Outcome.recover_ci_poll_result(issue, result, opts)
        end

      _ ->
        state
    end
  end

  defp classify_merge_queue_departure(state, issue, result) do
    target = CiLifecycle.ci_target_for_issue(issue)
    previous = get_in(state.ci_lifecycle, [:poll_cache, target])

    if MergeQueue.failed_entry_dropped?(result, previous) do
      Map.merge(result, %{decision: :failed, pending_reason: :merge_queue_dropped, failures: [%{name: "merge queue", kind: "merge_queue", result: "dropped after queue checks"}]})
    else
      result
    end
  end

  # ---- Parked-ready recovery alert ------------------------------------------
  #
  # A readied pull request that is approved, conflict-free, and still unarmed
  # will not re-enter the merge queue on its own (the recovery gap in #1737).
  # `mergeStateStatus: BLOCKED` on a freshly readied PR is not a merge conflict,
  # so the classifier keys eligibility on `mergeable` and deliberately ignores
  # the queue-status field. The daemon never arms auto-merge (the human-only
  # merge gate in #1841): it surfaces the parked state so the Executor can take
  # the documented explicit action (`aiur pr merge <n> --reviewed-sha <head>`).

  defp all_ci_targets_failed?([], _errors), do: false

  defp all_ci_targets_failed?(targets, errors) do
    failed_targets = errors |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    MapSet.subset?(MapSet.new(targets), failed_targets)
  end

  defp prune_ci_lifecycle_state(%State{} = state, issues, opts, baseline) do
    targets =
      issues
      |> Enum.map(&CiLifecycle.ci_target_for_issue/1)
      |> Enum.filter(&is_binary/1)

    approved_heads = prune_ci_map(state.ci_lifecycle.approved_heads, targets, baseline.approved_heads)
    passed_heads = state.ci_lifecycle |> Map.get(:passed_heads, %{}) |> prune_ci_map(targets, Map.get(baseline, :passed_heads, %{}))
    test_failure_heads = prune_ci_map(state.ci_lifecycle.test_failure_heads, targets, baseline.test_failure_heads)
    existing_poll_cache = Map.get(state.ci_lifecycle, :poll_cache, %{})

    poll_cache =
      existing_poll_cache
      |> prune_ci_map(targets, Map.get(baseline, :poll_cache, %{}))
      |> keep_shared_list_caches(existing_poll_cache)

    # Base repair invalidations intentionally survive while their ticket is in
    # rework (and therefore absent from this CI-only target list). The marker is
    # cleared only when that ticket returns with a new head or post-repair CI.

    state =
      state
      |> ParkedReadyAlert.ensure_parked_ready_alerts_seeded(opts)
      |> ParkedReadyAlert.resolve_departed_parked_ready_alerts(targets, opts)

    state = DraftAlertLifecycle.resolve_departed(state, targets, opts)

    if approved_heads == state.ci_lifecycle.approved_heads and
         passed_heads == Map.get(state.ci_lifecycle, :passed_heads, %{}) and
         test_failure_heads == state.ci_lifecycle.test_failure_heads and
         poll_cache == existing_poll_cache do
      state
    else
      ci_lifecycle =
        state.ci_lifecycle
        |> Map.put(:approved_heads, approved_heads)
        |> Map.put(:passed_heads, passed_heads)
        |> Map.put(:test_failure_heads, test_failure_heads)
        |> Map.put(:poll_cache, poll_cache)

      CiLifecycle.persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})
    end
  end

  # Only prune observations unchanged since this poll started.
  defp prune_ci_map(current, targets, baseline) do
    Enum.reduce(current, Map.take(current, targets), fn {key, value}, acc ->
      if Map.fetch(baseline, key) == {:ok, value}, do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp keep_shared_list_caches(poll_cache, existing_poll_cache) do
    Map.merge(
      poll_cache,
      Map.take(existing_poll_cache, [:issue_list_cache, :candidate_list_cache])
    )
  end
end
