defmodule Aiur.ExecutorWakeInbox do
  @moduledoc false

  use GenServer

  alias Aiur.Executor.Claims
  alias Aiur.Executor.StatePaths
  alias Aiur.ExecutorWakeInbox.{Recovery, Storage}
  alias Aiur.Journal

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
    wait(timeout_ms, nil, false, server)
  end

  @spec wait(non_neg_integer(), String.t() | nil, boolean(), GenServer.server()) ::
          {:ok, [map()]} | :timeout | :superseded | {:error, term()}
  def wait(timeout_ms, consumer_id, defer_ack?, server \\ __MODULE__)
      when is_integer(timeout_ms) and timeout_ms >= 0 and (is_binary(consumer_id) or is_nil(consumer_id)) and
             is_boolean(defer_ack?) do
    GenServer.call(server, {:wait, timeout_ms, consumer_id, defer_ack?}, timeout_ms + 5_000)
  end

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
    GenServer.call(server, {:acknowledge_as, consumer_id, records}, claim_call_timeout_ms())
  end

  # An acknowledgement blocks on the cross-process claims lock for as long as
  # that lock's own bounded retry allows, and then replays the journal to trim
  # it. The default five-second `GenServer.call` budget is not longer than the
  # default five-second lock retry, so a genuinely contended acknowledgement
  # raced its own caller: the CLI exited with a raw GenServer timeout and no exit
  # marker at all, while this process went on to advance the cursor for a caller
  # that was already gone. Give the call a budget that strictly dominates every
  # bound inside it (#2600).
  defp claim_call_timeout_ms, do: max(Claims.lock_retry_budget().timeout_ms, Claims.call_timeout_ms()) + 30_000

  @doc """
  Advances the shared cursor through one exact durable wake id.

  This is the explicit recovery path for an owner that covered a wake window
  outside `executor-wait`. It uses the same lease check as normal
  acknowledgement, refuses ids beyond or absent from the durable journal, and
  leaves every newer wake unread.
  """
  @spec fast_forward_as(String.t(), non_neg_integer(), GenServer.server()) ::
          {:ok, %{from: non_neg_integer(), through: non_neg_integer(), acknowledged_count: non_neg_integer(), pending_count: non_neg_integer()}}
          | {:error, term()}
  def fast_forward_as(consumer_id, wake_id, server \\ __MODULE__)
      when is_binary(consumer_id) and is_integer(wake_id) and wake_id >= 0 do
    GenServer.call(server, {:fast_forward_as, consumer_id, wake_id}, claim_call_timeout_ms())
  end

  @spec pending(GenServer.server()) :: [map()]
  def pending(server \\ __MODULE__), do: GenServer.call(server, :pending)

  @doc "The shared cursor: the highest wake id an owner has acknowledged."
  @spec cursor(GenServer.server()) :: non_neg_integer()
  def cursor(server \\ __MODULE__), do: GenServer.call(server, :cursor)

  @doc "The cursor and unread count for operator status surfaces."
  @spec stats(GenServer.server()) :: {:ok, %{cursor: non_neg_integer(), pending_count: non_neg_integer()}} | {:error, term()}
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    debounce_ms = Keyword.get(opts, :debounce_ms, Application.get_env(:aiur, :executor_wake_debounce_ms, @default_debounce_ms))
    path = Keyword.get(opts, :path, journal_path())
    cursor_path = Keyword.get(opts, :cursor_path, cursor_path())
    pending_path = Keyword.get(opts, :pending_path, pending_path())
    max_records = Keyword.get(opts, :max_records, Application.get_env(:aiur, :executor_wake_max_records, @default_max_records))

    alert_fun = Keyword.get(opts, :alert_fun, &Storage.safe_alert/3)

    StatePaths.ensure()

    with :ok <- Journal.prepare(Path.dirname(path), path),
         {:ok, pending} <- Storage.read_pending(pending_path),
         {:ok, summary} <- Storage.journal_summary(path, pending, cursor_path, alert_fun) do
      state = %{
        path: path,
        cursor_path: cursor_path,
        pending_path: pending_path,
        debounce_ms: debounce_ms,
        max_records: max_records,
        pending: pending,
        next_wake_id: summary.next_wake_id,
        cursor: summary.cursor,
        pending_count: summary.pending_count,
        timer: nil,
        waiters: %{},
        alert_fun: alert_fun,
        flush_failures: 0,
        trim_alerted?: false
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

    :ok = Storage.persist_pending(state.pending_path, pending)
    state = %{state | pending: pending, next_wake_id: next_wake_id} |> ensure_flush_timer()
    {:reply, :ok, state}
  end

  def handle_call({:wait, timeout_ms, consumer_id, defer_ack?}, from, state) do
    case Storage.unread_records(state) do
      {:ok, [_ | _] = records} ->
        {:reply, {:ok, records}, state}

      {:ok, []} ->
        key = waiter_key(from, consumer_id, defer_ack?)
        state = supersede_waiter(state, key, defer_ack?)
        {pid, _tag} = from
        monitor = Process.monitor(pid)
        timer = Process.send_after(self(), {:wait_timeout, key}, timeout_ms)
        waiter = %{from: from, monitor: monitor, timer: timer}
        {:noreply, %{state | waiters: Map.put(state.waiters, key, waiter)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:acknowledge_as, consumer_id, records}, _from, state) do
    highest = records |> Enum.map(& &1["wake_id"]) |> Enum.max(fn -> state.cursor end)

    case acknowledge_records_as(state, consumer_id, records, highest) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:fast_forward_as, consumer_id, wake_id}, _from, state) do
    state = flush_now(state)
    {result, state} = fast_forward(state, consumer_id, wake_id)
    {:reply, result, state}
  end

  def handle_call(:cursor, _from, state) do
    state = Storage.refresh_cursor(state)
    {:reply, state.cursor, state}
  end

  def handle_call(:stats, _from, state) do
    state = Storage.refresh_cursor(state)

    case Storage.unread_records(state) do
      {:ok, unread} ->
        in_flight = Enum.count(state.pending, fn {_key, record} -> record["wake_id"] > state.cursor end)
        stats = %{cursor: state.cursor, pending_count: length(unread) + in_flight}
        {:reply, {:ok, stats}, %{state | pending_count: length(unread)}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:pending, _from, state) do
    records =
      case Storage.unread_records(state) do
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

  def handle_info({:wait_timeout, key}, state) do
    case Map.pop(state.waiters, key) do
      {nil, _waiters} ->
        {:noreply, state}

      {%{from: from, monitor: monitor}, waiters} ->
        Process.demonitor(monitor, [:flush])
        {reply, state} = expire_waiter(%{state | waiters: waiters})
        GenServer.reply(from, reply)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {dead, live} = Enum.split_with(state.waiters, fn {_key, waiter} -> waiter.monitor == monitor end)
    Enum.each(dead, fn {_key, waiter} -> Process.cancel_timer(waiter.timer) end)
    {:noreply, %{state | waiters: Map.new(live)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = flush_pending(state)
    :ok
  end

  # The debounce window runs from the *first* unflushed record, not the latest.
  # Restarting it on every enqueue made the window extendable without bound: a
  # run whose wakes arrive faster than `debounce_ms` never flushed, so a blocked
  # `executor-wait` timed out empty while the records it was waiting for sat in
  # memory and only reached the ledger once the stream went quiet (#2600).
  # Records with the same key still merge inside the window; only the maximum
  # deferral is bounded.
  defp ensure_flush_timer(%{timer: {_timer, _token}} = state), do: state

  defp ensure_flush_timer(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:flush, token}, state.debounce_ms)
    %{state | timer: {timer, token}}
  end

  defp flush_now(%{timer: nil} = state), do: flush_pending(state)

  defp flush_now(%{timer: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    flush_pending(%{state | timer: nil})
  end

  defp flush_pending(%{pending: pending} = state) when map_size(pending) == 0, do: serve_waiters(state)

  defp flush_pending(state) do
    records = state.pending |> Map.values() |> Enum.sort_by(& &1["wake_id"])

    case Storage.append_new_records(state.path, records) do
      :ok ->
        :ok = Storage.persist_pending(state.pending_path, %{})
        state |> Map.merge(%{pending: %{}, flush_failures: 0}) |> Storage.trim_consumed() |> serve_waiters()

      {:error, reason} ->
        state |> Recovery.flush_failed(reason) |> ensure_flush_timer()
    end
  end

  # A wait must never report "quiet" while readable records sit unread. The
  # timer only proves that `debounce_ms` of coalescing did not land in time, so
  # the last act of an expiring waiter is to flush anything still pending and
  # re-read the durable ledger. Records appended late — by this flush or by a
  # peer daemon writing the shared journal — are returned by this one waiter and
  # then acknowledged by the caller, rather than being left for the next call to
  # rediscover from disk (#2600).
  defp expire_waiter(state) do
    state = flush_now(state)

    case Storage.unread_records(state) do
      {:ok, [_ | _] = records} -> {{:ok, records}, state}
      {:ok, []} -> {:timeout, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp serve_waiters(%{waiters: waiters} = state) when map_size(waiters) == 0, do: state

  defp serve_waiters(state) do
    case Storage.unread_records(state) do
      {:ok, [_ | _] = records} ->
        Enum.each(state.waiters, fn {_key, waiter} ->
          Process.demonitor(waiter.monitor, [:flush])
          Process.cancel_timer(waiter.timer)
          GenServer.reply(waiter.from, {:ok, records})
        end)

        %{state | waiters: %{}}

      _ ->
        state
    end
  end

  defp waiter_key(from, _consumer_id, false), do: {:from, from}
  defp waiter_key(_from, consumer_id, true), do: {:consumer, consumer_id}

  defp supersede_waiter(state, _key, false), do: state

  defp supersede_waiter(state, key, true) do
    case Map.pop(state.waiters, key) do
      {nil, _waiters} ->
        state

      {%{from: from, monitor: monitor, timer: timer}, waiters} ->
        Process.demonitor(monitor, [:flush])
        Process.cancel_timer(timer)
        GenServer.reply(from, :superseded)
        %{state | waiters: waiters}
    end
  end

  defp merge_record(previous, latest) do
    latest
    |> Map.put("wake_id", previous["wake_id"])
    |> Map.put("count", (previous["count"] || 1) + 1)
    |> Map.put("first_seen_at", previous["first_seen_at"])
  end

  defp fast_forward(state, consumer_id, wake_id) do
    state = Storage.refresh_cursor(state)

    case Storage.durable_records(state) do
      {:ok, durable} -> fast_forward_durable(state, consumer_id, wake_id, durable)
      {:error, _reason} = error -> {error, state}
    end
  end

  defp fast_forward_durable(state, consumer_id, wake_id, durable) do
    records = Enum.filter(durable, &(&1["wake_id"] > state.cursor))
    latest_wake_id = durable |> Enum.map(& &1["wake_id"]) |> Enum.max(fn -> state.cursor end)

    cond do
      wake_id <= state.cursor ->
        fast_forward_already_seen(state, consumer_id, wake_id, length(records))

      wake_id > latest_wake_id ->
        {{:error, :journal_reset}, state}

      not Enum.any?(durable, &(&1["wake_id"] == wake_id)) ->
        {{:error, {:wake_not_found, wake_id}}, state}

      true ->
        fast_forward_existing_prefix(state, consumer_id, records, wake_id)
    end
  end

  defp fast_forward_already_seen(state, consumer_id, wake_id, pending_count) do
    case acknowledge_records_as(state, consumer_id, [], state.cursor) do
      {:ok, updated_state} ->
        result = {:ok, %{from: state.cursor, through: max(wake_id, state.cursor), acknowledged_count: 0, pending_count: pending_count}}
        {result, updated_state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  # `fast_forward_durable/4` has already proven that `wake_id` is present in the
  # durable log and sits above the cursor, so the split below always covers it.
  defp fast_forward_existing_prefix(state, consumer_id, records, wake_id) do
    {covered, remaining} = Enum.split_while(records, &(&1["wake_id"] <= wake_id))

    case acknowledge_records_as(state, consumer_id, covered, wake_id) do
      {:ok, updated_state} ->
        result =
          {:ok,
           %{
             from: state.cursor,
             through: wake_id,
             acknowledged_count: length(covered),
             pending_count: length(remaining)
           }}

        {result, updated_state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp acknowledge_records_as(state, consumer_id, records, highest) do
    case Claims.record_acknowledgement(consumer_id, highest) do
      {:ok, _entry} ->
        {:ok, state |> Storage.advance_cursor(records) |> Storage.trim_consumed()}

      {:error, _reason} = error ->
        error
    end
  end

  defp journal_path, do: StatePaths.wakes_path()
  defp cursor_path, do: StatePaths.cursor_path()
  defp pending_path, do: StatePaths.pending_path()
end
