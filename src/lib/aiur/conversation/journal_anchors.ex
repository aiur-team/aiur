defmodule Aiur.Conversation.JournalAnchors do
  @moduledoc false

  @spec write(map(), map()) :: {:ok, map(), list(), list()} | {:error, term()}
  def write(state, anchor) do
    with {:ok, ids} <- ids(state),
         :ok <- append(state, anchor, ids) do
      if state.outage or not MapSet.member?(ids, anchor["anchor_id"]) do
        Phoenix.PubSub.broadcast(state.pubsub, "conversation:" <> state.id, {:anchor_added, state.id, anchor})
      end

      if Process.whereis(Aiur.Conversation.AnchorResolver),
        do: GenServer.cast(Aiur.Conversation.AnchorResolver, {:anchor_persisted, anchor})

      {:ok, Map.put(state, :anchor_ids, MapSet.put(ids, anchor["anchor_id"])), [], []}
    end
  end

  defp ids(%{anchor_ids: ids}) when not is_nil(ids), do: {:ok, ids}

  defp ids(state) do
    validator = fn
      %{"anchor_id" => id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :invalid_anchor}
    end

    case Aiur.Journal.replay(Path.join(state.dir, "anchors.jsonl"), validator) do
      {:ok, ids, nil} ->
        with :ok <- state.store.sync_anchors(state.dir), do: {:ok, MapSet.new(ids)}

      {:ok, _, corruption} ->
        {:error, corruption}

      error ->
        error
    end
  end

  defp append(state, anchor, ids) do
    if MapSet.member?(ids, anchor["anchor_id"]),
      do: :ok,
      else: state.store.append_anchor_line(state.dir, anchor)
  end
end
