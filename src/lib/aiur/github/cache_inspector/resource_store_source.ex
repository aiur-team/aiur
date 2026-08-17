defmodule Aiur.GitHub.CacheInspector.ResourceStoreSource do
  @moduledoc """
  Reads `Aiur.GitHub.ResourceStore` without going through it.

  The store keeps its entries in a public ETS table and this reads that table
  directly. That looks like a shortcut and is actually the point: `:ets` has no
  network, so the inspector's read path is structurally unable to fetch. The
  store's own API would work equally well today, but it exposes no enumeration
  and would put a GenServer between the page and the data whose behaviour on a
  miss is the store's to change — at which point "viewing never fetches" would
  depend on a decision made somewhere else.

  It also means the page cannot block. A table read does not queue behind the
  store's mailbox, so an inspector left open cannot slow the writers it watches.

  ## What a stored entry actually holds

  The store writes a bare map under `{resource_type, owner, repo, id}` with
  `:data`, `:data_version`, `:fetched_at_ms`, `:source`, `:etag`, `:version`,
  `:processed_at_ms` and `:recorded_at_ms`. Every one of those is optional, and
  the combination that matters most is **`:etag` present with `:data` absent**:
  `Aiur.GitHub.ResourceStore.drop_data/1` deliberately keeps the validator, and
  a reader that treats that as a hit earns a `304` with no body — a request paid
  for that returns nothing. So the body is read out as its own fact rather than
  inferred from the validator, and the page shows it as its own state.
  """

  @behaviour Aiur.GitHub.CacheInspector.Source

  alias Aiur.GitHub.ResourceStore

  @table Module.concat([ResourceStore, Table])

  # Deferred to the store rather than re-derived here. It answers from the same
  # table every read and write funnels through, and keeping one implementation
  # of "is there a store" means the page and the writers cannot disagree about
  # it. It is still not a `GenServer.call`, so the read path stays unable to
  # block and unable to fetch.
  @impl true
  def available? do
    ResourceStore.running?()
  rescue
    _unavailable -> false
  catch
    :exit, _reason -> false
  end

  @impl true
  def entries do
    @table
    |> :ets.tab2list()
    |> Enum.map(&normalize/1)
  rescue
    # The table can vanish between the check and the read. That is a cold store,
    # not an error worth surfacing as one.
    _unavailable -> []
  end

  defp normalize({{_type, _owner, _repo, _id} = key, entry}) when is_map(entry) do
    %{
      key: key,
      etag: Map.get(entry, :etag),
      version: Map.get(entry, :version),
      data_version: Map.get(entry, :data_version),
      source: Map.get(entry, :source),
      fetched_at_ms: Map.get(entry, :fetched_at_ms),
      processed_at_ms: Map.get(entry, :processed_at_ms),
      recorded_at_ms: Map.get(entry, :recorded_at_ms),
      # Read as "is a body held", never "is the body truthy". A resource whose
      # cached body is legitimately `false`, `0` or `[]` is still a body the
      # store can answer a reader with.
      data?: Map.has_key?(entry, :data) and not is_nil(Map.get(entry, :data)),
      data: Map.get(entry, :data)
    }
  end

  defp normalize(_row), do: %{}
end
