defmodule Aiur.Orchestrator.RateLimitFallback do
  @moduledoc """
  Automatically reroutes a running codex agent to headless Claude after
  `usage_limit_exhausted`, then reverts at a safe turn boundary once
  `Aiur.ModelAvailability` confirms codex recovery. Configured by
  `agent.rate_limit_fallback` (default `"claude"`).

  A durable `model:claude` label drives existing backend routing, while a
  second marker records Aiur's ownership so Executor-authored overrides remain
  untouched. Headless Claude does not replace codex's resumable session handle,
  and redispatch preserves worker affinity, allowing the original rollout to
  resume after recovery or an Aiur restart.

  All functions execute inside the orchestrator GenServer process, called
  once per poll tick from `Reconciler.reconcile_running_lifecycle/1`.
  """

  require Logger

  alias Aiur.Claude.Config, as: ClaudeConfig
  alias Aiur.{CodingAgent, Config, Issue, ModelAvailability, Tracker}

  alias Aiur.Orchestrator.{
    Dispatcher,
    PauseResume,
    RemoteControlMode,
    RetryEngine,
    State
  }

  @primary_backend "codex"
  @fallback_backend "claude"
  @marker_label_suffix "rate-limit-fallback"
  @minimum_fallback_dwell_seconds 60
  @max_transitions_per_tick 1
  @recovery_pause_reason :rate_limit_fallback_recovery

  @spec reconcile(State.t()) :: State.t()
  def reconcile(%State{} = state), do: reconcile(state, [])

  @doc false
  @spec reconcile(State.t(), keyword()) :: State.t()
  def reconcile(%State{} = state, opts) when is_list(opts) do
    # Resolve config and the availability ledger once for the whole tick.
    opts =
      opts
      |> Keyword.put_new_lazy(:fallback_backend, &Config.rate_limit_fallback_backend/0)
      |> Keyword.put_new_lazy(:marker_label, &marker_label/0)
      |> Keyword.put_new_lazy(:state, &ModelAvailability.load/0)

    max_transitions = max_transitions_per_tick(opts)

    {state, _transition_count} =
      state.running
      |> Enum.sort_by(fn {issue_id, _entry} -> to_string(issue_id) end)
      |> Enum.reduce_while(
        {state, 0},
        &reconcile_until_limit(&1, &2, opts, max_transitions)
      )

    state
  end

  # Runtime dependencies in `opts` keep the decision pure in tests.
  @doc false
  @spec decide(map(), Issue.t(), keyword()) ::
          :engage | :prepare_revert | :revert | :cancel_revert | :noop
  def decide(running_entry, %Issue{} = issue, opts \\ []) do
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)

    if fallback_engaged?(issue, marker_label) do
      decide_engaged(running_entry, issue, opts)
    else
      decide_unengaged(running_entry, issue, opts)
    end
  end

  @doc false
  @spec fallback_engaged?(Issue.t(), String.t()) :: boolean()
  def fallback_engaged?(%Issue{} = issue, marker_label \\ marker_label()) do
    normalized_marker = normalize_label(marker_label)
    Enum.any?(Issue.label_names(issue), &(normalize_label(&1) == normalized_marker))
  end

  defp usage_limited_on_primary?(running_entry, issue, opts) do
    fallback_backend = Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)
    current_backend = Keyword.get_lazy(opts, :current_backend, fn -> CodingAgent.backend_for(issue) end)

    State.paused_running_entry?(running_entry) and
      Map.get(running_entry, :paused_reason) == :usage_limit_exhausted and
      fallback_backend == @fallback_backend and
      ModelAvailability.available?(fallback_backend, opts) and
      is_nil(CodingAgent.override_backend(issue)) and
      current_backend == @primary_backend
  end

  defp recovery_ready?(running_entry, opts) do
    ModelAvailability.recovery_confirmed?(@primary_backend, opts) and
      fallback_dwell_elapsed?(running_entry, opts)
  end

  defp fallback_dwell_elapsed?(running_entry, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    minimum_seconds = Keyword.get(opts, :minimum_dwell_seconds, @minimum_fallback_dwell_seconds)

    case Map.get(running_entry, :started_at) do
      %DateTime{} = started_at -> DateTime.diff(now, started_at, :second) >= minimum_seconds
      _ -> false
    end
  end

  defp safe_revert_pause?(running_entry) do
    State.paused_running_entry?(running_entry) and
      Map.get(running_entry, :paused_reason) in [
        :usage_limit_exhausted,
        @recovery_pause_reason
      ]
  end

  defp recovery_pending?(running_entry),
    do: Map.get(running_entry, :rate_limit_fallback_revert_pending) == true

  defp decide_engaged(running_entry, issue, opts) do
    if usage_limited_on_primary?(running_entry, issue, opts),
      do: :engage,
      else: decide_engaged_recovery(running_entry, opts)
  end

  defp decide_engaged_recovery(running_entry, opts) do
    cond do
      recovery_pending?(running_entry) and
          not ModelAvailability.recovery_confirmed?(@primary_backend, opts) ->
        :cancel_revert

      recovery_ready?(running_entry, opts) ->
        decide_recovery_ready(running_entry)

      true ->
        :noop
    end
  end

  defp decide_recovery_ready(running_entry) do
    cond do
      safe_revert_pause?(running_entry) -> :revert
      recovery_pending?(running_entry) -> :noop
      State.active_running_entry?(running_entry) -> :prepare_revert
      true -> :noop
    end
  end

  defp decide_unengaged(running_entry, issue, opts) do
    if usage_limited_on_primary?(running_entry, issue, opts), do: :engage, else: :noop
  end

  defp reconcile_until_limit(
         _item,
         {state, transition_count},
         _opts,
         max_transitions
       )
       when transition_count >= max_transitions,
       do: {:halt, {state, transition_count}}

  defp reconcile_until_limit(
         {_issue_id, entry},
         {state, transition_count},
         opts,
         _max_transitions
       ) do
    {next_state, transitioned?} = reconcile_entry(state, entry, opts)
    next_count = if transitioned?, do: transition_count + 1, else: transition_count
    {:cont, {next_state, next_count}}
  end

  defp reconcile_entry(state, %{issue: %Issue{} = issue} = running_entry, opts) do
    apply_decision(state, running_entry, issue, decide(running_entry, issue, opts), opts)
  end

  defp reconcile_entry(state, _entry, _opts), do: {state, false}

  defp apply_decision(state, _running_entry, _issue, :noop, _opts), do: {state, false}

  defp apply_decision(state, running_entry, issue, :engage, opts) do
    fallback_backend = Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    relabeled = engage_issue(issue, fallback_backend, marker_label)
    context = transition_context(state, running_entry, issue, relabeled, opts)

    if fallback_backend_ready?(fallback_backend, running_entry, opts) do
      case redispatch_ready(state, relabeled, running_entry, opts) do
        :ok ->
          engage_after_preflight(context, fallback_backend, marker_label)

        {:error, reason} ->
          Logger.info("Rate-limit fallback engage deferred: #{log_context(running_entry, issue)} reason=#{inspect(reason)}")

          {state, false}
      end
    else
      Logger.warning("Rate-limit fallback engage deferred; backend unavailable: #{log_context(running_entry, issue)} backend=#{fallback_backend}")

      {state, false}
    end
  end

  defp apply_decision(state, running_entry, issue, :revert, opts) do
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    relabeled = revert_issue(issue, marker_label)
    context = transition_context(state, running_entry, issue, relabeled, opts)

    case redispatch_ready(state, relabeled, running_entry, opts) do
      :ok ->
        revert_after_preflight(context, marker_label)

      {:error, reason} ->
        maybe_resume_deferred_revert(state, running_entry, reason, opts)
    end
  end

  defp apply_decision(state, running_entry, issue, :prepare_revert, opts) do
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    relabeled = revert_issue(issue, marker_label)
    pause = Keyword.get(opts, :pause_fun, &PauseResume.send_pause_control_message/2)

    with :ok <- redispatch_ready(state, relabeled, running_entry, opts),
         {:ok, _request_id} <- pause.(state, Map.get(running_entry, :identifier)) do
      pending_entry =
        running_entry
        |> Map.put(:rate_limit_fallback_revert_pending, true)
        |> Map.put(:paused_reason, @recovery_pause_reason)

      Logger.info("Codex recovery confirmed; requesting fallback pause checkpoint: #{log_context(running_entry, issue)}")

      {put_running_entry(state, issue.id, pending_entry), true}
    else
      {:error, reason} ->
        Logger.info("Rate-limit fallback recovery checkpoint deferred: #{log_context(running_entry, issue)} reason=#{inspect(reason)}")

        {state, false}
    end
  end

  defp apply_decision(state, running_entry, _issue, :cancel_revert, opts) do
    cleared_entry = clear_recovery_pending(running_entry)

    if State.paused_running_entry?(running_entry) do
      resume =
        Keyword.get(opts, :resume_fun, fn current_state, entry ->
          PauseResume.resume_paused_issue(current_state, entry, false)
        end)

      staged_state = put_running_entry(state, get_in(running_entry, [:issue, Access.key(:id)]), cleared_entry)

      case resume.(staged_state, cleared_entry) do
        {{:ok, :resumed}, resumed_state} -> {resumed_state, true}
        _ -> {state, false}
      end
    else
      issue_id = get_in(running_entry, [:issue, Access.key(:id)])
      {put_running_entry(state, issue_id, cleared_entry), true}
    end
  end

  defp transition_context(state, running_entry, issue, relabeled, opts) do
    %{
      add_label: Keyword.get(opts, :add_label_fun, &Tracker.add_label/2),
      identifier: Map.get(running_entry, :identifier),
      issue: issue,
      opts: opts,
      relabeled: relabeled,
      remove_label: Keyword.get(opts, :remove_label_fun, &Tracker.remove_label/2),
      running_entry: running_entry,
      state: state
    }
  end

  defp engage_after_preflight(context, fallback_backend, marker_label) do
    case context.add_label.(context.identifier, marker_label) do
      :ok ->
        case context.add_label.(context.identifier, model_label(fallback_backend)) do
          :ok ->
            Logger.warning(
              "Codex usage-limit fallback engaged; re-dispatching on #{fallback_backend}: " <>
                log_context(context.running_entry, context.issue)
            )

            {redispatch(context.state, context.running_entry, context.relabeled, context.opts), true}

          {:error, reason} ->
            rollback = context.remove_label.(context.identifier, marker_label)

            log_transition_failure(
              :engage,
              context.running_entry,
              context.issue,
              reason,
              rollback
            )

            {context.state, true}
        end

      {:error, reason} ->
        log_transition_failure(
          :engage,
          context.running_entry,
          context.issue,
          reason,
          :not_needed
        )

        {context.state, true}
    end
  end

  defp revert_after_preflight(context, marker_label) do
    case context.remove_label.(context.identifier, model_label(@fallback_backend)) do
      :ok ->
        case context.remove_label.(context.identifier, marker_label) do
          :ok ->
            Logger.info(
              "Codex recovered; reverting usage-limit fallback: " <>
                log_context(context.running_entry, context.issue)
            )

            {redispatch(context.state, context.running_entry, context.relabeled, context.opts), true}

          {:error, reason} ->
            rollback = context.add_label.(context.identifier, model_label(@fallback_backend))

            log_transition_failure(
              :revert,
              context.running_entry,
              context.issue,
              reason,
              rollback
            )

            {context.state, true}
        end

      {:error, reason} ->
        log_transition_failure(
          :revert,
          context.running_entry,
          context.issue,
          reason,
          :not_needed
        )

        {context.state, true}
    end
  end

  defp log_transition_failure(transition, running_entry, issue, reason, rollback) do
    Logger.error(
      "Rate-limit fallback #{transition} failed: #{log_context(running_entry, issue)} " <>
        "reason=#{inspect(reason)} rollback=#{inspect(rollback)}"
    )
  end

  # Keep the issue on the worker that owns its workspace and session rollout.
  defp redispatch(state, running_entry, relabeled_issue, opts) do
    issue_id = relabeled_issue.id
    worker_host = Map.get(running_entry, :worker_host)
    teardown = Keyword.get(opts, :teardown_fun, &RemoteControlMode.teardown_for_redispatch/3)
    dispatch = Keyword.get(opts, :dispatch_fun, &Dispatcher.do_dispatch_issue/4)

    state = teardown.(state, running_entry, :rate_limit_fallback)
    state = %{state | running: Map.delete(state.running, issue_id)}
    state = dispatch.(state, relabeled_issue, nil, worker_host)

    ensure_redispatch_started(state, running_entry, relabeled_issue, worker_host, opts)
  end

  defp ensure_redispatch_started(state, running_entry, issue, worker_host, opts) do
    if live_running_entry?(Map.get(state.running, issue.id)) or
         Map.has_key?(state.retry_attempts, issue.id) do
      state
    else
      schedule_retry = Keyword.get(opts, :schedule_retry_fun, &RetryEngine.schedule_issue_retry/4)
      next_attempt = RetryEngine.next_retry_attempt_from_running(running_entry)

      schedule_retry.(state, issue.id, next_attempt, %{
        identifier: issue.identifier,
        error: "backend redispatch did not start",
        worker_host: worker_host,
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp live_running_entry?(%{pid: pid}) when is_pid(pid), do: true
  defp live_running_entry?(_entry), do: false

  defp redispatch_ready(state, issue, running_entry, opts) do
    ready = Keyword.get(opts, :dispatch_ready_fun, &Dispatcher.redispatch_ready?/3)
    ready.(state, issue, Map.get(running_entry, :worker_host))
  end

  defp fallback_backend_ready?(backend, running_entry, opts) do
    worker_host = Map.get(running_entry, :worker_host)

    ready =
      Keyword.get(opts, :backend_ready_fun, fn candidate, host ->
        default_backend_ready?(candidate, host, opts)
      end)

    backend == @fallback_backend and backend in CodingAgent.known_backends() and
      ready.(backend, worker_host)
  end

  # Headless Claude currently spawns on the orchestrator host and cannot use an
  # SSH worker's remote-only workspace. Leave those codex agents parked rather
  # than moving their durable labels to a backend that cannot start there.
  defp default_backend_ready?(@fallback_backend, nil, opts) do
    find_executable = Keyword.get(opts, :find_executable_fun, &System.find_executable/1)

    case ClaudeConfig.command() |> String.split(~r/\s+/, trim: true) do
      [executable | _args] -> is_binary(find_executable.(executable))
      [] -> false
    end
  end

  defp default_backend_ready?(_backend, _worker_host, _opts), do: false

  defp engage_issue(issue, backend, marker_label) do
    issue
    |> select_backend(backend)
    |> RemoteControlMode.add_issue_label(model_label(backend))
    |> RemoteControlMode.add_issue_label(marker_label)
  end

  defp revert_issue(issue, marker_label) do
    issue
    |> select_backend(nil)
    |> RemoteControlMode.remove_issue_label(marker_label)
    |> RemoteControlMode.remove_issue_label(model_label(@fallback_backend))
    |> select_current_route()
  end

  defp select_backend(issue, backend), do: %{issue | selected_backend: backend}

  defp select_current_route(issue) do
    backend =
      CodingAgent.override_backend(issue) ||
        CodingAgent.routing_backend(issue) || @primary_backend

    select_backend(issue, backend)
  end

  defp maybe_resume_deferred_revert(state, running_entry, reason, opts) do
    Logger.info("Rate-limit fallback revert deferred: #{log_context(running_entry, running_entry.issue)} reason=#{inspect(reason)}")

    if recovery_pending?(running_entry),
      do: apply_decision(state, running_entry, running_entry.issue, :cancel_revert, opts),
      else: {state, false}
  end

  defp clear_recovery_pending(entry) do
    entry = Map.delete(entry, :rate_limit_fallback_revert_pending)

    if Map.get(entry, :paused_reason) == @recovery_pause_reason,
      do: Map.delete(entry, :paused_reason),
      else: entry
  end

  defp put_running_entry(state, issue_id, entry),
    do: %{state | running: Map.put(state.running, issue_id, entry)}

  defp max_transitions_per_tick(opts) do
    case Keyword.get(opts, :max_transitions_per_tick, @max_transitions_per_tick) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @max_transitions_per_tick
    end
  end

  defp model_label(backend), do: "model:#{backend}"

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()

  defp marker_label, do: "#{Config.settings!().tracker.github.label_prefix}:#{@marker_label_suffix}"

  defp log_context(running_entry, issue),
    do: "#{State.issue_context(issue)} session_id=#{State.running_entry_session_id(running_entry)}"
end
