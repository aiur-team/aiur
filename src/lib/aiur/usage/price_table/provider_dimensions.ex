defmodule Aiur.Usage.PriceTable.ProviderDimensions do
  @moduledoc false

  @spec validate(:codex | :claude, atom(), atom(), atom()) :: :ok | {:error, atom()}
  def validate(:codex, _dimension, tier, :not_applicable)
      when tier in [:short_context, :long_context],
      do: :ok

  def validate(:codex, _dimension, tier, _duration)
      when tier not in [:short_context, :long_context],
      do: {:error, :invalid_price_context_tier}

  def validate(:codex, _dimension, _tier, _duration),
    do: {:error, :invalid_cache_write_duration}

  def validate(:claude, :cache_creation_input, :not_applicable, duration)
      when duration in [:five_minutes, :one_hour],
      do: :ok

  def validate(:claude, dimension, :not_applicable, :not_applicable)
      when dimension != :cache_creation_input,
      do: :ok

  def validate(:claude, _dimension, tier, _duration)
      when tier != :not_applicable,
      do: {:error, :invalid_price_context_tier}

  def validate(:claude, _dimension, _tier, _duration),
    do: {:error, :invalid_cache_write_duration}
end
