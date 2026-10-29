defmodule Aiur.Orchestrator.PressureAdmission do
  @moduledoc false

  alias Aiur.{Config, SystemCgroup, SystemPressure}
  alias Aiur.Orchestrator.{DispatchPolicy, EnvelopeResume, Slots, State, SustainedLoad}

  @priority_bypass_pressure_ceiling 90.0

  @spec sample() :: map()
  def sample do
    quota = SystemCgroup.cpu_quota()
    cgroup_pressure = if is_number(quota), do: SystemCgroup.cpu_pressure(), else: :unavailable
    pressure = if is_number(quota), do: cgroup_pressure, else: SystemPressure.cpu()
    fallback? = pressure == :unavailable

    %{
      cpu_pressure: pressure,
      cpu_pressure_source: if(is_number(quota), do: :cgroup, else: :host),
      cpu_quota: quota,
      pressure_threshold: Config.max_cpu_pressure(),
      pressure_target: Config.target_cpu_pressure(),
      load: quota_load(quota),
      schedulers: max(1, quota_schedulers(quota)),
      target: if(fallback?, do: Config.target_load_average(), else: nil),
      load_threshold: if(fallback?, do: Config.max_load_average(), else: nil),
      run_queue_threshold: if(fallback?, do: Config.run_queue_threshold(), else: nil),
      cpu_snapshot: if(is_number(quota), do: :unavailable, else: DispatchPolicy.read_cpu(Config.target_load_average(), Config.run_queue_threshold(), Config.max_load_average()))
    }
  end

  defp quota_schedulers(quota) when is_number(quota), do: floor(quota)
  defp quota_schedulers(_quota), do: System.schedulers_online()

  defp quota_load(quota) when is_number(quota), do: :unavailable
  defp quota_load(_quota), do: DispatchPolicy.read_load(Config.max_load_average(), Config.target_load_average())

  @spec cpu_gate(map()) :: :dispatch | {:hold, map()}
  def cpu_gate(%{cpu_pressure: %{avg60: value}, pressure_threshold: threshold}) do
    if is_number(threshold) and value > threshold,
      do: {:hold, %{signal: :cpu_pressure, measured: value, threshold: threshold}},
      else: :dispatch
  end

  def cpu_gate(%{cpu_pressure: :unavailable} = probes) do
    cond do
      is_number(Map.get(probes, :cpu_quota)) -> :dispatch
      Map.get(probes, :cpu_headroom, :unavailable) == :unavailable -> raw_load_gate(probes)
      true -> fallback_cpu_gate(probes)
    end
  end

  def cpu_gate(probes), do: fallback_cpu_gate(probes)

  @doc false
  @spec priority_bypass_allowed?(map()) :: boolean()
  def priority_bypass_allowed?(sample) when is_map(sample) do
    pressure = get_in(sample, [:cpu_pressure, :avg60])
    load = Map.get(sample, :load, :unavailable)
    threshold = Map.get(sample, :load_threshold) || Config.max_load_average()
    schedulers = Map.get(sample, :schedulers)

    cond do
      is_number(pressure) ->
        pressure <= @priority_bypass_pressure_ceiling

      is_number(load) and is_number(threshold) and threshold > 0 and is_integer(schedulers) and schedulers > 0 ->
        load <= threshold * schedulers

      true ->
        false
    end
  end

  def priority_bypass_allowed?(_sample), do: false

  defp raw_load_gate(probes) do
    case DispatchPolicy.load_gate(probes.load, probes.load_threshold, probes.schedulers) do
      :hold -> {:hold, %{signal: :load, measured: probes.load, threshold: probes.load_threshold * probes.schedulers}}
      :dispatch -> :dispatch
    end
  end

  defp fallback_cpu_gate(probes) do
    headroom = Map.get(probes, :cpu_headroom, :unavailable)
    run_queue = DispatchPolicy.run_queue_admission_reason(probes.runnable, probes.schedulers, probes.run_queue_threshold, headroom)

    if run_queue == :dispatch,
      do: DispatchPolicy.load_admission_reason(probes.load, probes.load_threshold, probes.schedulers, headroom),
      else: run_queue
  end

  @spec constraints(map()) :: [:dispatch | {:hold, map()}]
  def constraints(probes) do
    headroom = Map.get(probes, :cpu_headroom, :unavailable)

    if is_map(probes[:cpu_pressure]) or (Map.has_key?(probes, :cpu_pressure) and headroom == :unavailable) do
      [cpu_gate(probes)]
    else
      [
        DispatchPolicy.load_admission_reason(probes.load, probes.load_threshold, probes.schedulers, headroom),
        DispatchPolicy.run_queue_admission_reason(probes.runnable, probes.schedulers, probes.run_queue_threshold, headroom)
      ]
    end
  end

  @spec update(State.t(), map(), integer(), boolean(), boolean()) :: State.t()
  def update(state, %{cpu_pressure: %{avg60: pressure}} = probes, now_ms, _demand?, fresh?) do
    target = probes.pressure_target
    soft_pressure = discount_niced_background(pressure, Map.get(probes, :cpu_headroom, :unavailable))
    state = reset_signal(state, :cpu_pressure)
    previous = EnvelopeResume.validate(state.load_envelope_state, target, probes.schedulers)
    count = if fresh?, do: SustainedLoad.count(soft_pressure, target, 1, previous), else: Map.get(previous, :overload_samples, 0)
    effective = state.effective_concurrent_agents || Slots.max_concurrent_agent_limit(state)
    bootstrap? = Map.get(previous, :bootstrap_complete?, false)

    {next, decreased_at} =
      if bootstrap_hold?(effective, previous, target, fresh?),
        do: {1, nil},
        else: adjust(effective, previous, soft_pressure, target, count, now_ms, fresh?, %{limit: Slots.max_concurrent_agent_limit(state), used_slots: Slots.used_slots(state)})

    previous = if fresh?, do: EnvelopeResume.observe(previous, Slots.used_slots(state), next, effective, soft_pressure, target, count), else: previous
    snapshot = if is_map(probes.cpu_snapshot), do: probes.cpu_snapshot, else: nil

    %{
      state
      | effective_concurrent_agents: next,
        load_envelope_state: Map.merge(previous, %{last_decrease_ms: decreased_at, overload_samples: count, bootstrap_complete?: bootstrap? or fresh?, signal: :cpu_pressure, cpu_snapshot: snapshot})
    }
  end

  def update(state, probes, now_ms, demand?, fresh?) do
    state = reset_signal(state, :load)
    next = DispatchPolicy.update_load_envelope(state, if(fresh?, do: probes.load, else: :unavailable), probes.target, probes.schedulers, now_ms, probes.cpu_snapshot, demand?)
    put_in(next.load_envelope_state[:signal], :load)
  end

  # Niced CPU outside the daemon and registered fleet-agent trees (including
  # Executor review work) is treated as reclaimable by the fleet. cpu_gate/1
  # still enforces raw host PSI as the hard admission ceiling.
  defp discount_niced_background(pressure, %{background_percent: background}) when is_number(background),
    do: max(0.0, pressure - background)

  defp discount_niced_background(pressure, _headroom), do: pressure

  defp reset_signal(state, signal) do
    if Map.get(state.load_envelope_state, :signal, signal) == signal,
      do: state,
      else: put_in(state.load_envelope_state[:overload_samples], 0)
  end

  defp bootstrap_hold?(effective, previous, target, fresh?),
    do: fresh? and is_number(target) and effective == 1 and is_nil(previous.last_decrease_ms) and not Map.get(previous, :bootstrap_complete?, false)

  defp adjust(_effective, _previous, _pressure, nil, _count, _now, _fresh?, %{limit: limit}), do: {limit, nil}
  defp adjust(effective, previous, _pressure, _target, _count, _now, false, %{limit: limit}), do: {min(effective, limit), previous.last_decrease_ms}

  defp adjust(effective, previous, pressure, target, count, now, true, %{limit: limit, used_slots: used_slots}) do
    last = previous.last_decrease_ms

    cond do
      pressure > target ->
        SustainedLoad.decrease(min(effective, limit), last, %{
          overload_samples: count,
          now_ms: now,
          cooldown_ms: Config.load_cooldown_seconds() * 1_000,
          running_floor: max(div(used_slots + 1, 2), Map.get(previous, :safe_level, 1))
        })

      pressure < target * 0.8 ->
        ramp(effective, previous, pressure, target, limit)

      true ->
        {min(effective, limit), last}
    end
  end

  defp ramp(effective, previous, pressure, target, limit) do
    resume = EnvelopeResume.level(previous, target)
    fast? = is_integer(resume) and (effective < resume or (not Map.get(previous, :sustained_decrease?, false) and is_nil(previous.last_decrease_ms) and pressure < target / 2))
    ceiling = if is_integer(resume) and effective < resume, do: min(resume, limit), else: limit
    next = if fast?, do: min(min(effective * 2, effective + 3), ceiling), else: min(effective + Config.load_ramp_step(), limit)
    {next, if(next == limit, do: nil, else: previous.last_decrease_ms)}
  end

  @spec envelope_signal(map()) :: {number() | :unavailable, number() | nil, pos_integer()}
  def envelope_signal(%{cpu_pressure: %{avg60: value}, pressure_target: target}), do: {value, target, 1}

  def envelope_signal(probes),
    do: {Aiur.SystemLoad.gate_signal(probes.load, Map.get(probes, :cpu_headroom, :unavailable), probes.schedulers), probes.target, probes.schedulers}

  @spec envelope_context(map()) :: map()
  def envelope_context(sample) do
    {value, target, schedulers} = envelope_signal(sample)
    pressure? = is_map(sample[:cpu_pressure])

    %{
      load: value,
      target: target,
      schedulers: schedulers,
      metric: if(pressure?, do: "CPU PSI some avg60 (%)", else: "load"),
      ramp_threshold: if(pressure? and is_number(target), do: target * 0.8, else: target),
      threshold: if(is_number(target) and is_integer(schedulers), do: target * schedulers, else: :unavailable)
    }
  end

  @spec status_sample(map()) :: map()
  def status_sample(probes) do
    Map.take(probes, [:cpu_pressure, :cpu_pressure_source, :pressure_threshold, :pressure_target, :memory_mb, :memory_threshold_mb, :cgroup_memory_threshold])
  end
end
