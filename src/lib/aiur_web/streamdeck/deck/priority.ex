defmodule AiurWeb.Streamdeck.Deck.Priority do
  @moduledoc "Relative list-queue moves, with positions read back after a single write."
  alias AiurWeb.EndpointConfig

  @spec step(String.t(), :up | :down, pos_integer(), keyword()) :: {:ok, map() | :at_edge} | {:error, term()}
  def step(id, direction, ticks \\ 1, opts \\ []) when direction in [:up, :down] and is_integer(ticks) and ticks > 0 do
    with {:ok, queue, item} <- locate(read(opts), id), :ok <- editable(queue) do
      delta = if direction == :up, do: -ticks, else: ticks
      at = (item.position + delta) |> max(0) |> min(length(queue.items) - 1)

      move(id, queue, item, at, opts)
    end
  end

  defp move(_id, _queue, %{position: at}, at, _opts), do: {:ok, :at_edge}

  defp move(id, _queue, _item, at, opts) do
    reorder = Keyword.get(opts, :reorder_fun) || EndpointConfig.get(:streamdeck_reorder_fun) || (&Aiur.BuildQueue.reorder/2)

    with :ok <- normalize(reorder.(id, at)), {:ok, queue, item} <- locate(read(opts), id) do
      {:ok, %{queue: queue.name, position: item.position}}
    end
  end

  @spec positions(map()) :: map()
  def positions(%{snapshot: %{carried_age_ms: _age}}), do: %{}

  def positions(%{status: :running, queues: queues}) do
    for queue <- queues, item <- Map.get(queue, :items, []), into: %{}, do: {to_string(item.number), item.position}
  end

  def positions(_unavailable), do: %{}

  @spec decorate(map(), map()) :: map()
  def decorate(grid, positions) do
    Map.update(grid, :agents, [], fn agents -> Enum.map(agents, &Map.put(&1, :queue_position, positions[to_string(&1.identifier)])) end)
  end

  @spec message(term()) :: String.t()
  def message(:not_queued), do: "not in a queue"
  def message(:not_list), do: "plan order is fixed"
  def message(:disabled), do: "queue disabled"
  def message(:outcome_unknown), do: "outcome unknown"
  def message(:invalid_position), do: "invalid position"
  def message(reason) when is_atom(reason), do: Atom.to_string(reason)
  def message(reason), do: inspect(reason)

  defp read(opts) do
    read = Keyword.get(opts, :show_fun) || EndpointConfig.get(:streamdeck_build_queue_fun) || (&Aiur.BuildQueue.show/0)
    read.()
  end

  defp locate(%{snapshot: %{carried_age_ms: _age}}, _id), do: {:error, :read_timeout}

  defp locate(%{status: :running, queues: queues}, id) do
    Enum.find_value(queues, {:error, :not_queued}, fn queue ->
      case Enum.find(queue.items, &(to_string(&1.number) == id)) do
        nil -> nil
        item -> {:ok, queue, item}
      end
    end)
  end

  defp locate(%{status: status}, _id), do: {:error, status}
  defp editable(%{kind: :list}), do: :ok
  defp editable(_queue), do: {:error, :not_list}
  defp normalize({:unavailable, reason}), do: {:error, reason}
  defp normalize(result), do: result
end
