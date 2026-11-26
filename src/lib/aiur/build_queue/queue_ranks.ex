defmodule Aiur.BuildQueue.QueueRanks do
  @moduledoc "Local set ordering, independent of ticket markers."

  alias Aiur.BuildQueue.{AttentionHealth, Events, Reconcile}

  @spec commit(map(), String.t(), non_neg_integer()) :: {:ok | {:error, atom()}, map()}
  def commit(state, name, at) do
    case order(state.document, name, at) do
      {:ok, document, []} -> persist(state, document)
      error -> {error, state}
    end
  end

  defp persist(state, document) do
    case state.store.save(document) do
      :ok ->
        Events.saved(state.document, document, :operator)
        Reconcile.write_hints(state.projections, state.holds, document, state.settings, state.observations)
        Phoenix.PubSub.broadcast(Aiur.PubSub, "build_queue:changed", {:build_queue_changed, state.status})
        {:ok, %{state | document: document}}

      {:error, _} ->
        {{:error, :store_unavailable}, AttentionHealth.store(%{state | status: :store_unavailable})}
    end
  end

  @spec order(map(), String.t(), non_neg_integer()) :: {:ok, map(), []} | {:error, atom()}
  def order(document, name, at) do
    queue = Enum.find(document.queues, &(&1.name == name))

    cond do
      is_nil(queue) ->
        {:error, :not_found}

      not is_integer(at) or at < 0 or at >= length(document.queues) ->
        {:error, :invalid_position}

      true ->
        queues = document.queues |> Enum.sort_by(&{&1.rank, &1.id}) |> Enum.reject(&(&1.id == queue.id)) |> List.insert_at(at, queue)
        queues = Enum.with_index(queues, &rank_queue/2)
        {:ok, %{document | queues: queues}, []}
    end
  end

  @spec creation(map(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def creation(document, previous, opts) do
    cond do
      not Keyword.has_key?(opts, :rank) ->
        {:ok, document}

      Enum.any?(previous.queues, &(&1.name == opts[:queue])) ->
        {:error, :rank_requires_new_queue}

      true ->
        with {:ok, document, []} <- order(document, Keyword.fetch!(opts, :queue), opts[:rank]), do: {:ok, document}
    end
  end

  defp rank_queue(%{rank: rank} = queue, rank), do: queue
  defp rank_queue(queue, rank), do: %{queue | rank: rank, generation: queue.generation + 1}
end
