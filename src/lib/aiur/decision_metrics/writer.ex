defmodule Aiur.DecisionMetrics.Writer do
  @moduledoc "Asynchronous, bounded persistence worker for Decision latency snapshots."

  use GenServer

  require Logger

  alias Aiur.DecisionMetrics.Log

  @sample_limit 1_000
  @record_limit 2_000
  @seen_limit 5_000
  @replay_bytes 8 * 1_024 * 1_024
  @batch_limit 100
  @flush_interval_ms 25

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Queues one snapshot for batched persistence without blocking the collector."
  @spec persist(map(), GenServer.server()) :: :ok
  def persist(record, server \\ __MODULE__) when is_map(record) do
    GenServer.cast(server, {:persist, record})
  end

  @doc "Flushes queued records; primarily used by tests and orderly handoff paths."
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)

  @doc "Returns the bounded replay projection used to initialize the collector."
  @spec load(GenServer.server()) :: %{samples: map(), event_ids: [String.t()]}
  def load(server \\ __MODULE__), do: GenServer.call(server, :load)

  @doc "Returns resource-bound counters for diagnostics and regression tests."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    sample_limit = positive_option(opts, :sample_limit, @sample_limit)
    record_limit = max(sample_limit, positive_option(opts, :record_limit, @record_limit))
    seen_limit = positive_option(opts, :seen_limit, @seen_limit)

    replay = prepare_and_replay(path, opts, record_limit)

    state =
      %{
        path: path,
        sample_limit: sample_limit,
        record_limit: record_limit,
        seen_limit: seen_limit,
        batch_limit: positive_option(opts, :batch_limit, @batch_limit),
        flush_interval_ms: positive_option(opts, :flush_interval_ms, @flush_interval_ms),
        append_fun: Keyword.get(opts, :append_fun, &Log.append_batch/2),
        compact_fun: Keyword.get(opts, :compact_fun, &Log.compact/2),
        samples: replay.samples,
        records: replay.records,
        seen: MapSet.new(),
        seen_order: :queue.new(),
        seen_count: 0,
        pending: [],
        pending_count: 0,
        record_count: replay.record_count,
        force_compact?: replay.truncated?,
        flush_timer: nil
      }
      |> remember_events(replay.event_ids)
      |> bound_projections()

    if state.force_compact?, do: send(self(), :flush)
    {:ok, state}
  end

  @impl true
  def handle_cast({:persist, record}, state) do
    case Log.decode_record(record) do
      {:ok, {sample, event_id}} ->
        next_state =
          state
          |> put_snapshot(sample, event_id, record)
          |> queue_record(record)

        if next_state.pending_count >= next_state.batch_limit do
          {_result, next_state} = flush_pending(next_state)
          {:noreply, next_state}
        else
          {:noreply, schedule_flush(next_state)}
        end

      {:error, reason} ->
        Logger.warning("decision_metrics writer_ignored reason=#{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {result, next_state} = state |> cancel_flush() |> flush_pending()
    {:reply, result, next_state}
  end

  def handle_call(:load, _from, state) do
    reply = %{samples: state.samples, event_ids: :queue.to_list(state.seen_order)}
    {:reply, reply, state}
  end

  def handle_call(:stats, _from, state) do
    reply = %{
      sample_count: map_size(state.samples),
      seen_count: state.seen_count,
      pending_count: state.pending_count,
      record_count: state.record_count,
      force_compact?: state.force_compact?
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    {_result, next_state} = state |> Map.put(:flush_timer, nil) |> flush_pending()
    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = state |> cancel_flush() |> flush_pending()
    :ok
  end

  defp prepare_and_replay(path, opts, record_limit) do
    case Log.prepare(path) do
      :ok ->
        replay_fun = Keyword.get(opts, :replay_fun, &Log.replay/2)

        replay_fun.(path,
          record_limit: positive_option(opts, :replay_record_limit, record_limit),
          max_bytes: positive_option(opts, :replay_bytes, @replay_bytes)
        )

      {:error, reason} ->
        Logger.warning("decision_metrics prepare_failed path=#{path} reason=#{inspect(reason)}")
        %{samples: %{}, records: %{}, event_ids: [], record_count: 0, truncated?: true}
    end
  end

  defp put_snapshot(state, sample, event_id, record) do
    state
    |> Map.update!(:samples, &Map.put(&1, sample.decision_id, sample))
    |> Map.update!(:records, &Map.put(&1, sample.decision_id, record))
    |> remember_event(event_id)
    |> bound_projections()
  end

  defp queue_record(state, record) do
    %{state | pending: [record | state.pending], pending_count: state.pending_count + 1}
  end

  defp schedule_flush(%{flush_timer: nil, pending_count: count} = state) when count > 0 do
    timer = Process.send_after(self(), :flush, state.flush_interval_ms)
    %{state | flush_timer: timer}
  end

  defp schedule_flush(state), do: state

  defp cancel_flush(%{flush_timer: nil} = state), do: state

  defp cancel_flush(state) do
    Process.cancel_timer(state.flush_timer)
    %{state | flush_timer: nil}
  end

  defp flush_pending(state) do
    cond do
      state.force_compact? -> compact(state)
      state.pending_count == 0 -> {:ok, state}
      state.record_count + state.pending_count > state.record_limit -> compact(state)
      true -> append(state)
    end
  end

  defp append(state) do
    records = Enum.reverse(state.pending)

    case state.append_fun.(state.path, records) do
      :ok ->
        {:ok,
         %{
           state
           | pending: [],
             pending_count: 0,
             record_count: state.record_count + length(records),
             flush_timer: nil
         }}

      {:error, reason} ->
        write_failed(state, :append, reason)
    end
  end

  defp compact(state) do
    records = Map.values(state.records)

    case state.compact_fun.(state.path, records) do
      :ok ->
        {:ok,
         %{
           state
           | pending: [],
             pending_count: 0,
             record_count: length(records),
             force_compact?: false,
             flush_timer: nil
         }}

      {:error, reason} ->
        write_failed(state, :compact, reason)
    end
  end

  defp write_failed(state, operation, reason) do
    Logger.error("decision_metrics write_failed operation=#{operation} error=#{inspect(reason)}")

    {{:error, reason},
     %{
       state
       | pending: [],
         pending_count: 0,
         force_compact?: true,
         flush_timer: nil
     }}
  end

  defp bound_projections(state) when map_size(state.samples) <= state.sample_limit do
    state
  end

  defp bound_projections(state) do
    retained =
      state.samples
      |> Enum.sort_by(fn {_decision_id, sample} -> observed_sort_key(sample.last_observed_at) end, :desc)
      |> Enum.take(state.sample_limit)

    retained_ids = Enum.map(retained, &elem(&1, 0))
    retained_set = MapSet.new(retained_ids)

    %{
      state
      | samples: Map.new(retained),
        records: Map.take(state.records, retained_ids),
        pending: Enum.filter(state.pending, &(record_id(&1) in retained_set))
    }
    |> then(&%{&1 | pending_count: length(&1.pending)})
  end

  defp observed_sort_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp observed_sort_key(_at), do: 0
  defp record_id(record), do: Map.get(record, :decision_id, Map.get(record, "decision_id"))

  defp remember_events(state, event_ids), do: Enum.reduce(event_ids, state, &remember_event(&2, &1))

  defp remember_event(state, event_id) do
    if MapSet.member?(state.seen, event_id) do
      state
    else
      state = %{
        state
        | seen: MapSet.put(state.seen, event_id),
          seen_order: :queue.in(event_id, state.seen_order),
          seen_count: state.seen_count + 1
      }

      evict_seen(state)
    end
  end

  defp evict_seen(%{seen_count: count, seen_limit: limit} = state) when count > limit do
    {{:value, oldest}, order} = :queue.out(state.seen_order)
    %{state | seen: MapSet.delete(state.seen, oldest), seen_order: order, seen_count: count - 1}
  end

  defp evict_seen(state), do: state

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end
end
