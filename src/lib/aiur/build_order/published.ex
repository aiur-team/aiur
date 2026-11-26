defmodule Aiur.BuildOrder.Published do
  @moduledoc """
  Encodes one Build Order projection as a `build-order.v1` snapshot document.

  The document is derived, never authored. Epics, features and lanes come from
  the projection and its planning-pack metadata; waves, dependency states and
  the critical path reuse `Aiur.BuildOrder.GraphAnalysis` and
  `Aiur.BuildOrder.EdgeState`; progress counts the same lifecycle facts the
  dashboard renders. An unavailable tracker or progress read publishes
  `status: "unknown"` with a reason on every affected object instead of an empty
  graph that a reader would show as "nothing to do".

  A catalog projection publishes one epic per imported root until epic records
  above features land (#7496). A selected-root projection publishes one epic for
  the root itself, its pack workstreams as features, and every present lane.

  Node `id`s are the planning-pack ids (`BO-001`) when the projection holds
  them; otherwise they are the tracker identifiers. `number` is the tracker
  number or `null`, and every edge endpoint is a node id or a gate key from the
  same document.

  The three document shapes live in `Published.SelectedRoot`,
  `Published.Catalog` and `Published.Unavailable`; `Published.Document` holds
  the shared envelope and `Published.Pack` the planning-pack records.
  """

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.Published.{Catalog, Document, SelectedRoot, Unavailable}

  @spec contract() :: String.t()
  defdelegate contract, to: Document

  @spec contract_version() :: pos_integer()
  defdelegate contract_version, to: Document

  @spec contract_name() :: String.t()
  defdelegate contract_name, to: Document

  @spec encode(Snapshot.t(), keyword()) :: map()
  def encode(%Snapshot{} = snapshot, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    case snapshot.data do
      %Aiur.BuildOrder.SelectedRoot{} = selected -> SelectedRoot.document(snapshot, selected, now, opts)
      %Aiur.BuildOrder.Catalog{} = catalog -> Catalog.document(snapshot, catalog, now, opts)
      _missing -> Unavailable.document(snapshot, now)
    end
  end
end
