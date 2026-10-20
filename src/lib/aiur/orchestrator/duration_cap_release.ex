defmodule Aiur.Orchestrator.DurationCapRelease do
  @moduledoc """
  Hands a ticket whose worker parked at `agent.max_agent_duration_minutes` to
  a fresh worker (#4849): moves it with the startup reconciler's mapping (draft
  or no PR -> rework, ready PR -> human-review unless the PR needs rework), then
  frees the runner entry so it no longer holds a slot or blocks dispatch.
  """

  require Logger

  alias Aiur.AgentRunner.TurnProgress
  alias Aiur.Alerts
  alias Aiur.CodeHost
  alias Aiur.Config
  alias Aiur.GitHub.Client
  alias Aiur.Orchestrator.{AgentTeardown, Dispatcher, DispatchPolicy, ReworkGate, State, TrackerTasks}
  alias Aiur.Orchestrator.{Dispatcher.Budgets, DurationCapRetryStore}
  alias Aiur.Orchestrator.StartupClaimReconciler.Release

  @spec maybe_release(State.t(), map(), atom(), keyword()) :: State.t()
  def maybe_release(state, running_entry, status, opts \\ [])

  def maybe_release(%State{} = state, %{paused_reason: :max_agent_duration, issue: %{id: issue_id} = issue} = entry, :paused, opts) do
    opts = Keyword.merge(Application.get_env(:aiur, :duration_cap_release_opts, []), opts)
    release = fn -> release_decision(state, issue, entry, opts) end
    TrackerTasks.run(state, {:duration_cap_release, issue_id}, release, &apply_release(&1, &2, entry, opts))
  end

  def maybe_release(state, _running_entry, _status, _opts), do: state

  defp release_decision(state, issue, entry, opts) do
    {baseline, entry} = baseline(entry, opts)
    entry = Map.put(entry, :dispatch_latch_status, Budgets.dispatch_latch_status(state, issue.id))
    progress = progress?(entry, baseline, opts)

    classify_release(issue, entry, progress, opts)
    |> execute_release(issue, opts)
  end

  defp classify_release(issue, entry, true, opts) do
    if DispatchPolicy.active_issue_state?(issue.state, DispatchPolicy.active_state_set()) and retry_budget_available?(entry, opts) do
      case progress_release_target(issue, opts) do
        {:ok, "rework"} -> {:redispatch, %{issue | state: "rework"}}
        {:ok, target} -> {:release, target, "progress was detected"}
        {:error, _} = error -> error
      end
    else
      {:escalate, release_reason(true, issue, entry, opts)}
    end
  end

  defp classify_release(issue, entry, false, opts), do: {:escalate, release_reason(false, issue, entry, opts)}

  defp execute_release({:release, target, reason}, issue, opts) do
    Release.run(issue, release_opts(opts, reason, forced_target: target))
  end

  defp execute_release(decision, _issue, _opts), do: decision

  defp release_opts(opts, reason, extra) do
    Keyword.merge(
      [
        no_pr_target: "rework",
        writer: :duration_cap_release,
        # This daemon owns the parked worker's lease; it is released right after the write.
        ownership_fun: fn _identifier -> :none end,
        release_body: &"Agent reached `agent.max_agent_duration_minutes`; #{reason}; moved this ticket to #{&1}."
      ],
      opts
    )
    |> Keyword.merge(extra)
  end

  defp progress_release_target(issue, opts) do
    case Keyword.fetch(opts, :progress_release_target_fun) do
      {:ok, fun} when is_function(fun, 1) ->
        fun.(issue)

      _ ->
        fetch_open_pr(issue, opts)
    end
  end

  defp fetch_open_pr(issue, opts) do
    fetcher = Keyword.get(opts, :open_pr_fetcher, &CodeHost.fetch_open_pull_request_for_branch/1)

    case fetcher.(issue.identifier) do
      {:ok, nil} -> {:ok, "rework"}
      {:ok, %{"number" => number}} -> fetch_and_classify_pr(number, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_and_classify_pr(number, opts) do
    fetch = Keyword.get(opts, :pr_fetcher, &Client.fetch_open_pull_request/1)

    case fetch.(number) do
      {:ok, %{"draft" => true}} -> {:ok, "rework"}
      {:ok, %{} = pr} -> classify_pr(pr, opts)
      {:ok, nil} -> {:error, :pull_request_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_pr(pr, opts) do
    case ReworkGate.open_pull_request_rework_verdict(pr, opts) do
      {:ok, :rework} -> {:ok, "rework"}
      {:skip, :no_unresolved_review_threads} -> {:ok, "human-review"}
      {:error, reason} -> {:error, reason}
    end
  end

  # The tracker write already landed, so a refresh that swapped `:issue` must not
  # keep the runner; only a different or resumed runner is left alone.
  @runner_fields [:pid, :ref, :session_id, :telemetry_attempt_id, :control]

  @doc false
  @spec release_result(map(), term(), keyword()) :: State.t()
  @spec apply_release(State.t(), term(), map(), keyword()) :: State.t()
  def release_result(entry, result, opts \\ []), do: apply_release(%State{running: %{entry.issue.id => entry}}, result, entry, opts)

  @spec apply_release(State.t(), {:release, String.t() | nil, String.t()}, map(), keyword()) :: State.t()
  def apply_release(state, {:release, target, reason}, %{issue: %{id: issue_id}} = entry, opts) do
    if same_parked_runner?(Map.get(state.running, issue_id), entry) do
      target = target || "rework or human-review"
      Logger.warning("Released duration-capped agent to #{target} #{State.issue_context(entry.issue)}")
      if reason != "progress was detected", do: emit_pause_alert(entry, reason, opts)
      resolve_pause_alert(entry, target, opts)
      AgentTeardown.terminate_running_issue(state, issue_id, false)
    else
      state
    end
  end

  @spec apply_release(State.t(), {:escalate, String.t()}, map(), keyword()) :: State.t()
  def apply_release(state, {:escalate, reason}, %{issue: %{id: issue_id}} = entry, opts) do
    if same_parked_runner?(Map.get(state.running, issue_id), entry), do: emit_pause_alert(entry, reason, opts)
    state
  end

  @spec apply_release(State.t(), {:ok, String.t()}, map(), keyword()) :: State.t()
  def apply_release(state, {:ok, target}, entry, opts), do: apply_release(state, {:release, target, "progress was detected"}, entry, opts)

  @spec apply_release(State.t(), {:redispatch, Aiur.Issue.t()}, map(), keyword()) :: State.t()
  def apply_release(state, {:redispatch, issue}, %{issue: %{id: issue_id}} = entry, opts) do
    if same_parked_runner?(Map.get(state.running, issue_id), entry) do
      case increment_duration_cap_retry(issue_id, opts) do
        :ok ->
          state = AgentTeardown.terminate_running_issue(state, issue_id, false)
          dispatch_after_budget(state, issue, entry, issue_id, opts)

        {:error, reason} ->
          emit_pause_alert(entry, "Could not record automatic redispatch retry (#{inspect(reason)}); Executor action is required.", opts)
          state
      end
    else
      state
    end
  end

  # A failed or deferred write leaves the agent paused for the Executor, as before #4849.
  def apply_release(state, result, entry, opts) do
    Logger.warning("Duration-capped agent stays paused; release did not complete: #{inspect(result)} #{State.issue_context(entry.issue)}")
    emit_pause_alert(entry, "Automatic redispatch was not available (#{inspect(result)}); Executor action is required.", opts)
    state
  end

  defp dispatch_after_budget(state, issue, entry, issue_id, opts) do
    dispatch = Keyword.get(opts, :dispatch_fun, &Dispatcher.dispatch_issue/5)
    attempt = Map.get(entry, :retry_attempt, 0) + 1
    completion = fn next -> finish_redispatch(next, entry, issue_id, opts) end
    dispatch.(state, issue, attempt, Map.get(entry, :worker_host), prior_work: true, dispatch_result_fun: completion)
  end

  defp finish_redispatch(state, entry, issue_id, opts) do
    started? =
      match?(%{control: %{status: :working}}, Map.get(state.running, issue_id)) or
        MapSet.member?(state.claimed, issue_id) or TrackerTasks.issue_pending?(state, issue_id)

    if started? do
      resolve_pause_alert(entry, "automatic redispatch after progress", opts)
      state
    else
      emit_pause_alert(entry, "Progress was detected, but automatic redispatch did not start; Executor action is required.", opts)
      state
    end
  end

  defp same_parked_runner?(%{paused_reason: :max_agent_duration} = current, entry),
    do: Map.take(current, @runner_fields) == Map.take(entry, @runner_fields)

  defp same_parked_runner?(_current, _entry), do: false

  defp progress?(entry, baseline, opts) do
    case Keyword.get(opts, :progress_fun) do
      fun when is_function(fun, 1) -> fun.(entry) == true
      _ -> workspace_progress?(entry, baseline, opts)
    end
  end

  defp baseline(entry, opts) do
    case Map.get(entry, :duration_cap_progress_baseline) do
      value when is_binary(value) ->
        {value, entry}

      _ ->
        probe = Keyword.get(opts, :workspace_probe, &workspace_fingerprint/2)

        case probe.(Map.get(entry, :workspace_path), Map.get(entry, :worker_host)) do
          {:ok, value} -> {value, Map.put(entry, :duration_cap_progress_baseline, value)}
          _ -> {nil, entry}
        end
    end
  end

  defp workspace_progress?(entry, baseline, opts) do
    case Map.get(entry, :workspace_path) do
      path when is_binary(path) ->
        probe = Keyword.get(opts, :workspace_probe, &workspace_fingerprint/2)

        case probe.(path, Map.get(entry, :worker_host)) do
          {:ok, fingerprint} -> is_binary(fingerprint) and is_binary(baseline) and fingerprint != baseline
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp workspace_fingerprint(path, worker_host), do: TurnProgress.workspace_digest(path, worker_host)

  defp retry_budget_available?(entry, opts) do
    budget? = Keyword.get(opts, :retry_budget_available_fun, fn _ -> true end)
    count = duration_cap_retry_count(entry, opts)

    budget?.(entry) and count < Keyword.get(opts, :max_retry_attempts, Config.max_retry_attempts()) and
      Map.get(entry, :dispatch_latch_status, :none) == :none
  end

  defp duration_cap_retry_count(entry, opts) do
    case Keyword.get(opts, :duration_cap_retry_count_fun) do
      fun when is_function(fun, 1) ->
        fun.(entry)

      _ ->
        case DurationCapRetryStore.count(entry.issue.id) do
          {:ok, count} -> count
          {:error, _reason} -> Keyword.get(opts, :max_retry_attempts, Config.max_retry_attempts())
        end
    end
  end

  defp increment_duration_cap_retry(issue_id, opts) do
    case Keyword.get(opts, :increment_duration_cap_retry_fun) do
      fun when is_function(fun, 1) -> fun.(issue_id)
      _ -> DurationCapRetryStore.increment(issue_id)
    end
  end

  defp release_reason(progress, issue, entry, opts) do
    cond do
      not DispatchPolicy.active_issue_state?(issue.state, DispatchPolicy.active_state_set()) -> "ticket state is inactive"
      not progress -> "no commits or workspace changes were found (workpad-only changes do not count)"
      not retry_budget_available?(entry, opts) -> "retry budget is spent"
      true -> "progress was detected"
    end
  end

  defp emit_pause_alert(entry, reason, opts) do
    emit = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit.("ticket.#{entry.identifier}.agent.attention.paused-max_agent_duration",
      issue: entry.identifier,
      workspace: Map.get(entry, :workspace_path),
      message: "Agent paused after reaching the maximum duration",
      reason: reason,
      needs_attention: true,
      severity: "warning"
    )
  end

  defp resolve_pause_alert(entry, target, opts) do
    emit = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit.("ticket.#{entry.identifier}.agent.attention.paused-max_agent_duration.resolved",
      issue: entry.identifier,
      workspace: Map.get(entry, :workspace_path),
      reason: "Duration-capped agent released; ticket moved to #{target}.",
      needs_attention: false,
      severity: "info"
    )
  end
end
