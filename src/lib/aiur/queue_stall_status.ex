defmodule Aiur.QueueStallStatus do
  @moduledoc "Combines queue-list age with the current dispatch capacity for CLI status surfaces."
  alias Aiur.BuildQueue
  alias Aiur.BuildQueue.SetSummary
  alias Aiur.Orchestrator.StatusReport

  @spec decorate(map(), map() | nil, integer()) :: map()
  def decorate(envelope, capacity, now_ms) do
    capacity = capacity || StatusReport.snapshot_api()
    free_slots = get_in(capacity, [:capacity, :available]) || 0

    Map.update(envelope, :queues, [], fn queues ->
      Enum.map(queues, &Map.put(&1, :stalled?, SetSummary.stalled?(&1, now_ms, free_slots)))
    end)
  end

  @spec stalled_queues(map(), non_neg_integer()) :: [map()]
  def stalled_queues(_snapshot, 0), do: []

  def stalled_queues(_snapshot, free_slots) do
    now = System.system_time(:millisecond)

    case BuildQueue.show() do
      %{queues: queues} -> Enum.filter(queues, &SetSummary.stalled?(&1, now, free_slots))
      _ -> []
    end
  end
end
