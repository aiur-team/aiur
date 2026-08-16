defmodule Aiur.ExecutorWakeInbox do
  @moduledoc false

  use GenServer

  alias Aiur.Config.Paths
  alias Aiur.DecisionLog
  alias Aiur.Fs
  alias Aiur.JsonStore

  @default_debounce_ms 2_000
  @default_max_records 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue(map(), GenServer.server()) :: :ok
  def enqueue(record, server \\ __MODULE__) when is_map(record), do: GenServer.call(server, {:enqueue, record})

  @spec wait(non_neg_integer(), GenServer.server()) :: {:ok, [map()]} | :timeout | {:error, term()}
  def wait(timeout_ms, server \\ __MODULE__) when is_integer(timeout_ms) and timeout_ms >= 0 do
    GenServer.call(server, {:wait, timeout_ms}, timeout_ms + 5_000)
  end

  @spec pending(GenServer.server()) :: [map()]
  def pending(server \\ __MODULE__), do: GenServer.call(server, :pending)

  @impl true
  def init(opts) do
    debounce_ms = Keyword.get(opts, :debounce_ms, Application.get_env(:aiur, :executor_wake_debounce_ms, @default_debounce_ms))
    path = Keyword.get(opts, :path, journal_path())
    cursor_path = Keyword.get(opts, :cursor_path, cursor_path())
    pending_path = Keyword.get(opts, :pending_path, pending_path())
    max_records = Keyword.get(opts, :max_records, Application.get_env(:aiur, :executor_wake_max_records, @default_max_records))

    with :ok <- DecisionLog.prepare(Path.dirname(path), path) do
      state = %{
        path: path,
        cursor_path: cursor_path,
        pending_path: pending_path,
        debounce_ms: debounce_ms,
        max_records: max_records,
        pending: read_pending(pending_path),
        timer: nil,
        waiters: %{}
      }

      if map_size(state.pending) > 0, do: send(self(), :flush)
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:enqueue, record}, _from, state) do
    key = {record["topic_class"], record["ticket"]}
    pending = Map.update(state.pending, key, record, &merge_record(&1, record))
    :ok = persist_pending(state.pending_path, pending)
    state = %{state | pending: pending} |> reset_flush_timer()
    {:reply, :ok, state}
  end

  def handle_call({:wait, timeout_ms}, from, state) do
    case unread_records(state) do
      {:ok, [_ | _] = records} ->
        :ok = advance_cursor(state.cursor_path, records)
        trim_consumed(state)
        {:reply, {:ok, records}, state}

      {:ok, []} ->
        {pid, _tag} = from
        monitor = Process.monitor(pid)
        timer = Process.send_after(self(), {:wait_timeout, from}, timeout_ms)
        {:noreply, %{state | waiters: Map.put(state.waiters, from, {monitor, timer})}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:pending, _from, state) do
    records =
      case unread_records(state) do
        {:ok, items} -> items
        _ -> []
      end

    {:reply, records, state}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush_pending(%{state | timer: nil})}

  def handle_info({:flush, token}, %{timer: {_timer, token}} = state),
    do: {:noreply, flush_pending(%{state | timer: nil})}

  def handle_info({:flush, _stale_token}, state), do: {:noreply, state}

  def handle_info({:wait_timeout, from}, state) do
    case Map.pop(state.waiters, from) do
      {nil, _waiters} ->
        {:noreply, state}

      {{monitor, _timer}, waiters} ->
        Process.demonitor(monitor, [:flush])
        GenServer.reply(from, :timeout)
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {dead, live} = Enum.split_with(state.waiters, fn {_from, {ref, _timer}} -> ref == monitor end)
    Enum.each(dead, fn {_from, {_ref, timer}} -> Process.cancel_timer(timer) end)
    {:noreply, %{state | waiters: Map.new(live)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = flush_pending(state)
    :ok
  end

  defp reset_flush_timer(state) do
    if state.timer do
      {timer, _token} = state.timer
      Process.cancel_timer(timer)
    end

    token = make_ref()
    timer = Process.send_after(self(), {:flush, token}, state.debounce_ms)
    %{state | timer: {timer, token}}
  end

  defp flush_pending(%{pending: pending} = state) when map_size(pending) == 0, do: serve_waiters(state)

  defp flush_pending(state) do
    records = state.pending |> Map.values() |> Enum.sort_by(&(&1["event_id"] || 0))

    case append_new_records(state.path, records) do
      :ok ->
        :ok = persist_pending(state.pending_path, %{})
        trim_consumed(state)
        serve_waiters(%{state | pending: %{}})

      {:error, _reason} ->
        reset_flush_timer(state)
    end
  end

  defp serve_waiters(%{waiters: waiters} = state) when map_size(waiters) == 0, do: state

  defp serve_waiters(state) do
    case unread_records(state) do
      {:ok, [_ | _] = records} ->
        :ok = advance_cursor(state.cursor_path, records)
        trim_consumed(state)

        Enum.each(state.waiters, fn {from, {monitor, timer}} ->
          Process.demonitor(monitor, [:flush])
          Process.cancel_timer(timer)
          GenServer.reply(from, {:ok, records})
        end)

        %{state | waiters: %{}}

      _ ->
        state
    end
  end

  defp unread_records(state) do
    cursor = read_cursor(state.cursor_path)

    case DecisionLog.replay(state.path, &validate_record/1) do
      {:ok, records, nil} -> {:ok, Enum.filter(records, &((&1["event_id"] || 0) > cursor))}
      {:ok, _records, corruption} -> {:error, corruption}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_record(%{"event_id" => id, "topic" => topic} = record) when is_integer(id) and is_binary(topic), do: {:ok, record}
  defp validate_record(_record), do: {:error, :invalid_executor_wake}

  defp append_new_records(path, records) do
    with {:ok, durable_ids} <- durable_event_ids(path) do
      records
      |> Enum.reject(&MapSet.member?(durable_ids, &1["event_id"]))
      |> Enum.reduce_while(:ok, fn record, :ok ->
        case DecisionLog.append(path, record) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp durable_event_ids(path) do
    case DecisionLog.replay(path, &validate_record/1) do
      {:ok, records, nil} -> {:ok, MapSet.new(records, & &1["event_id"])}
      {:ok, _records, corruption} -> {:error, corruption}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_record(previous, latest) do
    latest
    |> Map.put("count", (previous["count"] || 1) + 1)
    |> Map.put("first_seen_at", previous["first_seen_at"])
  end

  defp persist_pending(path, pending) do
    encoded = Map.new(pending, fn {{topic_class, ticket}, record} -> {Jason.encode!([topic_class, ticket]), record} end)
    JsonStore.write!(path, encoded)
  end

  defp read_pending(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{} = encoded} ->
        Map.new(encoded, fn {key, record} ->
          [topic_class, ticket] = Jason.decode!(key)
          {{topic_class, ticket}, record}
        end)

      _ ->
        %{}
    end
  end

  defp read_cursor(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{"last_seen_event_id" => id}} when is_integer(id) -> id
      _ -> 0
    end
  end

  defp advance_cursor(path, records) do
    id = max(read_cursor(path), records |> Enum.map(&(&1["event_id"] || 0)) |> Enum.max(fn -> 0 end))
    JsonStore.write!(path, %{"last_seen_event_id" => id})
  end

  defp trim_consumed(state) do
    cursor = read_cursor(state.cursor_path)

    with {:ok, records, nil} <- DecisionLog.replay(state.path, &validate_record/1) do
      unread = Enum.filter(records, &((&1["event_id"] || 0) > cursor))
      consumed = Enum.filter(records, &((&1["event_id"] || 0) <= cursor))
      consumed_limit = max(state.max_records - length(unread), 0)
      retained = Enum.take(consumed, -consumed_limit) ++ unread

      if length(retained) < length(records) do
        contents = Enum.map(retained, &[Jason.encode!(&1), "\n"])
        _ = Fs.atomic_write(state.path, contents, fsync: true, mode: 0o600)
      end
    end

    :ok
  end

  defp journal_path, do: Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.wakes.ndjson")
  defp cursor_path, do: Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.wakes.cursor.json")
  defp pending_path, do: Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.wakes.pending.json")
end
