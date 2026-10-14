defmodule Aiur.Orchestrator.Dispatcher.HoldsAndAlerts do
  @moduledoc """
  Prewarm and tracker-preflight dispatch holds and their emit/clear alert pairs.
  """

  require Logger

  alias Aiur.AlertFeed
  alias Aiur.Alerts
  alias Aiur.Commands
  alias Aiur.Config
  alias Aiur.GitHub.AuthPreflight
  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.Dispatcher.Candidates
  alias Aiur.Orchestrator.Dispatcher.Capacity
  alias Aiur.Orchestrator.Dispatcher.CapacityConstraints
  alias Aiur.Orchestrator.DispatchOutcome
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerHealth

  # The prewarm gate holds the whole fleet while the warm base builds/clones.
  # That can persist across many poll cycles, so the hold is logged at most once
  # per this many consecutive hold ticks instead of every tick (which would bury
  # the signal in a wall of identical lines) — but still often enough that a
  # slow or permanently-stuck base build stays visible in the daemon log.
  @prewarm_hold_log_interval_ticks 30
  # A prewarm hold is only an operator-facing event once it has outlived a
  # routine refresh. A scheduled freshness probe resolves in seconds, so its
  # gate hold self-clears within a poll or two and never matters to an operator;
  # reporting it at `needs_attention` severity on every cycle drowns a real
  # block in background hum (#2432). This debounce lets the routine hold pass
  # silently and raises `system.dispatch.prewarm_blocked` only once a hold has
  # persisted past the bound — a probe that fails or exceeds its own timeout,
  # a build that genuinely holds the fleet, or a stalled hold the dispatch
  # watchdog later releases. Kept below `RepoBase`'s 30s remote-probe timeout so
  # a probe that exceeds its bound is reported while the gate is still held.
  @prewarm_blocked_alert_after_ms 15_000
  # The base is readied before CPU admission so per-issue workspaces can use it
  # instead of cold-cloning. A failed build deliberately falls back to dispatch,
  # while an in-progress build holds this tick. The hold is made observable (see
  # log_prewarm_hold/2) so a gated fleet is distinguishable from an idle one.
  @spec dispatch_or_hold(State.t(), [Issue.t()]) :: State.t()
  def dispatch_or_hold(%State{} = state, issues) when is_list(issues) do
    dispatch_or_hold(state, issues, &Dispatcher.trigger_and_status/0)
  end

  @doc false
  # Testable variant with an injected phase reader; the production path passes
  # `&RepoBase.refresh_for_dispatch/0` via `trigger_and_status/0`.
  @spec dispatch_or_hold(State.t(), [Issue.t()], (-> term())) :: State.t()
  def dispatch_or_hold(%State{} = state, issues, trigger_fun)
      when is_list(issues) and is_function(trigger_fun, 0) do
    dispatch_or_hold(state, issues, trigger_fun, [])
  end

  @doc false
  @spec dispatch_or_hold(State.t(), [Issue.t()], (-> term()), keyword()) :: State.t()
  def dispatch_or_hold(%State{} = state, issues, trigger_fun, opts)
      when is_list(issues) and is_function(trigger_fun, 0) and is_list(opts) do
    # An answer may arrive during the tracker fetch; admission must read the current local hold.
    state = Candidates.refresh_blocked_ticket_ids(state, Keyword.get(opts, :decision_store, Commands.default_store()))

    # Constraints are re-sampled every tick, so a stale gate never lingers in
    # `status` after the condition clears.
    state = %{state | dispatch_capacity_constraints: [], dispatch_selection_hold: nil}

    enabled? = Config.prewarm_enabled?()
    phase = if enabled?, do: trigger_fun.(), else: :ready
    log_fun = Keyword.get(opts, :log_fun, &Logger.info/1)
    admission_probes_fun = Keyword.get(opts, :admission_probes_fun, &Capacity.admission_probes/0)

    case DispatchPolicy.prewarm_gate(enabled?, phase) do
      :dispatch ->
        maybe_log_base_error(phase)

        # The candidate chain is asynchronous: judge its outcome when it ends
        # (#3683). An admission hold never starts it; `capacity_hold` names that.
        chain_done = fn current, stop_reason -> DispatchOutcome.record(state, current, issues, log_fun, stop_reason) end
        choose_opts = Keyword.put(opts, :dispatch_chain_done_fun, chain_done)

        state
        |> clear_prewarm_blocked_alert(phase)
        |> Map.put(:prewarm_hold_ticks, 0)
        |> Capacity.maybe_choose_under_load(issues, fn sampled, candidates -> Dispatcher.maybe_choose(sampled, candidates, choose_opts) end, admission_probes_fun: admission_probes_fun)

      :hold ->
        next =
          state
          |> Capacity.maybe_sample_host_pressure_under_prewarm_hold(issues, admission_probes_fun, opts)
          |> log_prewarm_hold(phase, log_fun)
          |> maybe_emit_prewarm_blocked_alert(phase)

        DispatchOutcome.record(state, next, issues, log_fun)
    end
  end

  # Raises `system.dispatch.prewarm_blocked` only once a prewarm hold has
  # persisted past `@prewarm_blocked_alert_after_ms`, so a routine refresh probe
  # that self-clears in seconds is never reported while a genuine block still is
  # (#2432). The hold start is stamped on the first observed hold tick; a hold
  # that clears before the bound (the healthy case) emits nothing, and the
  # debounce is reset by `clear_prewarm_blocked_alert/2` on the dispatch side.
  # The already-active clause is handled here so a block that has been reported
  # keeps recording the capacity constraint without re-publishing.
  @doc false
  @spec maybe_emit_prewarm_blocked_alert(State.t(), term()) :: State.t()
  def maybe_emit_prewarm_blocked_alert(%State{} = state, phase),
    do: maybe_emit_prewarm_blocked_alert(state, phase, fn -> System.monotonic_time(:millisecond) end)

  @doc false
  @spec maybe_emit_prewarm_blocked_alert(State.t(), term(), (-> non_neg_integer())) :: State.t()
  def maybe_emit_prewarm_blocked_alert(%State{} = state, phase, now_fun)
      when is_function(now_fun, 0) do
    now_ms = now_fun.()
    since_ms = state.prewarm_hold_since_ms || now_ms
    state = %{state | prewarm_hold_since_ms: since_ms}

    if state.prewarm_blocked_alert_active or now_ms - since_ms < @prewarm_blocked_alert_after_ms do
      CapacityConstraints.record_capacity_constraint(state, :build, "prewarm=#{phase}")
    else
      emit_prewarm_blocked_alert(state, phase)
    end
  end

  @doc false
  @spec emit_prewarm_blocked_alert(State.t(), atom()) :: State.t()
  def emit_prewarm_blocked_alert(%State{prewarm_blocked_alert_active: true} = state, phase),
    do: CapacityConstraints.record_capacity_constraint(state, :build, "prewarm=#{phase}")

  def emit_prewarm_blocked_alert(%State{} = state, phase) do
    reason = prewarm_blocked_reason(phase)

    state = CapacityConstraints.record_capacity_constraint(state, :build, "prewarm=#{phase}")

    case Alerts.emit_system("system.dispatch.prewarm_blocked",
           reason: reason,
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        %{state | prewarm_blocked_alert_active: true, prewarm_blocked_alert_resolution_emitted: false}

      {:error, _reason} ->
        state
    end
  end

  @doc false
  @spec clear_prewarm_blocked_alert(State.t()) :: State.t()
  @spec clear_prewarm_blocked_alert(State.t(), term()) :: State.t()
  def clear_prewarm_blocked_alert(state, phase \\ :ready)

  def clear_prewarm_blocked_alert(%State{prewarm_blocked_alert_resolution_emitted: true} = state, _phase),
    do: %{state | prewarm_blocked_alert_active: false, prewarm_hold_since_ms: nil}

  def clear_prewarm_blocked_alert(%State{} = state, phase) do
    active? =
      state.prewarm_blocked_alert_active or
        AlertFeed.active_system_attention?("system.dispatch.prewarm_blocked")

    if active? do
      case Alerts.emit_system("system.dispatch.prewarm_blocked.resolved",
             reason: prewarm_resolution_reason(phase),
             needs_attention: false,
             severity: "info"
           ) do
        :ok ->
          %{state | prewarm_blocked_alert_active: false, prewarm_blocked_alert_resolution_emitted: true, prewarm_hold_since_ms: nil}

        {:error, _reason} ->
          state
      end
    else
      %{state | prewarm_blocked_alert_active: false, prewarm_blocked_alert_resolution_emitted: true, prewarm_hold_since_ms: nil}
    end
  end

  defp prewarm_blocked_reason(:building) do
    "Prewarm build is running; fleet dispatch is paused until the shared base becomes ready. " <>
      "The monitored build is expected to clear this condition automatically."
  end

  defp prewarm_blocked_reason(:checking) do
    "Prewarm remote freshness probe is running; fleet dispatch is paused until it completes. " <>
      "A bounded dispatch watchdog will release the gate for cold-clone fallback if the probe stalls."
  end

  defp prewarm_blocked_reason(phase) do
    "Prewarm is #{phase}; fleet dispatch is paused until the shared base becomes ready or the bounded dispatch watchdog releases the gate."
  end

  defp prewarm_resolution_reason({:error, {:repo_base_dispatch_hold_stalled, phase}}) do
    "Prewarm #{phase} stalled; the bounded watchdog released the fleet dispatch gate for cold-clone fallback."
  end

  defp prewarm_resolution_reason({:error, reason}) do
    "Prewarm failed (#{inspect(reason)}); the fleet dispatch gate was released for cold-clone fallback."
  end

  defp prewarm_resolution_reason(_phase), do: "Shared prewarm is ready; fleet dispatch may resume."

  @doc false
  @spec emit_tracker_preflight_alert(State.t(), term()) :: State.t()
  def emit_tracker_preflight_alert(%State{} = state, reason) do
    TrackerHealth.log_tracker_preflight_error(reason)
    state = put_tracker_preflight_hold(state, reason)

    case tracker_preflight_alert_context(reason) do
      {:ok, signature, formatted_reason} ->
        emit_tracker_preflight_alert(state, signature, formatted_reason)

      :ignore ->
        state
    end
  end

  defp emit_tracker_preflight_alert(
         %State{tracker_preflight_alert_signature: previous_signature} = state,
         signature,
         formatted_reason
       ) do
    if previous_signature == signature do
      state
    else
      message =
        "GitHub tracker authentication preflight failed; fleet dispatch is paused. Cause: " <>
          "#{formatted_reason} This condition is expected to clear automatically once tracker authentication succeeds."

      case Alerts.emit_system("system.tracker.auth_preflight_failed",
             reason: message,
             needs_attention: true,
             severity: "warning"
           ) do
        :ok ->
          %{state | tracker_preflight_alert_signature: signature, tracker_preflight_alert_resolution_emitted: false}

        {:error, _reason} ->
          state
      end
    end
  end

  @doc false
  @spec clear_tracker_preflight_alert(State.t()) :: State.t()
  def clear_tracker_preflight_alert(%State{tracker_preflight_alert_resolution_emitted: true} = state),
    do: %{state | tracker_preflight_alert_signature: nil, dispatch_hold: nil}

  def clear_tracker_preflight_alert(%State{} = state) do
    active? =
      not is_nil(state.tracker_preflight_alert_signature) or
        AlertFeed.active_system_attention?("system.tracker.auth_preflight_failed")

    if active? do
      case Alerts.emit_system("system.tracker.auth_preflight_failed.resolved",
             reason: "GitHub tracker authentication preflight recovered; fleet dispatch may resume.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok ->
          %{
            state
            | tracker_preflight_alert_signature: nil,
              tracker_preflight_alert_resolution_emitted: true,
              dispatch_hold: nil
          }

        {:error, _reason} ->
          %{state | dispatch_hold: nil}
      end
    else
      %{
        state
        | tracker_preflight_alert_signature: nil,
          tracker_preflight_alert_resolution_emitted: true,
          dispatch_hold: nil
      }
    end
  end

  defp put_tracker_preflight_hold(%State{} = state, reason) do
    detail = tracker_preflight_detail(reason)

    held_since_ms =
      case state.dispatch_hold do
        %{reason: :tracker_preflight, held_since_ms: held_since_ms} -> held_since_ms
        _other -> System.monotonic_time(:millisecond)
      end

    %{
      state
      | dispatch_hold: %{
          reason: :tracker_preflight,
          detail: detail,
          held_since_ms: held_since_ms
        }
    }
  end

  defp tracker_preflight_detail({:github_auth_preflight_failed, %{reason: :local_hold, detail: %{hold: %{reason: reason, resource: resource}}}}),
    do: "#{reason} (#{resource})"

  defp tracker_preflight_detail({:github_auth_preflight_failed, diagnostic}) when is_map(diagnostic) do
    Map.get(diagnostic, :reason) || Map.get(diagnostic, "reason") || :unknown
  end

  defp tracker_preflight_detail(reason) when is_atom(reason), do: reason

  defp tracker_preflight_detail(_reason), do: :unknown

  defp tracker_preflight_alert_context({:github_auth_preflight_failed, diagnostic} = reason)
       when is_map(diagnostic) do
    formatted_reason = AuthPreflight.format_auth_preflight_error(reason)
    classification = Map.get(diagnostic, :reason) || Map.get(diagnostic, "reason") || :unknown
    repo = Map.get(diagnostic, :repo) || Map.get(diagnostic, "repo") || "unknown"

    {:ok, "github-auth:#{classification}:#{repo}", "#{formatted_reason} (classification=#{classification})"}
  end

  defp tracker_preflight_alert_context(:missing_github_token) do
    {:ok, "github-auth:missing_github_token", ":missing_github_token (classification=missing_github_token)"}
  end

  defp tracker_preflight_alert_context(_reason), do: :ignore

  defp maybe_log_base_error({:error, reason}),
    do: Logger.warning("prewarm base unavailable (#{inspect(reason)}); dispatching via cold clone")

  defp maybe_log_base_error(_phase), do: :ok

  # A silent indefinite hold is the core defect behind #1404: with the warm base
  # warming (or failing to rebuild), every poll tick held dispatch and nothing
  # was logged, so an operator saw an idle fleet instead of a gated one. Count
  # consecutive hold ticks and emit one `aiur_perf prewarm_hold` line at most
  # once per `@prewarm_hold_log_interval_ticks`; the counter resets as soon as
  # the gate lets a tick through, so the interval measures back-to-back holds.
  @doc false
  @spec log_prewarm_hold(State.t(), term()) :: State.t()
  def log_prewarm_hold(%State{} = state, phase), do: log_prewarm_hold(state, phase, &Logger.info/1)

  @doc false
  @spec log_prewarm_hold(State.t(), term(), (String.t() -> term())) :: State.t()
  def log_prewarm_hold(%State{prewarm_hold_ticks: ticks} = state, phase, log_fun)
      when is_function(log_fun, 1) do
    next_ticks = ticks + 1
    state = %{state | prewarm_hold_ticks: next_ticks}

    if rem(next_ticks, @prewarm_hold_log_interval_ticks) == 1 do
      log_fun.("aiur_perf prewarm_hold surface=dispatch phase=#{inspect(phase)}")
    end

    state
  end
end
