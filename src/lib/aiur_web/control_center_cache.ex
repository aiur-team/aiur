defmodule AiurWeb.ControlCenterCache do
  @moduledoc """
  Serializes and briefly caches the expensive Executor Control Center payload.

  Every connected dashboard receives the same PubSub notifications. Without a
  shared cache, one event fans out into one Orchestrator and provider read per
  browser. This cache makes the first caller refresh the payload while the
  remaining callers reuse that result for a short bounded interval. Cache keys
  may include provider incarnations, so retained entries are also bounded.
  """

  use GenServer

  @max_entries 8
  @event_coalesce_ms 1_000

  @type loader :: (-> map())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, %{})
      name -> GenServer.start_link(__MODULE__, %{}, name: name)
    end
  end

  @spec fetch(GenServer.server(), term(), non_neg_integer(), loader()) :: map()
  def fetch(server, key, max_age_ms, loader)
      when is_integer(max_age_ms) and max_age_ms >= 0 and is_function(loader, 0) do
    GenServer.call(server, {:fetch, key, max_age_ms, loader}, :infinity)
  end

  @doc "Loads once for a shared provider event and refreshes the ordinary TTL entry with the same payload."
  @spec fetch_event(GenServer.server(), term(), term(), loader()) :: map()
  def fetch_event(server, key, event_key, loader) when is_function(loader, 0) do
    GenServer.call(server, {:fetch_event, key, event_key, loader}, :infinity)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:fetch, key, max_age_ms, loader}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    case Map.get(state, key) do
      %{loaded_at_ms: loaded_at_ms, payload: payload}
      when now_ms - loaded_at_ms < max_age_ms ->
        {:reply, payload, state}

      _other ->
        payload = loader.()

        entry = %{
          loaded_at_ms: System.monotonic_time(:millisecond),
          load_order: System.unique_integer([:monotonic, :positive]),
          payload: payload
        }

        {:reply, payload, state |> Map.put(key, entry) |> bound_entries()}
    end
  end

  def handle_call({:fetch_event, key, event_key, loader}, _from, state) do
    fenced_key = {:provider_event, key, event_key}
    now_ms = System.monotonic_time(:millisecond)

    case Map.get(state, fenced_key) do
      %{loaded_at_ms: loaded_at_ms, payload: payload}
      when now_ms - loaded_at_ms < @event_coalesce_ms ->
        {:reply, payload, state}

      _entry ->
        payload = loader.()
        entry = cache_entry(payload)

        next_state =
          state
          |> Map.put(key, entry)
          |> Map.put(fenced_key, entry)
          |> bound_entries()

        {:reply, payload, next_state}
    end
  end

  defp cache_entry(payload) do
    %{
      loaded_at_ms: System.monotonic_time(:millisecond),
      load_order: System.unique_integer([:monotonic, :positive]),
      payload: payload
    }
  end

  defp bound_entries(entries) when map_size(entries) <= @max_entries, do: entries

  defp bound_entries(entries) do
    entries
    |> Enum.sort_by(fn {_key, entry} -> Map.get(entry, :load_order, 0) end, :desc)
    |> Enum.take(@max_entries)
    |> Map.new()
  end
end
