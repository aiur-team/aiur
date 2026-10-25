defmodule Aiur.BuildQueue.AttentionHealth do
  @moduledoc false
  alias Aiur.BuildQueue.{Attention, Settings}

  @spec plan(map(), list()) :: {map(), list()}
  def plan(state, projections) do
    unknown? = inputs_unknown?(state, projections)

    since = if unknown?, do: state.inputs_unknown_since_ms || state.clock.()
    state = %{state | inputs_unknown_since_ms: since}
    latched? = Enum.any?(state.document.latches, &(&1.key == {:inputs_unavailable, nil}))

    action =
      cond do
        unknown? and state.clock.() - since >= 2 * Settings.observation_max_age_ms(state.settings) -> [{:attention_open, {:inputs_unavailable, nil}}]
        not unknown? and latched? -> [{:attention_resolve, {:inputs_unavailable, nil}}]
        true -> []
      end

    {state, action}
  end

  defp inputs_unknown?(state, projections) do
    state.freshness == :unknown or map_size(state.source_verdicts) > 0 or
      Enum.any?(state.sources, fn {_key, source} -> match?({:unavailable, _}, source) end) or
      Enum.any?(projections, &(match?({:unknown, _}, &1.verdict) or &1.reason == :observation_unavailable))
  end

  @spec store(map()) :: map()
  def store(state) do
    unavailable? = state.status == :store_unavailable

    if unavailable? != state.store_attention? and Attention.transient_store(not unavailable?) == :ok do
      %{state | store_attention?: unavailable?}
    else
      state
    end
  end
end
