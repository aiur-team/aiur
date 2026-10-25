defmodule AiurWeb.ControlCenterCache do
  @moduledoc """
  Briefly caches the expensive Operator Control Center payload. Loaders run in
  monitored tasks; ordinary reads and identical provider events share loads.
  Forced reads and distinct events read anew without blocking other keys.
  Provider events also refresh the ordinary TTL entry. Retained entries
  are bounded because keys may include provider incarnations. A failed load
  re-serves the last payload marked `stale: true` with its `stale_age_ms`.
  `:clock`, `:boot_elapsed_ms` and `:load_timeout_ms` are test seams.
  """

  use GenServer

  require Logger

  @max_entries 8
  @event_coalesce_ms 1_000
  @call_timeout_ms 5_000
  @load_timeout_ms 4_000
  @startup_observation_timeout_ms 600_000

  @type loader :: (-> map())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "How long a load may run before it is killed; provider deadlines must fit inside it."
  @spec load_timeout_ms() :: pos_integer()
  def load_timeout_ms, do: @load_timeout_ms

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
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    boot_elapsed_ms = Keyword.get(opts, :boot_elapsed_ms, &Aiur.Boot.elapsed_ms/0)

    {:ok,
     %{
       entries: %{},
       loads: %{},
       clock: clock,
       boot_elapsed_ms: boot_elapsed_ms,
       load_timeout_ms: Keyword.get(opts, :load_timeout_ms, @load_timeout_ms),
       startup_observation_timeout_ms: Keyword.get(opts, :startup_observation_timeout_ms, @startup_observation_timeout_ms)
     }}
  end

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
    now_ms = state.clock.()

    case Map.get(state.entries, entry_key) do
      %{loaded_at_ms: loaded_at_ms, payload: payload} = entry when now_ms - loaded_at_ms < max_age_ms ->
        {:reply, startup_marker(payload, entry_key, entry, state), state}

      _entry ->
        load_key = if max_age_ms == 0, do: make_ref(), else: entry_key

        load =
          case Map.get(state.loads, load_key) do
            nil ->
              task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, loader)
              timer = Process.send_after(self(), {:load_timeout, task.ref}, state.load_timeout_ms)
              %{task: task, timer: timer, key: key, load_order: System.unique_integer([:monotonic, :positive]), waiters: [], entry_keys: []}

            pending ->
              pending
          end

        load = %{load | waiters: [from | load.waiters], entry_keys: Enum.uniq([key, entry_key | load.entry_keys])}
        {:noreply, put_in(state, [:loads, load_key], load)}
    end
  end

  defp finish_load(state, ref, result) do
    case Enum.find(state.loads, fn {_key, load} -> load.task.ref == ref end) do
      nil ->
        state

      {load_key, load} ->
        Process.cancel_timer(load.timer)
        Process.exit(load.task.pid, :kill)
        Process.demonitor(ref, [:flush])
        {payload, entries} = load_result(result, load, state.entries, state.clock.())
        payload = startup_marker(payload, load.key, Map.get(entries, load.key), state)
        Enum.each(load.waiters, &GenServer.reply(&1, payload))
        %{state | entries: entries, loads: Map.delete(state.loads, load_key)}
    end
  end

  defp load_result({:ok, payload}, load, entries, now_ms) do
    entry = %{
      loaded_at_ms: now_ms,
      load_order: load.load_order,
      payload: payload,
      fleet_observed?: fleet_observed?(payload) or previous_fleet_observed?(Map.get(entries, load.key))
    }

    entries = Enum.reduce(load.entry_keys, entries, &put_newer_entry(&2, &1, entry))
    {payload, bound_entries(entries)}
  end

  defp load_result({:error, reason}, load, entries, now_ms) do
    payload =
      case Map.get(entries, load.key) do
        %{payload: payload, loaded_at_ms: loaded_at_ms} ->
          Logger.warning("control center payload load failed (#{inspect(reason)}); serving the last loaded payload")
          payload |> Map.put(:stale, true) |> Map.put(:stale_age_ms, now_ms - loaded_at_ms)

        nil ->
          unavailable(reason)
      end

    {payload, entries}
  end

  defp startup_marker(payload, key, entry, state) do
    elapsed_ms = state.boot_elapsed_ms.()

    cond do
      previous_fleet_observed?(entry) or not dashboard_payload?(payload, key) ->
        payload |> Map.delete(:fleet_startup_pending?) |> Map.delete(:fleet_startup_timed_out?)

      elapsed_ms < state.startup_observation_timeout_ms ->
        payload |> Map.put(:fleet_startup_pending?, true) |> Map.delete(:fleet_startup_timed_out?)

      true ->
        payload |> Map.put(:fleet_startup_timed_out?, true) |> Map.delete(:fleet_startup_pending?)
    end
  end

  defp dashboard_payload?(payload, key) do
    is_map(Map.get(payload, :provider_health)) or is_map(Map.get(payload, :units)) or
      (dashboard_cache_key?(key) and match?(%{error: {:cache_unavailable, _reason}}, payload))
  end

  defp dashboard_cache_key?(
         {%{fleet: _fleet, membership: _membership, activity: _activity, tickets: _tickets}, _orchestrator, _decision_store, _decision_metrics, _recent_merge_store, _snapshot_timeout_ms}
       ),
       do: true

  defp dashboard_cache_key?(_key), do: false

  defp fleet_observed?(payload) do
    get_in(payload, [:provider_health, :fleet]) == :ok and
      not is_map(get_in(payload, [:fleet, :error]))
  end

  defp previous_fleet_observed?(%{fleet_observed?: true}), do: true
  defp previous_fleet_observed?(_entry), do: false

  defp unavailable(reason), do: %{stale: true, error: {:cache_unavailable, reason}}

  # Completion order cannot let a pre-event read overwrite a newer refresh.
  defp put_newer_entry(entries, key, entry) do
    case Map.get(entries, key) do
      %{load_order: order} when order > entry.load_order -> entries
      _entry -> Map.put(entries, key, entry)
    end
  end

  defp bound_entries(entries) when map_size(entries) <= @max_entries, do: entries

  defp bound_entries(entries) do
    entries
    |> Enum.sort_by(fn {_key, entry} -> Map.get(entry, :load_order, 0) end, :desc)
    |> Enum.take(@max_entries)
    |> Map.new()
  end
end
