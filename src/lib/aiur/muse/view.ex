defmodule Aiur.Muse.View do
  @moduledoc "Session-scoped native view replay protection and item-kind tracking."

  @max_events 100_000
  @max_items 10_000
  @max_stream_bytes 4 * 1024 * 1024

  @spec new(String.t()) :: map()
  def new(session_id), do: %{session_id: session_id, cursor: nil, seen: MapSet.new(), items: %{}}

  @spec ingest(map(), map()) :: {:emit, map(), map()} | {:ignore, map()} | {:error, atom()}
  def ingest(state, %{"params" => %{"sessionId" => session_id}}) when session_id != state.session_id,
    do: {:ignore, state}

  def ingest(_state, %{"method" => "view/gap"}), do: {:error, :incomplete_native_view}

  def ingest(state, %{"method" => method, "params" => params} = frame) when is_map(params) do
    key = {replay_method(method), params["viewCursor"], params["itemId"] || get_in(params, ["item", "itemId"]), params["field"]}

    cond do
      params["viewCursor"] && MapSet.member?(state.seen, key) -> {:ignore, state}
      MapSet.size(state.seen) >= @max_events -> {:error, :native_view_history_limit}
      true -> apply_frame(state, frame, key)
    end
  end

  def ingest(state, _frame), do: {:ignore, state}

  defp apply_frame(state, %{"method" => method, "params" => %{"item" => item}} = frame, key)
       when method in ["item/started", "item/completed"] and is_map(item) do
    with %{"itemId" => id, "kind" => kind, "revision" => revision} when is_binary(id) and is_binary(kind) and is_integer(revision) <- item,
         :ok <- item_capacity(state.items, id) do
      previous = Map.get(state.items, id)

      if obsolete?(previous, revision, method) do
        {:ignore, state}
      else
        streamed = Map.get(previous || %{}, :streamed, "")
        retained = retained_text(method, streamed)
        state = put_in(state.items[id], %{kind: kind, revision: revision, method: method, streamed: retained})
        {:emit, %{payload: frame, muse_item_kind: kind, muse_streamed_text: streamed}, remember(state, frame, key)}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_native_item}
    end
  end

  defp apply_frame(state, %{"method" => "item/delta", "params" => %{"itemId" => id}} = frame, key) do
    case state.items[id] do
      %{kind: kind, method: "item/started"} ->
        with {:ok, state} <- remember_text(state, id, kind, frame["params"]) do
          {:emit, %{payload: frame, muse_item_kind: kind}, remember(state, frame, key)}
        end

      %{method: "item/completed"} ->
        {:ignore, state}

      nil ->
        {:error, :incomplete_native_view}
    end
  end

  defp apply_frame(state, frame, key), do: {:emit, %{payload: frame}, remember(state, frame, key)}

  # MSP publishes these aliases for the same approval item and view cursor.
  defp replay_method("approval/requested"), do: "approval/request"
  defp replay_method(method), do: method

  defp retained_text("item/completed", _streamed), do: ""
  defp retained_text(_method, streamed), do: streamed

  defp remember_text(state, id, "agentMessage", %{"field" => "text", "delta" => text}) when is_binary(text) do
    body = Map.get(state.items[id], :streamed, "") <> text

    if byte_size(body) <= @max_stream_bytes,
      do: {:ok, put_in(state.items[id].streamed, body)},
      else: {:error, :native_view_text_limit}
  end

  defp remember_text(state, _id, _kind, _params), do: {:ok, state}

  defp obsolete?(%{revision: previous}, revision, _method) when revision < previous, do: true
  defp obsolete?(%{revision: revision, method: "item/completed"}, revision, _method), do: true
  defp obsolete?(_previous, _revision, _method), do: false

  defp item_capacity(items, id) do
    if Map.has_key?(items, id) or map_size(items) < @max_items, do: :ok, else: {:error, :native_view_history_limit}
  end

  defp remember(state, %{"params" => %{"viewCursor" => cursor}}, key) when is_binary(cursor),
    do: %{state | cursor: cursor, seen: MapSet.put(state.seen, key)}

  defp remember(state, _frame, _key), do: state
end
