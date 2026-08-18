defmodule Aiur.ExecutorWakeInbox do
  @moduledoc false

  use GenServer

  require Logger

  alias Aiur.Alerts
  alias Aiur.DecisionLog
  alias Aiur.Executor.Claims
  alias Aiur.Executor.StatePaths
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

  @doc """
  Advances the shared cursor past `records`, with **no ownership check**.

  Internal and test use only. Every consumer path must go through
  `acknowledge_as/3`, which is the only form that respects the lease; calling
  this directly bypasses the lease entirely and lets two consumers split the
  stream between them.
  """
  @spec acknowledge([map()], GenServer.server()) :: :ok
  def acknowledge(records, server \\ __MODULE__) when is_list(records), do: GenServer.call(server, {:acknowledge, records})

  @doc """
  Advances the shared cursor on behalf of the leased owner.

  A non-owner is refused with `{:error, {:not_owner, owner}}` and the cursor
  does not move, so two consumers cannot silently split the stream; a non-owner
  reads through `wait/2` or `pending/1` instead, which never move the cursor.

  The ownership check runs inside the claim store's lock, so a revoke or an
  expiry cannot land between the check and the roster evidence write. The
  cursor advance happens right after, in this GenServer, outside that lock —
  serialized here by the single inbox process, not by a cross-process critical
  section spanning both. It also writes the roster's consumption evidence:
  `last_acknowledged_at` has to come from the path that actually consumes, or
  the real consumer looks permanently `unknown` while a stalled one looks
  identical.
  """
  @spec acknowledge_as(String.t(), [map()], GenServer.server()) :: :ok | {:error, term()}
  def acknowledge_as(consumer_id, records, server \\ __MODULE__) when is_binary(consumer_id) and is_list(records) do
    GenServer.call(server, {:acknowledge_as, consumer_id, records})
  end

  @spec pending(GenServer.server()) :: [map()]
  def pending(server \\ __MODULE__), do: GenServer.call(server, :pending)

  @doc "The shared cursor: the highest wake id an owner has acknowledged."
  @spec cursor(GenServer.server()) :: non_neg_integer()
  def cursor(server \\ __MODULE__), do: GenServer.call(server, :cursor)

  @impl true
  def init(opts) do
    debounce_ms = Keyword.get(opts, :debounce_ms, Application.get_env(:aiur, :executor_wake_debounce_ms, @default_debounce_ms))
    path = Keyword.get(opts, :path, journal_path())
    cursor_path = Keyword.get(opts, :cursor_path, cursor_path())
    pending_path = Keyword.get(opts, :pending_path, pending_path())
    max_records = Keyword.get(opts, :max_records, Application.get_env(:aiur, :executor_wake_max_records, @default_max_records))

    StatePaths.ensure()

    with :ok <- DecisionLog.prepare(Path.dirname(path), path),
         {:ok, pending} <- read_pending(pending_path),
         {:ok, next_wake_id} <- next_wake_id(path, pending, cursor_path) do
      state = %{
        path: path,
        cursor_path: cursor_path,
        pending_path: pending_path,
        debounce_ms: debounce_ms,
        max_records: max_records,
        pending: pending,
        next_wake_id: next_wake_id,
        timer: nil,
        waiters: %{}
      }

      if map_size(state.pending) > 0, do: send(self(), :flush)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:enqueue, record}, _from, state) do
    key = {record["topic_class"], record["ticket"]}

    {pending, next_wake_id} =
      case Map.fetch(state.pending, key) do
        {:ok, previous} ->
          {Map.put(state.pending, key, merge_record(previous, record)), state.next_wake_id}

        :error ->
          assigned = Map.put(record, "wake_id", state.next_wake_id)
          {Map.put(state.pending, key, assigned), state.next_wake_id + 1}
      end

    :ok = persist_pending(state.pending_path, pending)
    state = %{state | pending: pending, next_wake_id: next_wake_id} |> reset_flush_timer()
    {:reply, :ok, state}
  end

  def handle_call({:wait, timeout_ms}, from, state) do
    case unread_records(state) do
      {:ok, [_ | _] = records} ->
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

  def handle_call({:acknowledge, records}, _from, state) do
    :ok = advance_cursor(state.cursor_path, records)
    trim_consumed(state)
    {:reply, :ok, state}
  end

  def handle_call({:acknowledge_as, consumer_id, records}, _from, state) do
    highest = records |> Enum.map(& &1["wake_id"]) |> Enum.max(fn -> read_cursor(state.cursor_path) end)

    case Claims.record_acknowledgement(consumer_id, highest) do
      {:ok, _entry} ->
        :ok = advance_cursor(state.cursor_path, records)
        trim_consumed(state)
        {:reply, :ok, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:cursor, _from, state), do: {:reply, read_cursor(state.cursor_path), state}

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
    records = state.pending |> Map.values() |> Enum.sort_by(& &1["wake_id"])

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
      {:ok, records, nil} -> {:ok, Enum.filter(records, &(&1["wake_id"] > cursor))}
      {:ok, _records, corruption} -> {:error, corruption}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_record(%{"wake_id" => wake_id, "event_id" => event_id, "topic" => topic} = record)
       when is_integer(wake_id) and wake_id > 0 and (is_integer(event_id) or is_nil(event_id)) and is_binary(topic),
       do: {:ok, record}

  defp validate_record(_record), do: {:error, :invalid_executor_wake}

  defp append_new_records(path, records) do
    with {:ok, durable_ids} <- durable_wake_ids(path) do
      records
      |> Enum.reject(&MapSet.member?(durable_ids, &1["wake_id"]))
      |> Enum.reduce_while(:ok, &append_record(path, &1, &2))
    end
  end

  defp append_record(path, record, :ok) do
    case DecisionLog.append(path, record) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp durable_wake_ids(path) do
    case DecisionLog.replay(path, &validate_record/1) do
      {:ok, records, nil} -> {:ok, MapSet.new(records, & &1["wake_id"])}
      {:ok, _records, corruption} -> {:error, corruption}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_record(previous, latest) do
    latest
    |> Map.put("wake_id", previous["wake_id"])
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
        decode_pending(encoded)

      {:ok, _wrong_shape} ->
        {:error, :invalid_executor_wake_pending_store}

      {:error, reason} ->
        {:error, {:executor_wake_pending_store_unavailable, reason}}
    end
  end

  defp decode_pending(encoded) do
    Enum.reduce_while(encoded, {:ok, %{}}, fn {encoded_key, record}, {:ok, pending} ->
      with {:ok, key} <- decode_pending_key(encoded_key),
           false <- Map.has_key?(pending, key),
           {:ok, record} <- validate_pending_record(key, record) do
        {:cont, {:ok, Map.put(pending, key, record)}}
      else
        _invalid -> {:halt, {:error, :invalid_executor_wake_pending_store}}
      end
    end)
  end

  defp decode_pending_key(encoded_key) when is_binary(encoded_key) do
    case Jason.decode(encoded_key) do
      {:ok, [topic_class, ticket]}
      when is_binary(topic_class) and (is_binary(ticket) or is_nil(ticket)) ->
        {:ok, {topic_class, ticket}}

      _invalid ->
        :error
    end
  end

  defp decode_pending_key(_encoded_key), do: :error

  defp validate_pending_record({topic_class, ticket}, record) do
    with {:ok, record} <- validate_record(record),
         true <- record["topic_class"] == topic_class and record["ticket"] == ticket do
      {:ok, record}
    else
      _invalid -> :error
    end
  end

  defp next_wake_id(path, pending, cursor_path) do
    case DecisionLog.replay(path, &validate_record/1) do
      {:ok, records, nil} ->
        durable_ids = Enum.map(records, & &1["wake_id"])
        pending_ids = pending |> Map.values() |> Enum.map(& &1["wake_id"])
        {:ok, Enum.max([read_cursor(cursor_path) | durable_ids ++ pending_ids]) + 1}

      {:ok, _records, corruption} ->
        {:error, corruption}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_cursor(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{"last_seen_wake_id" => id}} when is_integer(id) -> id
      _ -> 0
    end
  end

  defp advance_cursor(path, records) do
    id = max(read_cursor(path), records |> Enum.map(& &1["wake_id"]) |> Enum.max(fn -> 0 end))
    JsonStore.write!(path, %{"last_seen_wake_id" => id})
  end

  # Recording is unconditional now, so an unattended run appends wake records
  # that nobody will ever acknowledge. Dropping only consumed records left the
  # ledger unbounded in exactly that case, which is the growth #1661 is about.
  # The retained set is therefore capped at `max_records` outright: consumed
  # records are evicted first and only then the oldest unread, so the bound
  # holds with or without a consumer.
  #
  # Evicting an unread record loses a wake, so it is never silent — it is logged
  # with the count and the id range, and the durable cursor is advanced past the
  # dropped range so a consumer's next read is honest about where the stream now
  # begins rather than replaying a gap it cannot fill.
  defp trim_consumed(state) do
    cursor = read_cursor(state.cursor_path)

    with {:ok, records, nil} <- DecisionLog.replay(state.path, &validate_record/1) do
      unread = Enum.filter(records, &(&1["wake_id"] > cursor))
      consumed = Enum.filter(records, &(&1["wake_id"] <= cursor))
      retained_unread = Enum.take(unread, -state.max_records)
      consumed_limit = max(state.max_records - length(retained_unread), 0)
      retained = Enum.take(consumed, -consumed_limit) ++ retained_unread

      if length(retained) < length(records) do
        contents = Enum.map(retained, &[Jason.encode!(&1), "\n"])
        _ = Fs.atomic_write(state.path, contents, fsync: true, mode: 0o600)
      end

      report_dropped_unread(state, unread -- retained_unread)
    end

    :ok
  end

  defp report_dropped_unread(_state, []), do: :ok

  defp report_dropped_unread(state, dropped) do
    ids = Enum.map(dropped, & &1["wake_id"])
    :ok = advance_cursor(state.cursor_path, dropped)

    message =
      "Executor wake ledger overflowed its #{state.max_records}-record bound; " <>
        "#{length(dropped)} unread wakes (ids #{Enum.min(ids)}-#{Enum.max(ids)}) were evicted and will never be delivered."

    Logger.warning(
      "aiur_executor_wake_inbox phase=unread_evicted count=#{length(dropped)} " <>
        "first_wake_id=#{Enum.min(ids)} last_wake_id=#{Enum.max(ids)} max_records=#{state.max_records}"
    )

    safe_overflow_alert(message)
  end

  # Losing a wake is exactly the class of event an operator must be told about;
  # a daemon log line is effectively silent. The alert never carries record
  # content, only counts and ids, so the identifier-only boundary holds.
  defp safe_overflow_alert(message) do
    if Application.get_env(:aiur, :executor_wake_overflow_alerts?, true) do
      _ = Alerts.emit_custom("executor.wakes.overflow", message, needs_attention: false, severity: "warning")
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp journal_path, do: StatePaths.wakes_path()
  defp cursor_path, do: StatePaths.cursor_path()
  defp pending_path, do: StatePaths.pending_path()
end
