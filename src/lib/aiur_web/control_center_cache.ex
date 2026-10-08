defmodule AiurWeb.ControlCenterCache do
  @moduledoc """
  Briefly caches the expensive Operator Control Center payload. Loaders run in
  monitored tasks; callers for the same key share a load without blocking other
  keys. Provider events also refresh the ordinary TTL entry. Retained entries
  are bounded because keys may include provider incarnations.
  """

  use GenServer

  @max_entries 8
  @event_coalesce_ms 1_000
  @call_timeout_ms 5_000
  @load_timeout_ms 4_900

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
    GenServer.call(server, {:fetch, key, max_age_ms, loader}, @call_timeout_ms)
  catch
    :exit, reason -> unavailable(reason)
  end

  @doc "Loads once for a shared provider event and refreshes the ordinary TTL entry with the same payload."
  @spec fetch_event(GenServer.server(), term(), term(), loader()) :: map()
  def fetch_event(server, key, event_key, loader) when is_function(loader, 0) do
    GenServer.call(server, {:fetch_event, key, event_key, loader}, @call_timeout_ms)
  catch
    :exit, reason -> unavailable(reason)
  end

  @impl true
  def init(_state), do: {:ok, %{entries: %{}, loads: %{}}}

  @impl true
  def handle_call({:fetch, key, max_age_ms, loader}, from, state),
    do: fetch_or_load(key, key, max_age_ms, loader, from, state)

  def handle_call({:fetch_event, key, event_key, loader}, from, state),
    do: fetch_or_load(key, {:provider_event, key, event_key}, @event_coalesce_ms, loader, from, state)

  @impl true
  def handle_info({ref, payload}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_load(state, ref, {:ok, payload})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: {:noreply, finish_load(state, ref, {:error, reason})}

  def handle_info({:load_timeout, ref}, state),
    do: {:noreply, finish_load(state, ref, {:error, :timeout})}

  defp fetch_or_load(key, entry_key, max_age_ms, loader, from, state) do
    now_ms = System.monotonic_time(:millisecond)

    case Map.get(state.entries, entry_key) do
      %{loaded_at_ms: loaded_at_ms, payload: payload} when now_ms - loaded_at_ms < max_age_ms ->
        {:reply, payload, state}

      _entry ->
        load =
          case Map.get(state.loads, key) do
            nil ->
              task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, loader)
              timer = Process.send_after(self(), {:load_timeout, task.ref}, @load_timeout_ms)
              %{task: task, timer: timer, waiters: [], entry_keys: []}

            pending ->
              pending
          end

        load = %{load | waiters: [from | load.waiters], entry_keys: Enum.uniq([key, entry_key | load.entry_keys])}
        {:noreply, put_in(state, [:loads, key], load)}
    end
  end

  defp finish_load(state, ref, result) do
    case Enum.find(state.loads, fn {_key, load} -> load.task.ref == ref end) do
      nil ->
        state

      {key, load} ->
        Process.cancel_timer(load.timer)
        Process.exit(load.task.pid, :kill)
        Process.demonitor(ref, [:flush])
        {payload, entries} = load_result(result, key, load.entry_keys, state.entries)
        Enum.each(load.waiters, &GenServer.reply(&1, payload))
        %{state | entries: entries, loads: Map.delete(state.loads, key)}
    end
  end

  defp load_result({:ok, payload}, _key, entry_keys, entries) do
    entry = cache_entry(payload)
    entries = Enum.reduce(entry_keys, entries, &Map.put(&2, &1, entry))
    {payload, bound_entries(entries)}
  end

  defp load_result({:error, reason}, key, _entry_keys, entries) do
    payload =
      case Map.get(entries, key) do
        %{payload: payload} -> Map.put(payload, :stale, true)
        nil -> unavailable(reason)
      end

    {payload, entries}
  end

  defp unavailable(reason), do: %{stale: true, error: {:cache_unavailable, reason}}

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
