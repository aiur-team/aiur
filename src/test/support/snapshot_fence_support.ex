defmodule Aiur.SnapshotFenceSupport do
  @moduledoc false

  alias Aiur.Orchestrator.SnapshotStore

  @doc """
  Fences the SnapshotStore read model of a shared Orchestrator.

  Control queries read that read model before they ask the Orchestrator, and
  it is keyed by the registered name, so a projection an earlier case or module
  published outlives it and hides state a case injects with
  `:sys.replace_state/2`. `SnapshotStore.forget/1` alone is not enough: a
  projection already queued lands after it. A new generation fences that
  in-flight work. Hand the returned generation to the Orchestrator in the same
  `:sys.replace_state/2` so its own later publishes stay valid (#2719).
  """
  @spec fence_snapshot_read_model(GenServer.name()) :: reference()
  def fence_snapshot_read_model(orchestrator \\ Aiur.Orchestrator) do
    generation = SnapshotStore.begin_generation(orchestrator)
    :ok = SnapshotStore.forget(orchestrator)
    generation
  end
end
