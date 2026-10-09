defmodule Aiur.Orchestrator.PressureAdmission do
  @moduledoc false

  alias Aiur.{Config, SystemPressure}
  alias Aiur.Orchestrator.{DispatchPolicy, Slots, State, SustainedLoad}

  @spec sample() :: map()
  def sample do
    pressure = SystemPressure.cpu()
    fallback? = pressure == :unavailable

    %{
      cpu_pressure: pressure,
      pressure_threshold: Config.max_cpu_pressure(),
      pressure_target: Config.target_cpu_pressure(),
      load: DispatchPolicy.read_load(Config.max_load_average(), Config.target_load_average()),
      target: if(fallback?, do: Config.target_load_average(), else: nil),
      load_threshold: if(fallback?, do: Config.max_load_average(), else: nil),
      run_queue_threshold: if(fallback?, do: Config.run_queue_threshold(), else: nil),
      cpu_snapshot: DispatchPolicy.read_cpu(Config.target_load_average(), Config.run_queue_threshold(), Config.max_load_average())
    }
  end

  @spec cpu_gate(map()) :: :dispatch | {:hold, map()}
  def cpu_gate(%{cpu_pressure: %{avg60: value}, pressure_threshold: threshold}) do
    if is_number(threshold) and value > threshold,
      do: {:hold, %{signal: :cpu_pressure, measured: value, threshold: threshold}},
      else: :dispatch
  end

  def cpu_gate(%{cpu_pressure: :unavailable} = probes) do
    if Map.get(probes, :cpu_headroom, :unavailable) == :unavailable, do: raw_load_gate(probes), else: fallback_cpu_gate(probes)
  end

  def cpu_gate(probes), do: fallback_cpu_gate(probes)

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
    state = reset_signal(state, :cpu_pressure)
    previous = state.load_envelope_state
    count = if fresh?, do: SustainedLoad.count(pressure, target, 1, previous), else: Map.get(previous, :overload_samples, 0)
    effective = state.effective_concurrent_agents || Slots.max_concurrent_agent_limit(state)
    {next, decreased_at} = adjust(effective, previous.last_decrease_ms, pressure, target, count, now_ms, fresh?, Slots.max_concurrent_agent_limit(state))
    snapshot = if is_map(probes.cpu_snapshot), do: probes.cpu_snapshot, else: nil

    %{
      state
      | effective_concurrent_agents: next,
        load_envelope_state: Map.merge(previous, %{last_decrease_ms: decreased_at, overload_samples: count, bootstrap_complete?: true, signal: :cpu_pressure, cpu_snapshot: snapshot})
    }
  end

  def update(state, probes, now_ms, demand?, fresh?) do
    state = reset_signal(state, :load)
    next = DispatchPolicy.update_load_envelope(state, if(fresh?, do: probes.load, else: :unavailable), probes.target, probes.schedulers, now_ms, probes.cpu_snapshot, demand?)
    put_in(next.load_envelope_state[:signal], :load)
  end

  defp reset_signal(state, signal) do
    if Map.get(state.load_envelope_state, :signal, signal) == signal,
      do: state,
      else: put_in(state.load_envelope_state[:overload_samples], 0)
  end

  defp adjust(_effective, _last, _pressure, nil, _count, _now, _fresh?, limit), do: {limit, nil}
  defp adjust(effective, last, _pressure, _target, _count, _now, false, limit), do: {min(effective, limit), last}

  defp adjust(effective, last, pressure, target, count, now, true, limit) do
    cond do
      pressure > target -> SustainedLoad.decrease(min(effective, limit), last, %{overload_samples: count, now_ms: now, cooldown_ms: Config.load_cooldown_seconds() * 1_000})
      pressure < target * 0.8 -> {min(effective + Config.load_ramp_step(), limit), last}
      true -> {min(effective, limit), last}
    end
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
    Map.take(probes, [:cpu_pressure, :pressure_threshold, :pressure_target, :memory_mb, :memory_threshold_mb])
  end
end
