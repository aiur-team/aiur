defmodule Aiur.BuildQueue.SetSummary do
  @moduledoc "Set counts and admission state from reconciled item evidence."
  @terminal [:completed, :cancelled, :removed]

  @spec decorate([map()], [String.t()]) :: [map()]
  def decorate(queues, unavailable) do
    queues = queues |> Enum.sort_by(&{&1.set_rank, &1.queue_id}) |> Enum.map(&counts(&1, unavailable))
    states(queues, :unavailable)
  end

  @spec select_next(map(), Aiur.BuildQueue.ClaimProbe.next_set()) :: map()
  def select_next(envelope, next_set), do: %{envelope | queues: states(envelope.queues, next_set)}

  defp states(queues, next_set) do
    Enum.map(queues, fn queue ->
      next? =
        case next_set do
          {:ok, id} -> queue.queue_id == id
          :unavailable -> nil
        end

      {state, reason} = state(queue, next?, next_set)
      Map.merge(queue, %{state: state, waiting_reason: reason, next: next?})
    end)
  end

  defp counts(queue, unavailable) do
    counts =
      if queue.queue_id in unavailable or Enum.any?(queue.items, &(&1.state == :unknown)) do
        %{ready: nil, started: nil, done: nil}
      else
        %{ready: Enum.count(queue.items, &ready?/1), started: Enum.count(queue.items, &(&1.state == :claimed)), done: Enum.count(queue.items, &(&1.state in @terminal))}
      end

    Map.put(queue, :counts, counts)
  end

  defp ready?(item), do: item.state in [:ready, :promoted, :overridden] and item.verdict == :ready
  defp admission_reason(%{reason: "queue_set_order:" <> _ = reason}), do: reason
  defp admission_reason(_), do: nil

  defp state(queue, next?, next_set) do
    cond do
      Enum.any?(queue.items, &(&1.state == :claimed)) -> {:active, nil}
      queue.held -> {:waiting, "held"}
      queue.counts.ready == nil -> {:waiting, "readiness unknown"}
      Enum.all?(queue.items, &(&1.state in @terminal)) -> {:done, nil}
      next? -> {:next, nil}
      true -> {:waiting, waiting_reason(queue, next_set)}
    end
  end

  defp waiting_reason(queue, next_set) do
    Enum.find_value(queue.items, &admission_reason/1) || dispatch_wait(queue.counts.ready, next_set)
  end

  defp dispatch_wait(0, _next_set), do: "no ready tickets"
  defp dispatch_wait(_ready, :unavailable), do: "dispatch admission unknown"
  defp dispatch_wait(_ready, _next_set), do: "not admitted for dispatch"
end
