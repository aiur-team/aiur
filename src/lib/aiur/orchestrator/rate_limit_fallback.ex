defmodule Aiur.Orchestrator.RateLimitFallback do
  @moduledoc """
  Automatically reroutes a running agent on the configured primary backend to
  the configured fallback backend after `usage_limit_exhausted`, then reverts at
  a safe turn boundary once `Aiur.ModelAvailability` confirms the primary
  recovered. The backend pair is `agent.rate_limit_primary` /
  `agent.rate_limit_fallback` (defaults `"codex"` / `"claude"`); any eligible
  registry-declared fallback target works, and `""` disables the reroute.

  A durable `model:<fallback>` label drives existing backend routing, while a
  second marker records Aiur's ownership so Executor-authored overrides remain
  untouched. The fallback does not replace the primary's resumable session
  handle, and redispatch preserves worker affinity, allowing the original
  rollout to resume after recovery or an Aiur restart.

  All functions execute inside the orchestrator GenServer process, called
  once per poll tick from `Reconciler.reconcile_running_lifecycle/1`.
  """

  require Logger
  alias Aiur.Accounts.UsageReadings
  alias Aiur.{CodingAgent, Config, Issue, ModelAvailability}
  alias Aiur.Orchestrator.RateLimitFallback.Redispatch

  alias Aiur.Orchestrator.{
    ControlLifecycle,
    PauseResume,
    RateLimitFallbackTransition,
    RemoteControlMode,
    State
  }

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
      |> Keyword.put_new_lazy(:primary_backend, &Config.rate_limit_primary_backend/0)
      |> Keyword.put_new_lazy(:marker_label, &marker_label/0)
      |> Keyword.put_new_lazy(:state, &ModelAvailability.load/0)

    state = RateLimitFallbackTransition.prune(state)
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
          :engage | :prepare_revert | :revert | :cancel_revert | :resume | :handoff | :noop
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
    fallback_backend = fallback_backend(opts)
    primary_backend = primary_backend(opts)
    current_backend = Keyword.get_lazy(opts, :current_backend, fn -> CodingAgent.backend_for(issue) end)

    State.paused_running_entry?(running_entry) and
      Map.get(running_entry, :paused_reason) == :usage_limit_exhausted and
      is_binary(fallback_backend) and fallback_backend in CodingAgent.known_backends() and
      fallback_backend != current_backend and
      ModelAvailability.available?(fallback_backend, opts) and
      is_nil(CodingAgent.override_backend(issue)) and
      current_backend == primary_backend
  end

  defp recovery_ready?(running_entry, opts) do
    ModelAvailability.recovery_confirmed?(primary_backend(opts), opts) and
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
          not ModelAvailability.recovery_confirmed?(primary_backend(opts), opts) ->
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
    cond do
      account_handoff_ready?(running_entry, opts) -> :handoff
      usage_pause_recovered?(running_entry, issue, opts) -> :resume
      usage_limited_on_primary?(running_entry, issue, opts) -> :engage
      true -> :noop
    end
  end

  defp account_handoff_ready?(entry, opts) do
    session = Map.get(entry, :usage_limit_session, %{})

    if handoff_candidate?(entry, session) do
      config = Keyword.get_lazy(opts, :account_config, fn -> Config.settings!().agent end)
      source = session.account_name
      candidates = configured_claude_accounts(config, opts) |> Enum.reject(&(&1 == source))
      usages = account_usages(candidates, opts)

      match?({:ok, _}, Aiur.Accounts.select("claude", candidates, config.account_selection || "balance", usages))
    else
      false
    end
  rescue
    _ -> false
  end

  defp handoff_candidate?(entry, session) do
    # Headless Claude's aiur-claude app-server is not resumable: its thread map
    # is in-memory and thread/start cannot seed a moved session transcript.
    # Keep those sessions on the existing wait-for-reset path.
    State.paused_running_entry?(entry) and Map.get(entry, :paused_reason) == :usage_limit_exhausted and
      Map.get(entry, :account_handoff_attempted) != true and Map.get(session, :backend) == "claude-repl" and
      is_binary(session[:account_name]) and is_binary(session[:session_id]) and is_binary(session[:cwd])
  end

  defp configured_claude_accounts(config, opts) do
    names = Map.get(config.accounts || %{}, "claude", [])
    list_accounts = Keyword.get(opts, :account_list_fun, &Aiur.Accounts.list/1)
    registered = MapSet.new(list_accounts.("claude"), & &1.name)
    Enum.filter(names, &MapSet.member?(registered, &1))
  end

  defp account_usages(names, opts) do
    polled = UsageReadings.snapshot("claude", names)

    fetch =
      Keyword.get(opts, :account_usage_fetcher, fn name ->
        case Aiur.Accounts.usage("claude", name) do
          {:ok, %{windows: windows}, _metadata} -> Map.new(windows, &{&1.window, &1.used_percent})
          _ -> nil
        end
      end)

    Map.new(names, fn name ->
      value =
        case Map.fetch(polled, name) do
          {:ok, %{reading: %{windows: windows}}} -> Map.new(windows, &{&1.window, &1.used_percent})
          {:ok, _unavailable} -> nil
          :error -> fetch.(name)
        end

      {name, value}
    end)
  end

  defp usage_pause_recovered?(entry, issue, opts) do
    backend = Keyword.get_lazy(opts, :current_backend, fn -> CodingAgent.backend_for(issue) end)

    State.paused_running_entry?(entry) and
      Map.get(entry, :paused_reason) == :usage_limit_exhausted and
      not Issue.paused?(issue) and
      usage_reset_recovered?(entry, backend, opts)
  end

  # Keep a worker's explicit deadline even if writing the shared ledger failed.
  # An older positive ledger observation must not undo a newly reported limit.
  defp usage_reset_recovered?(entry, backend, opts) do
    with reset when is_binary(reset) <- Map.get(entry, :usage_limit_reset_at),
         {:ok, reset_at, _offset} <- DateTime.from_iso8601(reset) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      DateTime.compare(now, reset_at) != :lt and ModelAvailability.available?(backend, opts)
    else
      _ -> ModelAvailability.recovery_confirmed?(backend, opts)
    end
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
    if RateLimitFallbackTransition.deferred?(state, issue.id, opts) do
      {state, false}
    else
      case ControlLifecycle.current_pending(state.control_lifecycle, issue.id) do
        %{action: :resume} -> {state, false}
        _ -> apply_decision(state, running_entry, issue, decide(running_entry, issue, opts), opts)
      end
    end
  end

  defp reconcile_entry(state, _entry, _opts), do: {state, false}

  defp apply_decision(state, _running_entry, _issue, :noop, _opts), do: {state, false}

  defp apply_decision(%State{globally_paused: true} = state, _entry, _issue, :resume, _opts), do: {state, false}

  defp apply_decision(state, running_entry, _issue, :resume, opts) do
    resume = Keyword.get(opts, :resume_fun, &PauseResume.resume_paused_issue(&1, &2, false))

    case resume.(state, running_entry) do
      {{:ok, :resumed}, resumed_state} -> {resumed_state, true}
      {_error, deferred_state} -> {deferred_state, false}
    end
  end

  defp apply_decision(state, running_entry, issue, :engage, opts) do
    fallback_backend = fallback_backend(opts)
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    relabeled = engage_issue(issue, fallback_backend, marker_label)
    context = Redispatch.transition_context(state, running_entry, issue, relabeled, opts)

    if Redispatch.backend_ready?(fallback_backend, running_entry, opts) do
      case Redispatch.admission(state, relabeled, running_entry, opts) do
        {:ok, admitted_state} ->
          engage_after_preflight(%{context | state: admitted_state}, fallback_backend, marker_label)

        {:error, reason, rejected_state} ->
          Logger.info("Rate-limit fallback engage deferred: #{log_context(running_entry, issue)} reason=#{inspect(reason)}")

          {rejected_state, false}
      end
    else
      Logger.warning("Rate-limit fallback engage deferred; backend unavailable: #{log_context(running_entry, issue)} backend=#{fallback_backend}")

      {state, false}
    end
  end

  defp apply_decision(state, running_entry, issue, :handoff, opts) do
    session = Map.get(running_entry, :usage_limit_session, %{})
    config = Keyword.get_lazy(opts, :account_config, fn -> Config.settings!().agent end)
    candidates = configured_claude_accounts(config, opts) |> Enum.reject(&(&1 == session.account_name))
    usages = account_usages(candidates, opts)
    move_session = Keyword.get(opts, :move_session_fun, &Aiur.Accounts.move_session/6)

    with {:ok, destination} <- Aiur.Accounts.select("claude", candidates, config.account_selection || "balance", usages),
         :ok <- move_session.("claude", session.account_name, destination, session.session_id, session.cwd, Keyword.get(opts, :move_opts, [])) do
      Redispatch.handoff(opts, state, running_entry, issue, destination, session)
    else
      {:error, reason} ->
        Logger.warning("Claude account handoff deferred: #{log_context(running_entry, issue)} reason=#{inspect(reason)}")
        {put_running_entry(state, issue.id, Map.put(running_entry, :account_handoff_attempted, true)), true}
    end
  end

  defp apply_decision(state, running_entry, issue, :revert, opts) do
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    engaged = engaged_fallback(issue, opts)
    relabeled = revert_issue(issue, marker_label, engaged, opts)
    context = Map.put(Redispatch.transition_context(state, running_entry, issue, relabeled, opts), :engaged_fallback, engaged)

    case Redispatch.admission(state, relabeled, running_entry, opts) do
      {:ok, admitted_state} ->
        revert_after_preflight(%{context | state: admitted_state}, marker_label)

      {:error, reason, rejected_state} ->
        maybe_resume_deferred_revert(rejected_state, running_entry, reason, opts)
    end
  end

  defp apply_decision(state, running_entry, issue, :prepare_revert, opts) do
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    relabeled = revert_issue(issue, marker_label, engaged_fallback(issue, opts), opts)
    pause = Keyword.get(opts, :pause_fun, &PauseResume.send_pause_control_message/2)

    case Redispatch.admission(state, relabeled, running_entry, opts) do
      {:ok, admitted_state} ->
        case pause.(admitted_state, Map.get(running_entry, :identifier)) do
          {:ok, _request_id} ->
            pending_entry =
              running_entry
              |> Map.put(:rate_limit_fallback_revert_pending, true)
              |> Map.put(:paused_reason, @recovery_pause_reason)

            Logger.info("Codex recovery confirmed; requesting fallback pause checkpoint: #{log_context(running_entry, issue)}")

            {put_running_entry(admitted_state, issue.id, pending_entry), true}

          {:error, reason} ->
            log_recovery_checkpoint_deferred(running_entry, issue, reason)
            {admitted_state, false}
        end

      {:error, reason, rejected_state} ->
        log_recovery_checkpoint_deferred(running_entry, issue, reason)
        {rejected_state, false}
    end
  end

  defp apply_decision(state, running_entry, _issue, :cancel_revert, opts) do
    cleared_entry = clear_recovery_pending(running_entry)

    if State.paused_running_entry?(running_entry) do
      resume =
        Keyword.get(opts, :resume_fun, fn current_state, entry ->
          PauseResume.resume_paused_issue(current_state, entry, false)
        end)

      # Resume from an entry that still carries `:paused_reason`. PauseResume
      # reads it to emit the matching `agent.attention.paused-<cause>.resolved`
      # and clears it itself; handing over the already-cleared entry made the
      # cause look absent, so the pause attention stayed active forever.
      resume_entry = Map.delete(cleared_entry, :rate_limit_fallback_revert_pending)

      resume_entry =
        case Map.fetch(running_entry, :paused_reason) do
          {:ok, reason} -> Map.put(resume_entry, :paused_reason, reason)
          :error -> resume_entry
        end

      staged_state = put_running_entry(state, get_in(running_entry, [:issue, Access.key(:id)]), resume_entry)

      case resume.(staged_state, resume_entry) do
        {{:ok, :resumed}, resumed_state} -> {resumed_state, true}
        _ -> {state, false}
      end
    else
      issue_id = get_in(running_entry, [:issue, Access.key(:id)])
      {put_running_entry(state, issue_id, cleared_entry), true}
    end
  end

  defp engage_after_preflight(context, backend, marker),
    do: RateLimitFallbackTransition.run(context, :engage, backend, marker, &Redispatch.redispatch/4)

  defp revert_after_preflight(context, marker),
    do: RateLimitFallbackTransition.run(context, :revert, context.engaged_fallback, marker, &Redispatch.redispatch/4)

  defp log_recovery_checkpoint_deferred(running_entry, issue, reason) do
    Logger.info("Rate-limit fallback recovery checkpoint deferred: #{log_context(running_entry, issue)} reason=#{inspect(reason)}")
  end

  defp engage_issue(issue, backend, marker_label) do
    issue
    |> select_backend(backend)
    |> RemoteControlMode.add_issue_label(model_label(backend))
    |> RemoteControlMode.add_issue_label(marker_label)
  end

  defp revert_issue(issue, marker_label, engaged_fallback, opts) do
    issue
    |> select_backend(nil)
    |> RemoteControlMode.remove_issue_label(marker_label)
    |> RemoteControlMode.remove_issue_label(model_label(engaged_fallback))
    |> select_current_route(opts)
  end

  # A headroom choice is dropped here, so the fallback backend is a pin (#3960).
  defp select_backend(issue, backend),
    do: %{issue | selected_backend: backend, selected_account: nil, dispatch_selection: nil, selected_model: if(issue.dispatch_selection, do: nil, else: issue.selected_model)}

  defp select_current_route(issue, opts) do
    backend =
      CodingAgent.override_backend(issue) ||
        CodingAgent.routing_backend(issue) || primary_backend(opts)

    select_backend(issue, backend)
  end

  # The backend whose `model:<backend>` label revert must strip. Prefer the
  # running entry's `selected_backend` when it is still pinned to the engaged
  # fallback, since that is unambiguous even when an operator's own
  # `model:<backend>` override also sits on the issue (so we must not use
  # `override_backend/1`, which would pick the first label and could strip the
  # operator's). When `selected_backend` is not set (a reloaded entry drops the
  # in-memory field), fall back to the configured fallback — correct as long as the fallback config has not changed since engage, which is the normal case;
  # a config change between engage and revert is a rare edge that could orphan the label, and is not handled here.
  defp engaged_fallback(%Issue{selected_backend: backend}, _opts) when is_binary(backend), do: backend
  defp engaged_fallback(_issue, opts), do: fallback_backend(opts)

  defp fallback_backend(opts),
    do: Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)

  defp primary_backend(opts),
    do: Keyword.get_lazy(opts, :primary_backend, &Config.rate_limit_primary_backend/0)

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

  @doc false
  @spec put_running_entry(State.t(), String.t(), map()) :: State.t()
  def put_running_entry(state, issue_id, entry),
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
