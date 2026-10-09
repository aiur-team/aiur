defmodule Aiur.BuildQueue.Bookkeeping do
  @moduledoc false

  @spec apply(map(), {atom(), String.t()}) :: map()
  def apply(document, {:mark_override, id}), do: update_item(document, id, &%{&1 | override: :manual_promotion})
  def apply(document, {:mark_external_hold, id}), do: update_item(document, id, &%{&1 | hold: :external})
  def apply(document, {:withdraw_observed, id}), do: update_item(document, id, &%{&1 | promoted_at: nil})

  def apply(document, {:dequeue, id}) do
    %{document | items: Enum.reject(document.items, &(&1.issue_id == id)), edges: Enum.reject(document.edges, &(&1.prerequisite == id or &1.dependent == id))}
  end

  @spec hold(map(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def hold(document, target) do
    cond do
      Enum.any?(document.queues, &(&1.id == target)) ->
        {:ok, %{document | queues: Enum.map(document.queues, &if(&1.id == target, do: %{&1 | held: true}, else: &1))}}

      Enum.any?(document.items, &(&1.issue_id == target)) ->
        {:ok, update_item(document, target, &%{&1 | hold: :operator})}

      true ->
        {:error, :not_found}
    end
  end

  @spec release(map(), String.t(), map(), integer(), String.t()) :: {:ok, map()} | {:error, :not_found | :observation_unavailable}
  def release(document, target, observations, now, todo) do
    queue? = Enum.any?(document.queues, &(&1.id == target))
    selected = Enum.filter(document.items, &(&1.issue_id == target or &1.queue_id == target))

    cond do
      selected == [] and not queue? -> {:error, :not_found}
      Enum.any?(selected, &is_nil(observations[&1.issue_id])) -> {:error, :observation_unavailable}
      true -> {:ok, released(document, target, selected, observations, now, todo)}
    end
  end

  defp released(document, target, selected, observations, now, todo) do
    ids = MapSet.new(selected, & &1.issue_id)

    items = Enum.map(document.items, &release_item(&1, ids, observations, now, todo))

    %{
      document
      | items: items,
        queues: Enum.map(document.queues, fn queue -> if queue.id == target, do: %{queue | held: false}, else: queue end)
    }
  end

  defp release_item(item, ids, observations, now, todo) do
    if MapSet.member?(ids, item.issue_id) do
      promoted_at = if todo in observations[item.issue_id].labels, do: DateTime.from_unix!(now, :millisecond)
      %{item | override: nil, hold: nil, promoted_at: promoted_at}
    else
      item
    end
  end

  defp update_item(document, id, update), do: %{document | items: Enum.map(document.items, fn item -> if item.issue_id == id, do: update.(item), else: item end)}
end
