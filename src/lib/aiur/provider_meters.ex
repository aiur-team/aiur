defmodule Aiur.ProviderMeters do
  @moduledoc """
  Canonical provider-neutral account meter projection.

  Provider adapters submit content-free observations through `ingest/1`.
  The canonical store validates each mutation and resolves its exact opaque
  account generation before accepting, retaining, or broadcasting it.
  """

  alias Aiur.ProviderMeterSnapshot
  alias Aiur.ProviderMeters.{Events, Store}

  @type provider :: :codex | :claude
  @type backend :: :app_server

  @spec ingest(map()) :: {:ok, ProviderMeterSnapshot.t()} | {:error, atom()}
  def ingest(update), do: Store.ingest(Store, update)

  @spec record_failure(map()) :: {:ok, ProviderMeterSnapshot.t()} | {:error, atom()}
  def record_failure(failure), do: Store.record_failure(Store, failure)

  @spec snapshot(provider(), backend(), reference() | map()) :: ProviderMeterSnapshot.t()
  def snapshot(provider, backend, binding), do: Store.snapshot(Store, provider, backend, binding)

  @spec lookup(provider(), backend(), reference() | map()) :: ProviderMeterSnapshot.t()
  def lookup(provider, backend, binding), do: snapshot(provider, backend, binding)

  @spec health(provider(), backend(), reference() | map()) :: ProviderMeterSnapshot.health()
  def health(provider, backend, binding), do: snapshot(provider, backend, binding).health

  @spec freshness(provider(), backend(), reference() | map()) :: :fresh | :partial | :stale | :unknown
  def freshness(provider, backend, binding), do: snapshot(provider, backend, binding).freshness

  @spec generation() :: non_neg_integer()
  def generation, do: Store.generation(Store)

  @spec subscribe(provider(), backend(), reference() | map()) :: :ok | {:error, term()}
  def subscribe(provider, backend, binding) do
    with {:ok, generation} <- Store.subscription_generation(Store, provider, backend, binding) do
      Events.subscribe(provider, backend, generation)
    end
  end
end
