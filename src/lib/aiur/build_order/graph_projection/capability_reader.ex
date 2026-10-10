defmodule Aiur.BuildOrder.GraphProjection.CapabilityReader do
  @moduledoc "Mailbox-free catalog read; leaves reconciliation, timers, and broadcasts to their existing callers."

  alias Aiur.BuildOrder.GraphProjection
  alias Aiur.BuildOrder.GraphProjection.{Policy, Snapshot}

  @spec publish(map(), pos_integer()) :: :ok
  def publish(state, interval_ms) do
    Process.put(__MODULE__, {state.catalog, state.active_repository, state.authority_epoch, state.clock_ms, interval_ms})
    :ok
  end

  @spec catalog(GenServer.server()) :: Snapshot.t()
  def catalog(server \\ GraphProjection) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {entry, repository, epoch, clock_ms, interval_ms} <- Keyword.get(dictionary, __MODULE__) do
      Policy.snapshot(entry, repository, epoch, clock_ms.(), interval_ms)
    else
      _ -> exit(:snapshot_unpublished)
    end
  end
end
