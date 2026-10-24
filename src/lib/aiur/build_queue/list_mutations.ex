defmodule Aiur.BuildQueue.ListMutations do
  @moduledoc "Pure, atomic edits of local lists; returns marker actions for the server's writer."
  alias Aiur.BuildQueue.{Model, QueueRanks, QueueTriggers, Sets}
  alias Aiur.BuildQueue.Model.{Edge, Item, Queue}
  alias Aiur.BuildQueue.Sources.ExecutorList

  @type result :: {:ok, Model.t(), [{:mark | :unmark, String.t()}]} | {:error, term()}

  @spec add(Model.t(), [String.t()], keyword(), DateTime.t()) :: result()
  def add(document, ids, opts, now) do
    with :ok <- validate_ids(ids),
         :ok <- ownership(document, ids),
         {:ok, queue} <- queue(document, Keyword.get(opts, :queue), now),
         {:ok, queue} <- QueueTriggers.add(queue, document, opts),
         {:ok, items, _, :current} <- ExecutorList.members(queue, document),
         :ok <- anchor_member(document, queue, items, ids, Keyword.get(opts, :after)),
         {:ok, at} <- position(Keyword.get(opts, :at, length(items)), length(items)),
         {:ok, edges} <- edges(ids, Keyword.get(opts, :after)) do
      added = Enum.map(ids, &%Item{issue_id: &1, queue_id: queue.id, position: 0, hold: nil, override: nil, promoted_at: nil, added_at: now})
      {before, following} = Enum.split(items, at)
      queues = if Enum.any?(document.queues, &(&1.id == queue.id)), do: document.queues, else: document.queues ++ [queue]

      with {:ok, ranked} <- QueueRanks.creation(%{document | queues: queues}, document, opts) do
        ranked = %{ranked | edges: Enum.uniq(ranked.edges ++ edges)}
        {:ok, replace_items(ranked, queue.id, before ++ added ++ following), Enum.map(ids, &{:mark, &1})}
      end
    end
  end

  @spec remove(Model.t(), String.t()) :: result()
  def remove(document, id) do
    with {:ok, item, queue} <- member(document, id),
         {:ok, items, _, :current} <- ExecutorList.members(queue, document) do
      document = %{document | edges: Enum.reject(document.edges, &(&1.source == :list and &1.dependent == item.issue_id))}
      {:ok, replace_items(document, queue.id, Enum.reject(items, &(&1.issue_id == id))), [{:unmark, id}]}
    end
  end

  @spec reorder(Model.t(), String.t(), non_neg_integer()) :: result()
  def reorder(document, id, at) do
    with {:ok, item, queue} <- member(document, id),
         {:ok, items, _, :current} <- ExecutorList.members(queue, document),
         {:ok, at} <- position(at, length(items) - 1) do
      reordered = items |> Enum.reject(&(&1.issue_id == id)) |> List.insert_at(at, item)
      {:ok, replace_items(document, queue.id, reordered), []}
    end
  end

  @spec add_edge(Model.t(), String.t(), String.t()) :: result()
  def add_edge(document, prerequisite, dependent) do
    with :ok <- validate_ids([prerequisite]),
         {:ok, _, _} <- member(document, dependent),
         {:ok, edges} <- edges([dependent], prerequisite) do
      {:ok, %{document | edges: Enum.uniq(document.edges ++ edges)}, []}
    end
  end

  defp validate_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &valid_id?/1) and length(Enum.uniq(ids)) == length(ids), do: :ok, else: {:error, :invalid_ids}
  end

  defp validate_ids(_), do: {:error, :invalid_ids}
  defp valid_id?(id) when is_binary(id), do: Regex.match?(~r/\A[1-9][0-9]*\z/, id)
  defp valid_id?(_), do: false

  defp ownership(document, ids) do
    case Enum.find(document.items, &(&1.issue_id in ids)) do
      nil -> :ok
      item -> {:error, {:already_queued, Enum.find(document.queues, &(&1.id == item.queue_id)).name}}
    end
  end

  defp queue(document, name, now) when is_binary(name) do
    if String.trim(name) == "" do
      {:error, :invalid_queue}
    else
      case Enum.find(document.queues, &(&1.name == name)) do
        nil -> new_queue(document, name, now)
        %Queue{kind: :list} = queue -> {:ok, queue}
        _ -> {:error, :not_list}
      end
    end
  end

  defp queue(_, _, _), do: {:error, :invalid_queue}

  defp new_queue(document, name, now) do
    with {:ok, id} <- queue_id(document), do: {:ok, %Queue{id: id, name: name, rank: Sets.next_rank(document), kind: :list, root: nil, held: false, generation: 0, created_at: now}}
  end

  @spec queue_id(Model.t()) :: {:ok, String.t()} | {:error, :queue_limit}
  def queue_id(document) do
    used = MapSet.new(document.queues, & &1.id)

    id =
      Enum.find_value(0..65_535, fn n ->
        candidate = ("q-" <> String.pad_leading(Integer.to_string(n, 16), 4, "0")) |> String.downcase()
        if not MapSet.member?(used, candidate), do: candidate
      end)

    if id, do: {:ok, id}, else: {:error, :queue_limit}
  end

  defp member(document, id) do
    case Enum.find(document.items, &(&1.issue_id == id)) do
      nil ->
        {:error, :not_queued}

      item ->
        case Enum.find(document.queues, &(&1.id == item.queue_id)) do
          %Queue{kind: :list} = queue -> {:ok, item, queue}
          _ -> {:error, :not_list}
        end
    end
  end

  defp position(at, maximum) when is_integer(at) and at >= 0 and at <= maximum, do: {:ok, at}
  defp position(_, _), do: {:error, :invalid_position}

  defp anchor_member(_document, _queue, _items, _ids, nil), do: :ok

  defp anchor_member(document, queue, _items, ids, prerequisite) do
    if Enum.any?(ids, &(&1 == prerequisite)) or Enum.any?(document.items, &(&1.queue_id == queue.id and &1.issue_id == prerequisite)),
      do: :ok,
      else: {:error, :anchor_not_in_queue}
  end

  defp edges(_ids, nil), do: {:ok, []}

  defp edges(ids, prerequisite) do
    dependents = if prerequisite in ids, do: Enum.reject(ids, &(&1 == prerequisite)), else: ids

    cond do
      prerequisite in ids and dependents == [] ->
        {:error, :self_edge}

      not valid_id?(prerequisite) ->
        {:error, :invalid_ids}

      true ->
        edges = Enum.map(dependents, &%Edge{prerequisite: prerequisite, dependent: &1, source: :list})
        {:ok, edges}
    end
  end

  defp replace_items(document, queue_id, items) do
    others = Enum.reject(document.items, &(&1.queue_id == queue_id))
    ordered = Enum.with_index(items, fn item, index -> %{item | position: index} end)
    %{document | items: others ++ ordered}
  end
end
