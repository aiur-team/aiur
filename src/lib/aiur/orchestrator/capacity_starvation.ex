defmodule Aiur.Orchestrator.CapacityStarvation do
  @moduledoc """
  Detects sustained fleet under-utilization from the orchestrator's poll state.

  The detector deliberately excludes the zero-live halt case and resets while
  live agents or the adaptive envelope are ramping. It emits once per sustained
  incident, then rearms only after the starvation condition clears.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchPolicy, Slots, State}
  alias Aiur.Orchestrator.CapacityStarvation.Alert

  @debounce_cycles 3
  @low_load_fraction 0.5

  @type sample :: %{
          required(:load) => number() | :unavailable,
          required(:target) => number() | nil,
          required(:schedulers) => pos_integer(),
          required(:prewarm_hold?) => boolean(),
          required(:admission_constraint) => atom() | nil
        }

  @spec observe(State.t(), [Issue.t()], sample(), keyword()) :: State.t()
  def observe(%State{} = state, issues, sample, opts \\ [])
      when is_list(issues) and is_map(sample) and is_list(opts) do
    snapshot = snapshot(state, issues, sample)
    detector = state.capacity_starvation

    cond do
      not starvation_base?(state, snapshot) ->
        clear_incident(state, detector, opts)

      detector.alert_active? ->
        put_detector(state, track_sample(detector, snapshot))

      ramping?(detector, snapshot) or not envelope_available_or_static?(detector, snapshot) ->
        put_detector(state, track_sample(detector, snapshot, 0, false))

      true ->
        advance_debounce(state, snapshot, detector, opts)
    end
  end

  defp snapshot(state, issues, sample) do
    ready = ready_issues(state, issues)
    authorized = Enum.filter(ready, &DispatchPolicy.issue_dispatch_authorized?/1)
    ready_count = length(ready)
    live_agents = State.active_running_count(state.running)
    configured_cap = Slots.max_concurrent_agent_limit(state)
    effective_cap = Slots.effective_concurrent_agent_limit(state)

    %{
      state: state,
      authorized: authorized,
      ready_count: ready_count,
      authorization_denials: ready_count - length(authorized),
      live_agents: live_agents,
      occupied_slots: live_agents + State.reserved_paused_running_count(state.running),
      configured_cap: configured_cap,
      effective_cap: effective_cap,
      load: Map.get(sample, :load, :unavailable),
      target: Map.get(sample, :target),
      schedulers: Map.get(sample, :schedulers),
      prewarm_hold?: Map.get(sample, :prewarm_hold?) == true,
      admission_constraint: Map.get(sample, :admission_constraint)
    }
  end

  defp ready_issues(state, issues) do
    active_states = DispatchPolicy.active_state_set()
    terminal_states = DispatchPolicy.terminal_state_set()

    Enum.filter(issues, fn
      %Issue{id: id} = issue ->
        DispatchPolicy.ready_dispatch_demand?(issue, active_states, terminal_states) and
          not Map.has_key?(state.running, id) and not MapSet.member?(state.claimed, id)

      _ ->
        false
    end)
  end

  defp starvation_base?(%State{globally_paused: true}, _snapshot), do: false

  defp starvation_base?(_state, snapshot) do
    snapshot.live_agents > 0 and
      snapshot.ready_count > snapshot.live_agents and
      low_load?(snapshot.load, snapshot.target, snapshot.schedulers)
  end

  defp low_load?(load, target, schedulers)
       when is_number(load) and is_number(target) and target > 0 and is_integer(schedulers) and
              schedulers > 0 do
    load <= target * schedulers * @low_load_fraction
  end

  defp low_load?(_load, _target, _schedulers), do: false

  defp ramping?(%{last_live_agents: previous}, %{live_agents: current})
       when is_integer(previous),
       do: previous != current

  defp ramping?(_detector, _snapshot), do: false

  defp envelope_available_or_static?(_detector, %{effective_cap: cap, occupied_slots: occupied})
       when cap > occupied,
       do: true

  defp envelope_available_or_static?(%{last_effective_cap: cap}, %{effective_cap: cap}),
    do: true

  defp envelope_available_or_static?(_detector, _snapshot), do: false

  defp advance_debounce(state, snapshot, detector, opts) do
    consecutive_cycles = detector.consecutive_cycles + 1
    detector = track_sample(detector, snapshot, consecutive_cycles)

    if consecutive_cycles >= @debounce_cycles do
      case Alert.open(snapshot, detector, @debounce_cycles, opts) do
        {:error, _reason} -> put_detector(state, detector)
        _success -> put_detector(state, %{detector | alert_active?: true})
      end
    else
      put_detector(state, detector)
    end
  end

  defp clear_incident(state, %{alert_active?: true} = detector, opts) do
    case Alert.resolve(opts) do
      {:error, _reason} -> put_detector(state, detector)
      _success -> put_detector(state, reset_detector())
    end
  end

  defp clear_incident(state, _detector, _opts), do: put_detector(state, reset_detector())

  defp track_sample(detector, snapshot, consecutive_cycles \\ nil, provisioning_lag \\ nil) do
    %{
      detector
      | consecutive_cycles: consecutive_cycles || detector.consecutive_cycles,
        provisioning_lag?: next_provisioning_lag(detector, snapshot, provisioning_lag),
        last_live_agents: snapshot.live_agents,
        last_effective_cap: snapshot.effective_cap
    }
  end

  defp next_provisioning_lag(_detector, _snapshot, override) when is_boolean(override), do: override

  defp next_provisioning_lag(detector, snapshot, _override) do
    detector.provisioning_lag? || provisioning_lag?(detector, snapshot)
  end

  defp provisioning_lag?(
         %{last_live_agents: live, last_effective_cap: previous_cap},
         %{live_agents: live, effective_cap: effective_cap, occupied_slots: occupied}
       )
       when is_integer(live) and is_integer(previous_cap),
       do: effective_cap > previous_cap and effective_cap > occupied

  defp provisioning_lag?(_detector, _snapshot), do: false

  defp put_detector(%State{capacity_starvation: detector} = state, detector), do: state
  defp put_detector(state, detector), do: %{state | capacity_starvation: detector}

  defp reset_detector do
    %{
      consecutive_cycles: 0,
      alert_active?: false,
      provisioning_lag?: false,
      last_live_agents: nil,
      last_effective_cap: nil
    }
  end
end
