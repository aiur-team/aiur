defmodule Aiur.Usage.Pricing.Dimensions do
  @moduledoc false

  alias Aiur.CodingAgent

  @type t :: %{context_tier: term(), cache_write_duration: term()}

  @spec from_options(atom(), keyword()) :: t()
  def from_options(provider, options) do
    provider
    |> dimensions()
    |> Enum.into(%{}, fn {dimension, %{default: default}} ->
      {dimension, Keyword.get(options, dimension, default)}
    end)
  end

  @spec validate(atom(), t()) :: :ok | {:error, atom()}
  def validate(provider, pricing_dimensions) when is_map(pricing_dimensions) do
    provider
    |> dimensions()
    |> Enum.reduce_while(:ok, fn {dimension, policy}, :ok ->
      value = Map.get(pricing_dimensions, dimension)

      case validate_dimension(value, policy, dimension) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def validate(_provider, _pricing_dimensions), do: {:error, :unsupported_context_tier}

  @spec for_component(atom(), atom(), t()) :: t()
  def for_component(provider, token_dimension, pricing_dimensions) do
    case component_dimensions(provider, token_dimension) do
      nil -> pricing_dimensions
      component -> normalize_for_component(pricing_dimensions, component)
    end
  end

  defp dimensions(provider) do
    case CodingAgent.provider_pricing(provider) do
      %{dimensions: dimensions} when is_map(dimensions) -> dimensions
      _ -> %{}
    end
  end

  defp component_dimensions(provider, token_dimension) do
    case CodingAgent.provider_pricing(provider) do
      %{component_dimensions: component_dimensions} when is_map(component_dimensions) ->
        Map.get(component_dimensions, token_dimension, Map.get(component_dimensions, :default))

      _ ->
        nil
    end
  end

  defp validate_dimension(nil, %{required: true}, :context_tier), do: {:error, :missing_context_tier}
  defp validate_dimension(nil, %{required: true}, :cache_write_duration), do: {:error, :missing_cache_write_duration}

  defp validate_dimension(value, %{allowed: allowed}, dimension) do
    if value in allowed, do: :ok, else: unsupported_dimension(dimension)
  end

  defp validate_dimension(_value, _policy, :context_tier), do: {:error, :unsupported_context_tier}
  defp validate_dimension(_value, _policy, :cache_write_duration), do: {:error, :unsupported_cache_write_duration}

  defp unsupported_dimension(:context_tier), do: {:error, :unsupported_context_tier}
  defp unsupported_dimension(:cache_write_duration), do: {:error, :unsupported_cache_write_duration}

  defp normalize_for_component(pricing_dimensions, component_dimensions) do
    Enum.reduce(component_dimensions, pricing_dimensions, fn {dimension, allowed}, result ->
      if Map.get(result, dimension) in allowed,
        do: result,
        else: Map.put(result, dimension, List.first(allowed))
    end)
  end
end
