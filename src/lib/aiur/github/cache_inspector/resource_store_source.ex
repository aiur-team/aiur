defmodule Aiur.GitHub.CacheInspector.ResourceStoreSource do
  @moduledoc """
  Reads `Aiur.GitHub.ResourceStore` without going through it.

  The store keeps its entries in an ETS table, and this reads that table
  directly. That looks like a shortcut and is actually the point: `:ets` has no
  network, so the inspector's read path is structurally unable to fetch. Calling
  the store's own API would work equally well today and would put a GenServer
  between the page and the data whose behaviour on a miss is the store's to
  change — at which point "viewing never fetches" would depend on a decision
  made somewhere else.

  It also means the page cannot block. A table read does not queue behind the
  store's mailbox, so an inspector left open cannot slow the writers it watches.

  ## Before the store lands

  `Aiur.GitHub.ResourceStore` arrives with U1 (PR #2079). Until then this
  answers `available?: false` and the page renders its own "no store yet" state,
  which is the same state a cold store produces and therefore not a special case
  worth branching on.
  """

  @behaviour Aiur.GitHub.CacheInspector.Source

  @table Module.concat([Aiur.GitHub.ResourceStore, Table])

  @impl true
  def available? do
    :ets.whereis(@table) != :undefined
  rescue
    _unavailable -> false
  end

  @impl true
  def entries do
    @table
    |> :ets.tab2list()
    |> Enum.map(&normalize/1)
  rescue
    # The table can vanish between the check and the read. That is a cold
    # store, not an error worth surfacing as one.
    _unavailable -> []
  end

  # The store's record is a `{key, entry}` pair whose entry is a bare map. Both
  # the current shape and the richer one U1 grows into (a cached response body
  # beside its validator) pass through unchanged, because everything optional is
  # read by name and absent keys simply do not render.
  defp normalize({{_type, _owner, _repo, _id} = key, entry}) when is_map(entry) do
    entry
    |> Map.take([:etag, :version, :source, :payload, :writes, :fetched_at, :processed_at_ms])
    |> Map.put(:key, key)
  end

  defp normalize({key, entry}) when is_map(entry), do: Map.put(entry, :key, key)
  defp normalize(_row), do: %{}
end
