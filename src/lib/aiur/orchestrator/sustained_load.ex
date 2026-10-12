defmodule Aiur.Orchestrator.SustainedLoad do
  @moduledoc false

  @samples 3

  @spec count(number() | :unavailable, number() | nil, pos_integer(), map()) :: non_neg_integer()
  def count(load, target, schedulers, previous)
      when is_number(load) and is_number(target) and load > target * schedulers,
      do: min(Map.get(previous, :overload_samples, 0) + 1, @samples)

  def count(_load, _target, _schedulers, _previous), do: 0

  @spec decrease(pos_integer(), integer() | nil, map()) :: {pos_integer(), integer() | nil}
  def decrease(effective, last_decrease_ms, options) do
    sustained? = Map.get(options, :overload_samples, @samples) >= @samples
    cooldown_elapsed? = is_nil(last_decrease_ms) or options.now_ms - last_decrease_ms >= options.cooldown_ms

    if sustained? and cooldown_elapsed? do
      reduced = max(div(effective + 1, 2), 1)
      {reduced, if(reduced < effective, do: options.now_ms, else: last_decrease_ms)}
    else
      {effective, last_decrease_ms}
    end
  end
end
