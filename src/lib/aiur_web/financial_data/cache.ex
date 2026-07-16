defmodule AiurWeb.FinancialData.Cache do
  @moduledoc false

  use GenServer

  alias AiurWeb.FinancialDataAccess

  @max_entries 8
  @authentication_required {:error, :authentication_required}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch!(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, %{entries: %{}})
      name -> GenServer.start_link(__MODULE__, %{entries: %{}}, name: name)
    end
  end

  @spec fetch(
          GenServer.server(),
          FinancialDataAccess.Context.t(),
          {String.t(), String.t()},
          atom(),
          term(),
          non_neg_integer(),
          (-> term())
        ) :: {:ok, term()} | {:error, :authentication_required | :provider_unavailable}
  def fetch(server, context, identity, source, key, max_age_ms, loader) do
    GenServer.call(server, {:fetch, context, identity, source, key, max_age_ms, loader}, :infinity)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(
        {:fetch, context, identity, source, key, max_age_ms, loader},
        {caller_pid, _tag},
        state
      ) do
    case FinancialDataAccess.identity(context) do
      {:ok, ^identity} ->
        state
        |> prune_stale_configuration()
        |> fetch_authorized(context, identity, source, key, max_age_ms, caller_pid, loader)

      _denied ->
        {:reply, @authentication_required, state}
    end
  end

  defp fetch_authorized(state, context, identity, source, key, max_age_ms, caller_pid, loader) do
    case FinancialDataAccess.identity(context) do
      {:ok, ^identity} ->
        cache_key = cache_key(identity, source, key)
        now_ms = System.monotonic_time(:millisecond)

        case get_in(state, [:entries, cache_key]) do
          %{loaded_at_ms: loaded_at_ms, payload: payload}
          when now_ms - loaded_at_ms < max_age_ms ->
            deliver_cached(state, context, identity, payload)

          _missing_or_expired ->
            load_and_maybe_cache(state, cache_key, context, identity, caller_pid, loader)
        end

      _denied ->
        {:reply, @authentication_required, state}
    end
  end

  defp load_and_maybe_cache(state, cache_key, context, identity, caller_pid, loader) do
    case safe_load(loader) do
      {:ok, payload} ->
        finalize_loaded(state, cache_key, context, identity, caller_pid, payload)

      :error ->
        {:reply, {:error, :provider_unavailable}, state}
    end
  end

  defp deliver_cached(state, context, identity, payload) do
    case FinancialDataAccess.identity(context) do
      {:ok, ^identity} -> {:reply, {:ok, payload}, state}
      _stale_or_denied -> {:reply, @authentication_required, prune_stale_configuration(state)}
    end
  end

  defp finalize_loaded(state, cache_key, context, identity, caller_pid, payload) do
    with {:ok, ^identity} <- FinancialDataAccess.identity(context),
         true <- is_pid(caller_pid) and Process.alive?(caller_pid) do
      entry = %{
        loaded_at_ms: System.monotonic_time(:millisecond),
        load_order: System.unique_integer([:monotonic, :positive]),
        payload: payload
      }

      entries = state.entries |> Map.put(cache_key, entry) |> bound_entries()
      {:reply, {:ok, payload}, %{state | entries: entries}}
    else
      _stale_or_disconnected ->
        {:reply, @authentication_required, prune_stale_configuration(state)}
    end
  end

  defp safe_load(loader) do
    {:ok, loader.()}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp prune_stale_configuration(state) do
    current_generation =
      case FinancialDataAccess.current_configuration_generation() do
        {:ok, generation} -> generation
        _denied -> nil
      end

    entries =
      Map.reject(state.entries, fn
        {{configuration_generation, _connection_generation, _source, _key}, _entry} ->
          configuration_generation != current_generation

        {_unexpected_key, _entry} ->
          true
      end)

    %{state | entries: entries}
  end

  defp cache_key({configuration_generation, connection_generation}, source, key),
    do: {configuration_generation, connection_generation, source, key}

  defp bound_entries(entries) when map_size(entries) <= @max_entries, do: entries

  defp bound_entries(entries) do
    entries
    |> Enum.sort_by(fn {_key, entry} -> entry.load_order end, :desc)
    |> Enum.take(@max_entries)
    |> Map.new()
  end
end
