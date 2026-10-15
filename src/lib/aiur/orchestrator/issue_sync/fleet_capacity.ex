defmodule Aiur.Orchestrator.IssueSync.FleetCapacity do
  @moduledoc """
  Tracks fleet-wide capacity starvation and recovery.
  """

  alias Aiur.AlertFeed
  alias Aiur.Alerts
  alias Aiur.CodingAgent
  alias Aiur.Config
  alias Aiur.Orchestrator.IssueSync.CapacityConstraints
  alias Aiur.Orchestrator.PressureAdmission
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.PollCadence

  @doc false
  @spec sync_fleet_capacity_starved_alert(State.t(), list(), integer()) :: State.t()
  def sync_fleet_capacity_starved_alert(%State{} = state, issues, now_ms)
      when is_list(issues) and is_integer(now_ms) do
    context = fleet_capacity_context(state, issues)

    if fleet_capacity_starved?(context) do
      sync_fleet_capacity_starvation(state, context, now_ms)
    else
      clear_fleet_capacity_starvation(state)
    end
  end

  def sync_fleet_capacity_starved_alert(%State{} = state, _issues, _now_ms), do: state

  @spec sync_fleet_capacity_starved_alert(State.t(), list()) :: State.t()
  def sync_fleet_capacity_starved_alert(%State{} = state, issues) when is_list(issues),
    do: sync_fleet_capacity_starved_alert(state, issues, System.monotonic_time(:millisecond))

  def sync_fleet_capacity_starved_alert(%State{} = state, _issues), do: state

  defp fleet_capacity_context(state, issues) do
    sample = state.dispatch_capacity_sample
    constraint_entries = CapacityConstraints.capacity_constraint_entries(state, issues)
    ready_issues = CapacityConstraints.ready_dispatch_issues(state, issues)
    live_count = State.active_running_count(state.running)
    effective_cap = Slots.effective_concurrent_agent_limit(state)

    Map.merge(PressureAdmission.envelope_context(sample), %{
      state: state,
      ready_count: length(ready_issues),
      live_count: live_count,
      occupied_slots: Slots.used_slots(state),
      effective_cap: effective_cap,
      configured_cap: Slots.max_concurrent_agent_limit(state),
      constraints: Enum.map(constraint_entries, & &1.identity),
      binding_constraint: selected_binding_constraint(state, constraint_entries, ready_issues)
    })
  end

  # The fleet is starved only when ready work is queued AND dispatch is
  # genuinely held: a hard capacity gate is binding, or the fleet is at its
  # dispatch envelope (no free admission slots) while the envelope is not
  # mid-ramp, or the fleet is below a fully-ramped envelope that should already
  # have been filled. The below-target dispatch ramp — a fleet below or at a
  # widening envelope with agents still starting — is the intended behavior,
  # not starvation (#2447).
  defp fleet_capacity_starved?(context) do
    not context.state.globally_paused and context.ready_count > 0 and
      (hard_capacity_gate?(context) or fleet_at_capacity_bound?(context))
  end

  # A resource or load gate holding dispatch while ready work queues. These are
  # the genuine-starvation cases (acceptance #2): load, memory, FD, build,
  # run-queue, provider, budget, per-state, worker, or model-fallback limits.
  defp hard_capacity_gate?(context) do
    is_binary(context.binding_constraint) or context.constraints != []
  end

  # The fleet has no free admission slots within the current dispatch envelope
  # (the envelope is the binding constraint) and the envelope is not widening,
  # or the fleet is below a fully-ramped envelope that should have been filled.
  # A below-envelope fleet during a below-target ramp is the intended ramp.
  defp fleet_at_capacity_bound?(context) do
    cond do
      context.occupied_slots >= context.effective_cap -> not envelope_ramping?(context)
      context.effective_cap >= context.configured_cap -> true
      true -> false
    end
  end

  # The adaptive envelope widens while load stays at/below target and effective
  # capacity is still below the ceiling; that below-target state is the ramp.
  defp envelope_ramping?(%{effective_cap: effective, configured_cap: configured} = context)
       when is_integer(effective) and effective > 0 and is_integer(configured) and configured > 0 do
    effective < configured and load_below_or_at_target?(context)
  end

  defp envelope_ramping?(_context), do: false

  defp load_below_or_at_target?(%{load: load, ramp_threshold: target, schedulers: schedulers} = context)
       when is_number(load) and is_number(target) and target > 0 and is_integer(schedulers) and schedulers > 0,
       do: if(context.metric == "CPU PSI some avg60 (%)", do: load < target, else: load <= target * schedulers)

  defp load_below_or_at_target?(_context), do: false

  defp sync_fleet_capacity_starvation(state, context, now_ms) do
    starvation = state.fleet_capacity_starvation

    if is_integer(starvation[:effective_cap]) and starvation[:effective_cap] != context.effective_cap do
      put_fleet_capacity_starvation(state, now_ms, starvation[:alert_active] || false, context.effective_cap)
    else
      since_ms = starvation[:since_ms] || now_ms

      if starvation[:alert_active] or now_ms - since_ms < fleet_capacity_starvation_alert_after_ms(state) do
        put_fleet_capacity_starvation(state, since_ms, starvation[:alert_active] || false, context.effective_cap)
      else
        emit_fleet_capacity_starvation(state, context, since_ms)
      end
    end
  end

  # Deliberately cadence-derived, and deliberately the *effective* cadence
  # rather than the configured one. Fleet starvation is only observable on a
  # poll tick, and starvation means no agent is running — which is exactly when
  # idle backoff widens the tick. A de-bounce shorter than one observation cycle
  # is no de-bounce at all: it alerts on the first observation. Reading
  # `poll_interval_ms` (the base) made that true the moment `idle_widen_factor`
  # went above 1.0. The cost is an alert that arrives one widened cycle after
  # starvation begins; the alternative is an alert that fires before the
  # dispatcher has had a chance to clear it.
  #
  # Routed through `PollCadence` rather than used raw so the de-bounce inherits
  # the same bound on a remote `X-Poll-Interval` as every other cadence-derived
  # threshold: a server that asks Aiur to poll rarely must not also be able to
  # silence its starvation alert.
  defp fleet_capacity_starvation_alert_after_ms(%State{effective_poll_interval_ms: effective_ms})
       when is_integer(effective_ms) and effective_ms > 0 do
    PollCadence.effective_interval_ms(class: :dispatch, effective_interval_ms: effective_ms)
  end

  defp fleet_capacity_starvation_alert_after_ms(%State{poll_interval_ms: poll_interval_ms})
       when is_integer(poll_interval_ms) and poll_interval_ms > 0,
       do: poll_interval_ms

  defp fleet_capacity_starvation_alert_after_ms(_state),
    do: Config.capacity_starvation_alert_after_seconds() * 1_000

  defp emit_fleet_capacity_starvation(state, context, since_ms) do
    case Alerts.emit_system("system.fleet.capacity.starved",
           reason: fleet_capacity_starvation_reason(context),
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        state
        |> Map.put(:fleet_capacity_starvation_resolution_emitted, false)
        |> put_fleet_capacity_starvation(since_ms, true, context.effective_cap)

      {:error, _reason} ->
        put_fleet_capacity_starvation(state, since_ms, false, context.effective_cap)
    end
  end

  defp fleet_capacity_starvation_reason(context) do
    "Ready tickets=#{context.ready_count}, live agents=#{context.live_count}, " <>
      "#{context.metric}=#{inspect(context.load)}/#{inspect(context.threshold)}, effective cap=#{context.effective_cap}, " <>
      "configured cap=#{context.configured_cap}; binding constraint=#{fleet_capacity_constraint(context)}."
  end

  defp fleet_capacity_constraint(%{binding_constraint: constraint}) when is_binary(constraint), do: constraint

  defp fleet_capacity_constraint(%{occupied_slots: occupied, live_count: live}) when occupied > live,
    do: "paused agent reservations (occupied slots=#{occupied})"

  defp fleet_capacity_constraint(%{effective_cap: effective, configured_cap: configured, live_count: live})
       when effective <= live and effective < configured,
       do: "adaptive envelope (effective cap=#{effective})"

  defp fleet_capacity_constraint(%{effective_cap: effective, configured_cap: configured, live_count: live})
       when effective <= live and effective == configured,
       do: "configured concurrency ceiling (cap=#{configured})"

  defp fleet_capacity_constraint(_context), do: "no binding constraint identified"

  defp selected_binding_constraint(%State{prewarm_blocked_alert_active: true}, entries, _ready_issues) do
    entries |> Enum.find(&(&1.identity == "build")) |> then(&(&1 && &1.detail))
  end

  defp selected_binding_constraint(%State{capacity_hold: %{signal: signal}}, entries, _ready_issues) do
    entries
    |> Enum.find(&(&1.identity == capacity_hold_identity(signal)))
    |> then(&(&1 && &1.detail))
  end

  defp selected_binding_constraint(state, entries, ready_issues) do
    case Enum.filter(entries, &String.starts_with?(&1.identity, "per-state:")) do
      [_ | _] = per_state_entries -> Enum.map_join(per_state_entries, "; ", & &1.detail)
      _ -> model_fallback_constraint(state, ready_issues) || worker_capacity_constraint(state, ready_issues)
    end
  end

  defp model_fallback_constraint(%State{model_fallback_waiting: waiting}, ready_issues) do
    waiting_count = Enum.count(ready_issues, &MapSet.member?(waiting, &1.id))

    if waiting_count > 0 do
      "dispatch authorization denials (all fallback backends usage-limited for #{waiting_count} ready ticket(s))"
    end
  end

  defp worker_capacity_constraint(state, ready_issues) do
    if Enum.any?(ready_issues, &(CodingAgent.backend_for(&1) |> CodingAgent.remote_worker?())) and
         not Slots.worker_slots_available?(state) do
      "worker-host capacity (all SSH worker slots are occupied)"
    end
  end

  defp capacity_hold_identity(:cpu_pressure), do: "cpu-pressure"
  defp capacity_hold_identity(:envelope), do: "load-envelope"
  defp capacity_hold_identity(:file_descriptors), do: "fd"
  defp capacity_hold_identity(:run_queue), do: "run-queue"
  defp capacity_hold_identity(signal), do: to_string(signal)

  defp clear_fleet_capacity_starvation(%State{fleet_capacity_starvation_resolution_emitted: true} = state),
    do: put_fleet_capacity_starvation(state, nil, false, nil)

  defp clear_fleet_capacity_starvation(%State{} = state) do
    starvation = state.fleet_capacity_starvation

    active? = starvation[:alert_active] or AlertFeed.active_system_attention?("system.fleet.capacity.starved")

    if active? do
      case Alerts.emit_system("system.fleet.capacity.starved.resolved",
             reason: "Fleet capacity is no longer starved.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok ->
          state
          |> Map.put(:fleet_capacity_starvation_resolution_emitted, true)
          |> put_fleet_capacity_starvation(nil, false, nil)

        {:error, _reason} ->
          state
      end
    else
      state
      |> Map.put(:fleet_capacity_starvation_resolution_emitted, true)
      |> put_fleet_capacity_starvation(nil, false, nil)
    end
  end

  defp put_fleet_capacity_starvation(state, since_ms, alert_active, effective_cap) do
    %{state | fleet_capacity_starvation: %{since_ms: since_ms, alert_active: alert_active, effective_cap: effective_cap}}
  end
end
