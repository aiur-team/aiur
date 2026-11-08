defmodule Aiur.BuildOrder.TicketTimelineCache do
  @moduledoc "Per-daemon cache of built ticket timeline segments and event high-water marks."
  use GenServer

  @max_tickets 256

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec get(term()) :: map() | nil
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @spec put(term(), map()) :: :ok
  def put(key, cache), do: GenServer.call(__MODULE__, {:put, key, cache})

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}, order: []}}

  @impl true
  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state.entries, key), state}

  def handle_call({:put, key, incoming}, _from, state) do
    existing = Map.get(state.entries, key, %{events: [], high_water: 0})
    appended = Enum.filter(incoming.events, &(event_id(&1) > existing.high_water))
    events = Enum.uniq_by(existing.events ++ appended, &event_id/1)
    merged = %{events: events, high_water: Enum.reduce(events, existing.high_water, &max(&2, event_id(&1)))}
    order = [key | List.delete(state.order, key)]
    {entries, order} = trim(Map.put(state.entries, key, merged), order)
    {:reply, :ok, %{state | entries: entries, order: order}}
  end

  defp trim(entries, order) when length(order) <= @max_tickets, do: {entries, order}

  defp trim(entries, order) do
    {key, rest} = List.pop_at(order, -1)
    trim(Map.delete(entries, key), rest)
  end

  defp event_id(%{id: id}) when is_integer(id), do: id
  defp event_id(_), do: 0
end
