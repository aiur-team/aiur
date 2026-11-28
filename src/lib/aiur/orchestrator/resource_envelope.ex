defmodule Aiur.Orchestrator.ResourceEnvelope do
  @moduledoc false

  alias Aiur.Orchestrator.{DispatchPolicy, EnvelopeResume, Slots, State}

  @minimum_hold_ms 10_000

  @type binding :: %{signal: atom(), condition: atom(), observed_at_ms: integer() | nil}
  @type envelope :: %{binding: binding(), healthy_since_ms: integer() | nil, sampled_at_ms: integer() | nil}

  @spec boot() :: envelope()
  def boot do
    %{binding: binding(:resource_readings, :unknown, nil), healthy_since_ms: nil, sampled_at_ms: nil}
  end

  @spec enabled?(State.t()) :: boolean()
  def enabled?(state), do: is_map(state.load_envelope_state[:resources])

  @spec configure(State.t(), map()) :: State.t()
  def configure(state, agent) do
    case {agent.resource_concurrency == true, enabled?(state)} do
      {true, false} ->
        %{state | effective_concurrent_agents: 1, load_envelope_state: %{cpu_snapshot: nil, resources: boot()}}

      {false, true} ->
        %{state | effective_concurrent_agents: DispatchPolicy.initial_load_envelope_limit(agent), load_envelope_state: EnvelopeResume.boot(agent)}

      {true, true} ->
        enforce_limit(state)

      {false, false} ->
        state
    end
  end

  @spec enforce_limit(State.t()) :: State.t()
  def enforce_limit(%State{load_envelope_state: %{resources: resources}, effective_concurrent_agents: effective} = state) when is_integer(effective) do
    limit = Slots.max_concurrent_agent_limit(state)

    if effective > limit do
      state = put_in(state.load_envelope_state[:resources], %{resources | binding: cap_binding(state, limit), healthy_since_ms: nil})
      %{state | effective_concurrent_agents: limit}
    else
      state
    end
  end

  def enforce_limit(state), do: state

  defp cap_binding(state, limit), do: binding(cap_signal(state, limit), :at_limit, System.monotonic_time(:millisecond))

  defp cap_signal(state, limit) do
    configured = state.max_concurrent_agents || Aiur.Config.max_concurrent_agents()
    if limit < configured, do: :session_cap, else: :configured_cap
  end

  @spec update(State.t(), map(), boolean(), integer()) :: State.t()
  def update(state, probes, demand?, now_ms) do
    limit = Slots.max_concurrent_agent_limit(state)
    effective = Slots.effective_concurrent_agent_limit(state)
    hold_ms = max(@minimum_hold_ms, Aiur.Config.load_cooldown_seconds() * 1_000)
    max_gap_ms = 2 * normal_dispatch_interval_ms(state)
    sampled_at = probes[:resource_sampled_at_ms]
    readings = if is_integer(sampled_at) and (now_ms - sampled_at) in 0..max_gap_ms, do: probes[:resource_readings] || [], else: []
    timestamp = if readings == [], do: now_ms, else: sampled_at

    {next, resources} = step(state.load_envelope_state.resources, effective, limit, cap_signal(state, limit), readings, {timestamp, hold_ms, max_gap_ms}, demand?)

    state = put_in(state.load_envelope_state[:resources], resources)
    %{state | effective_concurrent_agents: next}
  end

  defp normal_dispatch_interval_ms(state) do
    base = state.poll_interval_ms || Aiur.PollCadence.base_interval_ms(class: :dispatch)
    if state.idle_poll_backoff[:active?], do: base, else: max(base, state.effective_poll_interval_ms || base)
  end

  @spec step(envelope(), pos_integer(), pos_integer(), atom(), [binding()], {integer(), pos_integer(), pos_integer()}, boolean()) :: {pos_integer(), envelope()}
  def step(previous, current, limit, cap_signal, readings, {sampled_at, hold_ms, max_gap_ms}, demand?) do
    level = min(current, limit)

    cond do
      is_integer(previous.sampled_at_ms) and sampled_at <= previous.sampled_at_ms ->
        {level, previous}

      binding = limiting_reading(readings) ->
        next = if binding.condition == :pressure, do: max(1, div(level, 2)), else: level
        {next, observed(previous, binding, sampled_at)}

      true ->
        healthy_step(previous, level, limit, cap_signal, {sampled_at, hold_ms, max_gap_ms}, demand?)
    end
  end

  defp limiting_reading([]), do: binding(:resource_readings, :unknown, nil)

  defp limiting_reading(readings) do
    Enum.find_value([:pressure, :unknown, :busy], fn condition ->
      Enum.find(readings, &(&1.condition == condition))
    end)
  end

  defp healthy_step(previous, current, limit, cap_signal, {sampled_at, hold_ms, max_gap_ms}, demand?) do
    since = healthy_since(previous, sampled_at, max_gap_ms)
    grow? = demand? and current < limit and sampled_at - since >= hold_ms
    next = if grow?, do: current + 1, else: current
    {signal, condition} = healthy_binding(next, limit, cap_signal, demand?)
    {next, %{binding: binding(signal, condition, sampled_at), healthy_since_ms: if(grow?, do: sampled_at, else: since), sampled_at_ms: sampled_at}}
  end

  defp observed(previous, binding, sampled_at),
    do: %{previous | binding: binding, healthy_since_ms: nil, sampled_at_ms: sampled_at}

  defp healthy_since(%{healthy_since_ms: since, sampled_at_ms: last}, now, max_gap) when is_integer(since) and now - last <= max_gap, do: since
  defp healthy_since(_previous, now, _max_gap), do: now

  defp healthy_binding(limit, limit, cap_signal, _demand?), do: {cap_signal, :at_limit}
  defp healthy_binding(_next, _limit, _cap_signal, false), do: {:ticket_demand, :waiting}
  defp healthy_binding(_next, _limit, _cap_signal, true), do: {:healthy_hold, :waiting}

  @spec binding(atom(), atom(), integer() | nil) :: binding()
  def binding(signal, condition, observed_at), do: %{signal: signal, condition: condition, observed_at_ms: observed_at}

  @spec label(map(), integer()) :: String.t() | nil
  def label(capacity, now_ms \\ System.monotonic_time(:millisecond))

  def label(%{resource_binding: %{signal: signal, condition: condition, observed_at_ms: observed_at}}, now_ms) do
    age = if is_integer(observed_at), do: "#{div(max(0, now_ms - observed_at), 1_000)}s ago", else: "unavailable"
    "#{signal} (#{condition}, sample age #{age})"
  end

  def label(_capacity, _now_ms), do: nil
end
