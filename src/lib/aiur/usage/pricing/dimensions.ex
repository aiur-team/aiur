defmodule Aiur.Usage.Pricing.Dimensions do
  @moduledoc false

  @type t :: %{
          context_tier: term(),
          cache_write_duration: term()
        }

  @spec from_options(:codex | :claude, keyword()) :: t()
  def from_options(:codex, options) do
    %{
      context_tier: Keyword.get(options, :context_tier),
      cache_write_duration: Keyword.get(options, :cache_write_duration, :not_applicable)
    }
  end

  def from_options(:claude, options) do
    %{
      context_tier: Keyword.get(options, :context_tier, :not_applicable),
      cache_write_duration: Keyword.get(options, :cache_write_duration)
    }
  end

  @spec validate(:codex | :claude, t()) :: :ok | {:error, atom()}
  def validate(:codex, %{context_tier: nil}),
    do: {:error, :missing_context_tier}

  def validate(:codex, %{context_tier: tier})
      when tier not in [:short_context, :long_context],
      do: {:error, :unsupported_context_tier}

  def validate(:codex, %{cache_write_duration: duration})
      when duration != :not_applicable,
      do: {:error, :unsupported_cache_write_duration}

  def validate(:codex, _dimensions), do: :ok

  def validate(:claude, %{context_tier: tier})
      when tier != :not_applicable,
      do: {:error, :unsupported_context_tier}

  def validate(:claude, %{cache_write_duration: nil}),
    do: {:error, :missing_cache_write_duration}

  def validate(:claude, %{cache_write_duration: duration})
      when duration not in [:five_minutes, :one_hour],
      do: {:error, :unsupported_cache_write_duration}

  def validate(:claude, _dimensions), do: :ok

  @spec for_component(:codex | :claude, atom(), t()) :: t()
  def for_component(:claude, dimension, dimensions)
      when dimension != :cache_creation_input,
      do: %{dimensions | cache_write_duration: :not_applicable}

  def for_component(_provider, _dimension, dimensions), do: dimensions
end
