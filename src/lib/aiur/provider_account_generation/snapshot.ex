defmodule Aiur.ProviderAccountGeneration.Snapshot do
  @moduledoc false

  @schema_version 1

  @spec known(atom(), atom(), String.t(), atom(), DateTime.t()) :: map()
  def known(provider, backend, generation, source, observed_at) do
    %{
      schema_version: @schema_version,
      provider: provider,
      backend: backend,
      generation: generation,
      source: source,
      freshness: :current,
      health: :healthy,
      reason: nil,
      observed_at: observed_at
    }
  end

  @spec unavailable(atom(), atom()) :: map()
  def unavailable(provider, backend), do: unknown(provider, backend, :unavailable, :owner_unavailable, nil)

  @spec unknown(atom(), atom(), atom(), atom(), DateTime.t() | nil) :: map()
  def unknown(provider, backend, source, reason, observed_at) do
    %{
      schema_version: @schema_version,
      provider: provider,
      backend: backend,
      generation: nil,
      source: source,
      freshness: :unknown,
      health: if(source == :unavailable, do: :unavailable, else: :unknown),
      reason: reason,
      observed_at: observed_at
    }
  end

  @spec invalidated(map(), atom(), atom(), atom(), atom(), DateTime.t()) :: {map(), atom() | nil}
  def invalidated(snapshot, provider, backend, source, reason, clock) do
    reason = effective_reason(snapshot, reason)

    updated =
      if is_nil(snapshot.generation) and snapshot.reason == reason do
        snapshot
      else
        unknown(provider, backend, source, reason, clock)
      end

    change = if is_binary(snapshot.generation) or snapshot.reason != reason, do: :invalidated
    {updated, change}
  end

  defp effective_reason(%{generation: nil, reason: reason}, :continuity_lost) when reason in [:logout, :unsupported_auth_mode], do: reason
  defp effective_reason(_snapshot, reason), do: reason
end
