defmodule Aiur.DecisionMetrics.Writer do
  @moduledoc "Asynchronous, bounded persistence worker for Decision latency snapshots."

  use GenServer

  require Logger

  alias Aiur.DecisionMetrics.{Log, Options, Window}
  alias Aiur.DecisionMetrics.Writer.Persistence

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
    sample_limit = Options.positive(opts, :sample_limit, @sample_limit)
    record_limit = max(sample_limit, Options.positive(opts, :record_limit, @record_limit))
    seen_limit = Options.positive(opts, :seen_limit, @seen_limit)

    replay = prepare_and_replay(path, opts, record_limit)

    state =
      %{
        path: path,
        sample_limit: sample_limit,
        record_limit: record_limit,
        batch_limit: Options.positive(opts, :batch_limit, @batch_limit),
        flush_interval_ms: Options.positive(opts, :flush_interval_ms, @flush_interval_ms),
        append_fun: Keyword.get(opts, :append_fun, &Log.append_batch/2),
        compact_fun: Keyword.get(opts, :compact_fun, &Log.compact/2),
        samples: replay.samples,
        records: replay.records,
        seen: Window.new(seen_limit, replay.event_ids),
        pending: [],
        pending_count: 0,
        record_count: replay.record_count,
        force_compact?: replay.truncated?,
        flush_timer: nil
      }
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
          |> Persistence.queue(record)

        if next_state.pending_count >= next_state.batch_limit do
          {_result, next_state} = Persistence.flush(next_state)
          {:noreply, next_state}
        else
          {:noreply, Persistence.schedule(next_state)}
        end

      {:error, reason} ->
        Logger.warning("decision_metrics writer_ignored reason=#{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {result, next_state} = state |> Persistence.cancel() |> Persistence.flush()
    {:reply, result, next_state}
  end

  def handle_call(:load, _from, state) do
    reply = %{samples: state.samples, event_ids: Window.ids(state.seen)}
    {:reply, reply, state}
  end

  def handle_call(:stats, _from, state) do
    reply = %{
      sample_count: map_size(state.samples),
      seen_count: Window.size(state.seen),
      pending_count: state.pending_count,
      record_count: state.record_count,
      force_compact?: state.force_compact?
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    {_result, next_state} = state |> Map.put(:flush_timer, nil) |> Persistence.flush()
    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = state |> Persistence.cancel() |> Persistence.flush()
    :ok
  end

  defp prepare_and_replay(path, opts, record_limit) do
    case Log.prepare(path) do
      :ok ->
        replay_fun = Keyword.get(opts, :replay_fun, &Log.replay/2)

        replay_fun.(path,
          record_limit: Options.positive(opts, :replay_record_limit, record_limit),
          max_bytes: Options.positive(opts, :replay_bytes, @replay_bytes)
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
    |> Map.update!(:seen, &Window.put(&1, event_id))
    |> bound_projections()
  end

  defp bound_projections(state) do
    {samples, retained_ids} = Window.recent(state.samples, state.sample_limit)
    retained_set = MapSet.new(retained_ids)

    %{
      state
      | samples: samples,
        records: Map.take(state.records, retained_ids),
        pending: Enum.filter(state.pending, &MapSet.member?(retained_set, record_id(&1)))
    }
    |> then(&%{&1 | pending_count: length(&1.pending)})
  end

  defp record_id(record), do: Map.get(record, :decision_id, Map.get(record, "decision_id"))
end
