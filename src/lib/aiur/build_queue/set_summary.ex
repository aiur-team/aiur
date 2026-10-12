defmodule Aiur.BuildQueue.SetSummary do
  @moduledoc "Set counts and admission state from reconciled item evidence."
  @terminal [:completed, :cancelled, :removed]

  @spec decorate([map()]) :: [map()]
  def decorate(queues) do
    queues = queues |> Enum.sort_by(&{&1.set_rank, &1.queue_id}) |> Enum.map(&counts/1)
    next = Enum.find(queues, &eligible?/1)

    Enum.map(queues, fn queue ->
      {state, reason} = state(queue, next)
      Map.merge(queue, %{state: state, waiting_reason: reason})
    end)
  end

  defp counts(queue) do
    counts =
      if Enum.any?(queue.items, &(&1.state == :unknown)) do
        %{ready: nil, started: nil, done: nil}
      else
        %{ready: Enum.count(queue.items, &ready?/1), started: Enum.count(queue.items, &(&1.state == :claimed)), done: Enum.count(queue.items, &(&1.state in @terminal))}
      end

    Map.put(queue, :counts, counts)
  end

  defp eligible?(queue), do: not queue.held and queue.counts.ready != nil and queue.counts.started == 0 and Enum.any?(queue.items, &(ready?(&1) and is_nil(admission_reason(&1))))
  defp ready?(item), do: item.state in [:ready, :promoted, :overridden] and item.verdict == :ready
  defp admission_reason(%{reason: "queue_set_order:" <> _ = reason}), do: reason
  defp admission_reason(_), do: nil

  defp state(queue, next) do
    cond do
      Enum.any?(queue.items, &(&1.state == :claimed)) -> {:active, nil}
      Enum.all?(queue.items, &(&1.state in @terminal)) -> {:done, nil}
      queue.held -> {:waiting, "held"}
      queue.counts.ready == nil -> {:waiting, "readiness unknown"}
      next && queue.queue_id == next.queue_id -> {:next, nil}
      true -> {:waiting, waiting_reason(queue, next)}
    end
  end

  defp waiting_reason(queue, next) do
    Enum.find_value(queue.items, &admission_reason/1) || if(queue.counts.ready > 0 and next, do: "earlier set #{next.name} has ready work", else: "no ready tickets")
  end
end
