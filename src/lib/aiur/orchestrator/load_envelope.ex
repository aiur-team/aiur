defmodule Aiur.Orchestrator.LoadEnvelope do
  @moduledoc false

  alias Aiur.{Config, SystemCpu, SystemLoad}
  alias Aiur.Orchestrator.{EnvelopeResume, Slots, State, SustainedLoad}

  @cpu_headroom_ramp_max 3
  @reclaimable_cpu_threshold 60.0

  @type envelope_options :: %{
          optional(:resume_level) => pos_integer() | nil,
          optional(:bootstrap_complete?) => boolean(),
          target: number() | nil,
          schedulers: pos_integer(),
          static_limit: pos_integer(),
          ramp_step: pos_integer(),
          cooldown_ms: non_neg_integer(),
          now_ms: integer(),
          cpu_headroom: SystemCpu.headroom() | :unavailable,
          queued_work?: boolean(),
          used_slots: non_neg_integer()
        }

  @spec load_envelope(
          integer() | nil,
          integer() | nil,
          number() | :unavailable,
          envelope_options()
        ) ::
          {pos_integer(), integer() | nil}
  def load_envelope(effective, last_decrease_ms, load, options) do
    {next, next_decrease_ms, _bootstrap_complete?} =
      load_envelope_state(
        effective,
        last_decrease_ms,
        load,
        Map.put_new(options, :bootstrap_complete?, true)
      )

    {next, next_decrease_ms}
  end

  defp load_envelope_state(_effective, _last_decrease_ms, _load, %{
         target: nil,
         static_limit: static_limit,
         bootstrap_complete?: bootstrap_complete?
       }),
       do: {static_limit, nil, bootstrap_complete?}

  # Existing workers need their occupied capacity restored before fresh admission.
  defp load_envelope_state(1, nil, _load, %{bootstrap_complete?: false, used_slots: occupied, static_limit: cap} = options) when occupied > 0,
    do: {min(max(occupied, Map.get(options, :resume_level) || 1), cap), nil, true}

  defp load_envelope_state(effective, last_decrease_ms, :unavailable, options) do
    next = normalize_load_envelope_limit(effective, options.static_limit)
    {next, last_decrease_ms, options.bootstrap_complete?}
  end

  defp load_envelope_state(1, nil, load, %{bootstrap_complete?: false}) when is_number(load),
    do: {1, nil, true}

  defp load_envelope_state(effective, last_decrease_ms, load, %{static_limit: static_limit} = options)
       when is_number(load) do
    effective = normalize_load_envelope_limit(effective, static_limit)
    adjust_load_envelope(effective, last_decrease_ms, load, options)
  end

  @spec update_load_envelope(
          State.t(),
          number() | :unavailable,
          number() | nil,
          pos_integer(),
          integer(),
          SystemCpu.snapshot() | :unavailable,
          boolean()
        ) :: State.t()
  def update_load_envelope(
        %State{} = state,
        load,
        target,
        schedulers,
        now_ms,
        cpu_snapshot,
        queued_work?
      ) do
    envelope_state = EnvelopeResume.validate(state.load_envelope_state, target, schedulers)
    cpu_headroom = SystemCpu.headroom(envelope_state.cpu_snapshot, cpu_snapshot)
    overload_samples = SustainedLoad.count(SystemLoad.gate_signal(load, cpu_headroom, schedulers), target, schedulers, envelope_state)

    {effective, last_decrease_ms, bootstrap_complete?} =
      load_envelope_state(
        state.effective_concurrent_agents,
        envelope_state.last_decrease_ms,
        load,
        %{
          target: target,
          resume_level: EnvelopeResume.level(envelope_state, target),
          sustained_decrease?: Map.get(envelope_state, :sustained_decrease?, false),
          overload_samples: overload_samples,
          schedulers: schedulers,
          static_limit: Slots.max_concurrent_agent_limit(state),
          ramp_step: Config.load_ramp_step(),
          cooldown_ms: Config.load_cooldown_seconds() * 1_000,
          now_ms: now_ms,
          cpu_headroom: cpu_headroom,
          queued_work?: queued_work?,
          used_slots: Slots.used_slots(state),
          bootstrap_complete?: Map.get(envelope_state, :bootstrap_complete?, false)
        }
      )

    envelope_state = EnvelopeResume.observe(envelope_state, Slots.used_slots(state), effective, state.effective_concurrent_agents, load, target, overload_samples)

    %{
      state
      | effective_concurrent_agents: effective,
        load_envelope_state:
          Map.merge(envelope_state, %{
            last_decrease_ms: last_decrease_ms,
            overload_samples: overload_samples,
            cpu_snapshot: next_cpu_snapshot(envelope_state.cpu_snapshot, cpu_snapshot),
            bootstrap_complete?: bootstrap_complete?
          })
    }
  end

  defp adjust_load_envelope(
         effective,
         last_decrease_ms,
         load,
         %{schedulers: schedulers} = options
       ) do
    load = SystemLoad.gate_signal(load, options.cpu_headroom, schedulers)

    if load <= options.target * schedulers and fast_recovery?(last_decrease_ms, options) do
      {next, next_decrease_ms} = widen(effective, last_decrease_ms, load, options, true)
      {next, next_decrease_ms, options.bootstrap_complete?}
    else
      {next, next_decrease_ms} =
        adjust_load_envelope_without_headroom(effective, last_decrease_ms, load, options)

      {next, next_decrease_ms, true}
    end
  end

  defp fast_recovery?(last_decrease_ms, options) do
    is_integer(last_decrease_ms) and options.queued_work? and
      clear_cpu_headroom?(options.cpu_headroom)
  end

  defp adjust_load_envelope_without_headroom(
         effective,
         last_decrease_ms,
         load,
         %{target: target, schedulers: schedulers} = options
       )
       when load <= target * schedulers do
    widen(effective, last_decrease_ms, load, options, false)
  end

  defp adjust_load_envelope_without_headroom(effective, last_decrease_ms, _load, options) do
    SustainedLoad.decrease(effective, last_decrease_ms, options)
  end

  defp clear_cpu_headroom?(headroom) when is_map(headroom) do
    case reclaimable_cpu_percent(headroom) do
      reclaimable when is_number(reclaimable) -> reclaimable >= @reclaimable_cpu_threshold
      :unavailable -> false
    end
  end

  defp clear_cpu_headroom?(_headroom), do: false

  defp widen(effective, last_decrease_ms, load, options, recovering?) do
    resume = Map.get(options, :resume_level)

    cond do
      is_integer(resume) and effective < resume ->
        {next, _decrease_ms} = fast_ramp(effective, last_decrease_ms, min(resume, options.static_limit))
        {next, last_decrease_ms}

      is_integer(resume) and not Map.get(options, :sustained_decrease?, false) and is_nil(last_decrease_ms) and load < options.target * options.schedulers / 2 ->
        fast_ramp(effective, last_decrease_ms, options.static_limit)

      recovering? ->
        fast_ramp(effective, last_decrease_ms, options.static_limit)

      true ->
        {min(effective + options.ramp_step, options.static_limit), last_decrease_ms}
    end
  end

  defp fast_ramp(effective, last_decrease_ms, static_limit) do
    next = min(static_limit, min(effective * 2, effective + @cpu_headroom_ramp_max))
    {next, if(next == static_limit, do: nil, else: last_decrease_ms)}
  end

  defp reclaimable_cpu_percent(%{reclaimable_percent: percent}) when is_number(percent), do: percent
  defp reclaimable_cpu_percent(%{idle_percent: percent}) when is_number(percent), do: percent
  defp reclaimable_cpu_percent(_headroom), do: :unavailable

  defp next_cpu_snapshot(_previous, %{total: _total, idle: _idle, runnable: _runnable} = current),
    do: current

  defp next_cpu_snapshot(_previous, _current), do: nil

  defp normalize_load_envelope_limit(effective, static_limit)
       when is_integer(effective) and effective > 0 and is_integer(static_limit) and
              static_limit > 0,
       do: min(effective, static_limit)

  defp normalize_load_envelope_limit(_effective, static_limit), do: static_limit
end
