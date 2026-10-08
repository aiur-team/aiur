defmodule Aiur.BuildOrder.History do
  @moduledoc "Repository-scoped durable history with serialized writes and ETS reads."
  use GenServer
  require Logger
  alias Aiur.BuildOrder.History.{Persistence, Row}
  alias Aiur.BuildOrder.ProviderHealth
  alias Aiur.Config.Paths
  @topic "build-order-history:changed"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}, shutdown: 10_000}
  @spec apply([Row.event()], keyword()) :: {:ok, map()} | {:error, term()}
  def apply(events, opts \\ []), do: call(opts, {:apply, events, Keyword.get(opts, :checkpoint)})
  @spec flush(keyword()) :: :ok | {:error, term()}
  def flush(opts \\ []), do: call(opts, :flush)
  @spec mark_complete(keyword()) :: :ok | {:error, term()}
  def mark_complete(opts \\ []), do: call(opts, :mark_complete)
  @spec snapshot(keyword()) :: {:ok, map()} | {:error, ProviderHealth.t()}
  def snapshot(opts \\ []), do: call(opts, :snapshot)
  @spec health(keyword()) :: ProviderHealth.t()
  def health(opts \\ []), do: read(opts, fn table -> :ets.lookup_element(table, :__health__, 2) end)
  @spec rows([pos_integer()], keyword()) :: {:ok, [Row.t()], ProviderHealth.t()} | {:error, ProviderHealth.t()}
  def rows(numbers, opts \\ []) do
    read(opts, &read_rows(&1, numbers))
    |> read_result()
  end

  defp read_rows(table, numbers) do
    health = :ets.lookup_element(table, :__health__, 2)
    if health.state == :healthy, do: {:ok, Enum.flat_map(numbers, &lookup_row(table, &1)), health}, else: {:error, health}
  end

  defp lookup_row(table, number), do: for({^number, row} <- :ets.lookup(table, number), do: row)

  @spec checkpoint(atom(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def checkpoint(key, opts \\ [])

  def checkpoint(key, opts) when key in [:backfill, :closed_since] do
    read(opts, fn table ->
      health = :ets.lookup_element(table, :__health__, 2)
      if writable?(health), do: {:ok, Map.fetch!(:ets.lookup_element(table, :__checkpoints__, 2), key)}, else: {:error, health}
    end)
    |> read_result()
  end

  def checkpoint(_key, _opts), do: {:error, :unknown_checkpoint}
  @spec writable?(ProviderHealth.t()) :: boolean()
  def writable?(%ProviderHealth{state: :healthy}), do: true
  def writable?(%ProviderHealth{state: :unavailable, failure: failure}), do: failure in [:history_corrupt, :history_rebuilding, :flush_failed]
  def writable?(_health), do: false
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = table(Keyword.get(opts, :name, __MODULE__))
    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])
    Process.put(:build_history_table, table)
    state = initial_state(opts) |> Map.merge(%{table: table, flush_ms: Keyword.get(opts, :flush_ms, 2_000), timer: nil, synced?: false})
    mirror(state, Map.values(state.rows))
    {:ok, schedule(state)}
  end

  defp initial_state(opts) do
    repository = Keyword.get_lazy(opts, :repository, &repository/0)

    base = %{
      rows: %{},
      checkpoints: %{backfill: nil, closed_since: nil},
      status: "ok",
      path: nil,
      repository: repository,
      dirty?: false,
      health: ProviderHealth.new(1, :healthy, false, failure: :backfill_pending)
    }

    with true <- github_repository?(repository), {:ok, dir} <- state_dir(opts), :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, "history.json")
      loaded(base, path, Persistence.load(path, repository))
    else
      false -> unavailable(base, :not_applicable)
      {:error, _reason} -> unavailable(base, :state_dir_unavailable)
    end
  end

  defp loaded(base, path, {:ok, data}) do
    state = Map.merge(base, Map.drop(data, [:generation, :complete])) |> Map.put(:path, path)
    observed = newest(Map.values(data.rows), nil)
    health = ProviderHealth.new(data.generation, :healthy, data.complete, observed_at: observed, last_success_at: persisted_at(path), failure: if(data.complete, do: nil, else: :backfill_pending))
    state = %{state | health: health}
    if data.status == "rebuilding", do: unavailable(state, :history_rebuilding), else: state
  end

  defp loaded(base, path, {:error, :history_corrupt}), do: %{unavailable(base, :history_corrupt) | path: path, status: "rebuilding", dirty?: true}
  defp loaded(base, path, {:error, failure}), do: %{unavailable(base, failure) | path: path}

  defp persisted_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> DateTime.from_unix!(stat.mtime)
      {:error, _reason} -> nil
    end
  end

  defp unavailable(state, failure), do: %{state | health: %{state.health | state: :unavailable, complete?: false, failure: failure}}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, if(state.health.state == :healthy, do: {:ok, %{rows: state.rows, health: state.health}}, else: {:error, state.health}), state}

  def handle_call({:apply, events, checkpoint}, _from, state) do
    with :ok <- writable(state), :ok <- validate_checkpoint(checkpoint), {:ok, events} <- validate_events(events) do
      rows = Enum.reduce(events, state.rows, &merge_event/2)
      changed = Enum.filter(Map.values(rows), &(Map.get(state.rows, &1.number) != &1))
      state = commit(state, changed, checkpoint)
      {:reply, {:ok, %{generation: state.health.generation, changed: numbers(changed)}}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:mark_complete, _from, state) do
    case writable(state) do
      :ok ->
        changed? = not state.health.complete?
        health = %{state.health | state: :healthy, complete?: true, failure: nil, generation: state.health.generation + if(changed?, do: 1, else: 0)}
        state = %{state | health: health, status: "ok", dirty?: state.dirty? or changed?}
        mirror(state, [])
        if changed?, do: broadcast(state, [])
        {:reply, :ok, schedule(state)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:flush, _from, state) do
    {result, state} = do_flush(state)
    {:reply, result, state}
  end

  defp merge_event(event, rows) do
    case Row.merge(Map.get(rows, event.number), event) do
      {:changed, row} -> Map.put(rows, event.number, row)
      :unchanged -> rows
    end
  end

  defp commit(state, changed_rows, checkpoint) do
    checkpoints = if is_nil(checkpoint), do: state.checkpoints, else: Map.put(state.checkpoints, elem(checkpoint, 0), elem(checkpoint, 1))
    changed? = changed_rows != []
    health = %{state.health | generation: state.health.generation + if(changed?, do: 1, else: 0), observed_at: newest(changed_rows, state.health.observed_at)}
    rows = Enum.reduce(changed_rows, state.rows, &Map.put(&2, &1.number, &1))
    state = %{state | rows: rows, health: health, checkpoints: checkpoints, dirty?: state.dirty? or changed? or checkpoints != state.checkpoints}
    mirror(state, changed_rows)
    if changed?, do: broadcast(state, numbers(changed_rows))
    schedule(state)
  end

  defp numbers(rows), do: Enum.sort(Enum.map(rows, & &1.number))
  defp newest(rows, initial), do: Enum.reduce(rows, initial, fn row, acc -> if is_nil(acc) or DateTime.compare(row.observed_at, acc) == :gt, do: row.observed_at, else: acc end)
  defp mirror(state, rows), do: :ets.insert(state.table, [{:__health__, state.health}, {:__checkpoints__, state.checkpoints} | Enum.map(rows, &{&1.number, &1})])

  defp broadcast(state, numbers) do
    if Process.whereis(Aiur.PubSub), do: Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:build_order_history_changed, %{generation: state.health.generation, changed: numbers, health: state.health}})
  end

  defp writable(state), do: if(writable?(state.health), do: :ok, else: {:error, state.health.failure})
  defp validate_checkpoint(nil), do: :ok
  defp validate_checkpoint({key, value}) when key in [:backfill, :closed_since], do: if(Persistence.json_map?(value), do: :ok, else: {:error, :invalid_checkpoint})
  defp validate_checkpoint(_checkpoint), do: {:error, :unknown_checkpoint}

  defp validate_events(events) when is_list(events) do
    Enum.reduce_while(Enum.with_index(events), {:ok, events}, fn {event, index}, result ->
      case Row.validate_event(event) do
        {:ok, _valid} -> {:cont, result}
        {:error, reason} -> {:halt, {:error, {:invalid_event, index, reason}}}
      end
    end)
  end

  defp validate_events(_events), do: {:error, {:invalid_event, 0, :invalid_batch}}

  @impl true
  def handle_info(:flush, state) do
    {_result, state} = do_flush(%{state | timer: nil})
    {:noreply, schedule(state)}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.debug("aiur_build_history helper_exit reason=#{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    case do_flush(state) do
      {:ok, _state} -> :ok
      {{:error, reason}, _state} -> Logger.warning("aiur_build_history terminate_flush_failed reason=#{inspect(reason)}")
    end
  end

  defp schedule(%{dirty?: true, timer: nil} = state), do: %{state | timer: Process.send_after(self(), :flush, state.flush_ms)}
  defp schedule(state), do: state
  defp do_flush(%{dirty?: false} = state), do: {:ok, state}

  defp do_flush(state) do
    case Persistence.write(state) do
      :ok ->
        failure =
          cond do
            state.status == "rebuilding" -> :history_rebuilding
            not state.health.complete? -> :backfill_pending
            true -> nil
          end

        state = %{state | dirty?: false, synced?: true, health: %{state.health | last_success_at: DateTime.utc_now(), failure: failure}}
        mirror(state, [])
        {:ok, state}

      {:error, reason} ->
        Logger.warning("aiur_build_history flush_failed reason=#{inspect(reason)}")
        state = %{state | health: %{state.health | failure: :flush_failed}}
        mirror(state, [])
        {{:error, reason}, schedule(state)}
    end
  end

  defp table(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :build_history_table)
      nil -> raise ArgumentError, "history process is not running"
    end
  end

  defp table(name), do: Module.concat(name, Mirror)
  defp read_result(%ProviderHealth{} = health), do: {:error, health}
  defp read_result(result), do: result
  defp missing, do: ProviderHealth.new(:unknown, :unavailable, false, failure: :history_not_running)

  defp read(opts, fun) do
    fun.(table(Keyword.get(opts, :server, __MODULE__)))
  rescue
    ArgumentError -> missing()
  end

  defp call(opts, message) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), message, :infinity)
  catch
    :exit, _reason -> {:error, missing()}
  end

  defp state_dir(opts), do: if(Keyword.has_key?(opts, :state_dir), do: {:ok, Keyword.fetch!(opts, :state_dir)}, else: Paths.build_history_state_dir())
  defp github_repository?(value), do: is_binary(value) and String.valid?(value) and Regex.match?(~r/\A[^\/\s]+\/[^\/\s]+\z/u, value)

  defp repository do
    Aiur.Tracker.project_identity()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end
end
