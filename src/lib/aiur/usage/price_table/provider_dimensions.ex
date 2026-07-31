defmodule Aiur.Usage.PriceTable.ProviderDimensions do
  @moduledoc false

  alias Aiur.CodingAgent

  @spec validate(atom(), atom(), atom(), atom()) :: :ok | {:error, atom()}
  def validate(provider, token_dimension, context_tier, cache_write_duration) do
    with {:ok, dimensions} <- component_dimensions(provider, token_dimension),
         :ok <- validate_dimension(context_tier, dimensions.context_tier, :invalid_price_context_tier),
         :ok <- validate_dimension(cache_write_duration, dimensions.cache_write_duration, :invalid_cache_write_duration) do
      :ok
    end
  end

  defp component_dimensions(provider, token_dimension) do
    case CodingAgent.provider_pricing(provider) do
      %{component_dimensions: component_dimensions} when is_map(component_dimensions) ->
        case Map.get(component_dimensions, token_dimension, Map.get(component_dimensions, :default)) do
          %{context_tier: _tiers, cache_write_duration: _durations} = dimensions -> {:ok, dimensions}
          _ -> {:error, :invalid_price_context_tier}
        end

      _ ->
        {:error, :invalid_price_context_tier}
    end
  end

  defp validate_dimension(value, allowed, error), do: if(value in allowed, do: :ok, else: {:error, error})
end
