defmodule Aiur.BuildOrder.GraphProjection.CapabilityReader do
  @moduledoc "Snapshot-only catalog read; leaves reconciliation, timers, and broadcasts to their existing callers."

  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.Snapshot

  @spec catalog(GenServer.server()) :: Snapshot.t()
  def catalog(server \\ GraphProjection), do: GenServer.call(server, :capability_catalog)
end
