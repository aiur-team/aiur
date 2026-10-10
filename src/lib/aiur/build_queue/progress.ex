defmodule Aiur.BuildQueue.Progress do
  @moduledoc "Shared list progress calculation and reconciliation fact producer."
  alias Aiur.BuildProgress
  alias Aiur.BuildQueue.ReadModel

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(BuildProgress) and GenServer.whereis(BuildProgress) != nil

  @spec summary([map()]) :: map()
  def summary(items) do
    if available?(), do: counts(items), else: unknown()
  end

  defp counts(items) do
    active = Enum.reject(items, &(&1.state == :removed))
    total = length(active)
    completed = Enum.count(active, &(&1.state == :completed))
    resolved = Enum.count(active, &(&1.state != :unknown))

    resolution =
      cond do
        total == 0 -> :unresolved
        resolved == 0 -> :unresolved
        resolved < total -> :partial
        true -> :resolved
      end

    %{completed: if(resolved > 0, do: completed), resolved: resolved, total: total, percent: if(resolved > 0, do: div(completed * 100, total)), resolution: resolution}
  end

  @spec fact(map(), [map()], map()) :: map() | nil
  def fact(%{kind: :build_order}, _items, _source), do: nil

  def fact(queue, items, source) do
    progress = summary(items)

    if progress.total not in [nil, 0] do
      Map.merge(progress, %{scope: {:queue, queue.id}, generation: queue.generation, freshness: source.freshness, observed_at: source.observed_at})
    end
  end

  @spec publish(map()) :: :ok
  def publish(state) do
    if available?() do
      model = ReadModel.build(state)
      source = model.sources["tracker_observation"]
      source = %{source | observed_at: source.observed_at || model.snapshot.captured_at}
      queues = Map.new(state.document.queues, &{&1.id, &1})

      for row <- model.queues, fact = fact(queues[row.queue_id], row.items, source), fact != nil do
        :ok = BuildProgress.put_fact(fact)
      end
    end

    :ok
  end

  defp unknown, do: %{completed: nil, resolved: nil, total: nil, percent: nil, resolution: :unknown}
end
