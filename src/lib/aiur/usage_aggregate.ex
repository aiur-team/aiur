defmodule Aiur.UsageAggregate do
  @moduledoc """
  Stable daemon-owned seam for the crash-safe usage aggregate/query projection.

  It projects the ordered accepted deltas published by `Aiur.UsageLedger`
  (DASH-009) into exact, relationship-revision-partitioned aggregate cells and
  serves bounded queries scoped by explicit repository-qualified typed tickets
  and/or opaque run identifiers. The ledger remains the single source of truth:
  this projection never appends envelopes, derives deltas, or owns
  idempotency/counter state, and it is fully reproducible from the retained
  ledger deltas after a crash.

  Downstream pricing (DASH-011) and retention (DASH-025) consume this behavior
  through the functions below; neither reads the implementation files directly.
  """

  alias Aiur.UsageAggregate.Store

  @pubsub Aiur.PubSub
  @topic "usage-aggregate:changed"

  @doc """
  Returns the bounded exact summary for an explicit scope.

  `scope` is a map with optional `:runs` (opaque run-id strings) and
  `:tickets` (`Aiur.TrackerIdentity` structs). Non-joinable identities and any
  bare issue number are rejected rather than used as a scope key.
  """
  @spec query(map()) :: map()
  def query(scope) when is_map(scope), do: Store.query(scope)

  @doc "Returns bounded health, freshness, coverage, and generation facts."
  @spec snapshot() :: map()
  def snapshot, do: Store.snapshot()

  @doc """
  Returns the retained aggregate cells paired with the bounded metadata as
  `%{cells: cells, metadata: metadata}`, the source shape the pure grouped-scope
  query layer (DASH-030) consumes.

  Work is proportional to the retained cell count, never to ledger size. The
  cells stay server-side: the grouped-scope layer reduces them to a bounded,
  scope-restricted snapshot before anything reaches a browser.
  """
  @spec cells_snapshot() :: %{cells: map(), metadata: map()}
  def cells_snapshot, do: Store.cells_snapshot()

  @spec health() :: term()
  def health, do: Store.health()

  @spec generation() :: non_neg_integer()
  def generation, do: Store.generation()

  @spec freshness() :: map()
  def freshness, do: Store.freshness()

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc false
  @spec broadcast(map()) :: :ok
  def broadcast(payload) when is_map(payload) do
    if is_pid(Process.whereis(@pubsub)) do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:usage_aggregate_changed, payload})
    end

    :ok
  end
end
