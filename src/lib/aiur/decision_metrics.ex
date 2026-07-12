defmodule Aiur.DecisionMetrics do
  @moduledoc """
  Bounded Decision lifecycle latency metrics.

  This worker observes `Aiur.Events.Exchange` notifications only after the
  canonical `DecisionStore` append. It keeps a bounded in-memory projection and
  hands redacted snapshots to an asynchronous, compacting writer under stable
  Decision state. Missing or out-of-order milestones remain unknown.
  """

  use GenServer

  require Logger

  alias Aiur.DecisionMetrics.{Canonical, Event, Log, Sample, Writer}
  alias Aiur.DecisionStore
  alias Aiur.Events.Exchange
  alias Aiur.Metrics

  @patterns ["ticket.*.agent.decision.#", "ticket.*.agent.attention.#"]
  @metrics_filename "decision_latency.ndjson"
  @sample_limit 1_000
  @seen_limit 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Synchronously projects one already-persisted Exchange event."
  @spec observe(map(), GenServer.server()) :: :ok | :duplicate | :ignored
  def observe(event, server \\ __MODULE__) when is_map(event) do
    GenServer.call(server, {:observe, event})
  end

  @doc "Returns the current redacted snapshot for one retained Decision."
  @spec snapshot(String.t(), GenServer.server()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:snapshot, decision_id})
  end

  @doc "Flushes queued metric snapshots to the bounded stream."
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)

  @doc "Absolute path of the bounded decision latency metrics stream."
  @spec metrics_file() :: Path.t()
  def metrics_file, do: Metrics.file(:decision_metrics_path, @metrics_filename, :decision_state)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe?, true), do: Enum.each(@patterns, &Exchange.subscribe/1)

    {writer, owned_writer?} = writer(opts)
    loaded = Writer.load(writer)
    sample_limit = positive_option(opts, :sample_limit, @sample_limit)
    seen_limit = positive_option(opts, :seen_limit, @seen_limit)

    state =
      %{
        samples: loaded.samples,
        seen: MapSet.new(),
        seen_order: :queue.new(),
        seen_count: 0,
        sample_limit: sample_limit,
        seen_limit: seen_limit,
        attention_index: %{},
        clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
        decision_store: Keyword.get(opts, :decision_store, DecisionStore),
        writer: writer,
        owned_writer?: owned_writer?
      }
      |> remember_events(loaded.event_ids)
      |> bound_samples()

    start_canonical_seed(state, opts)
    {:ok, state}
  end

  @impl true
  def handle_call({:observe, event}, _from, state) do
    {reply, next_state} = record_event(event, state)
    {:reply, reply, next_state}
  end

  def handle_call({:snapshot, decision_id}, _from, state) do
    reply =
      case Map.fetch(state.samples, decision_id) do
        {:ok, sample} -> {:ok, Sample.to_map(sample)}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:flush, _from, state) do
    {:reply, flush_writer(state.writer), state}
  end

  @impl true
  def handle_info({:event, event}, state) when is_map(event) do
    {_reply, next_state} = record_event(event, state)
    {:noreply, next_state}
  end

  def handle_info({:canonical_seed, %{events: events, attention_index: index}}, state) do
    state = %{state | attention_index: Map.merge(index, state.attention_index)}

    next_state =
      Enum.reduce(events, state, fn event, acc ->
        {_reply, next_acc} = record_event(event, acc)
        next_acc
      end)

    {:noreply, bound_samples(next_state)}
  end

  def handle_info({:canonical_seed_failed, reason}, state) do
    Logger.warning("decision_metrics canonical_seed_failed reason=#{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{owned_writer?: true, writer: writer}) when is_pid(writer) do
    if Process.alive?(writer) do
      _ = Writer.flush(writer)
      GenServer.stop(writer)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp writer(opts) do
    case Keyword.fetch(opts, :writer) do
      {:ok, writer} -> {writer, false}
      :error -> maybe_start_private_writer(opts)
    end
  end

  defp maybe_start_private_writer(opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) ->
        writer_opts =
          opts
          |> Keyword.take([
            :sample_limit,
            :record_limit,
            :seen_limit,
            :batch_limit,
            :flush_interval_ms,
            :replay_record_limit,
            :replay_bytes,
            :replay_fun,
            :append_fun,
            :compact_fun
          ])
          |> Keyword.merge(name: nil, path: path)

        {:ok, writer} = Writer.start_link(writer_opts)
        {writer, true}

      _other ->
        {Writer, false}
    end
  end

  defp start_canonical_seed(state, opts) do
    if Keyword.get(opts, :seed?, true) do
      owner = self()
      server = state.decision_store
      limit = state.sample_limit
      seed_fun = Keyword.get(opts, :seed_fun, &Canonical.snapshot/2)

      Task.start(fn -> run_canonical_seed(owner, seed_fun, server, limit) end)
    end

    :ok
  end

  defp run_canonical_seed(owner, seed_fun, server, limit) do
    result = seed_fun.(server, limit)
    send(owner, {:canonical_seed, result})
  rescue
    error -> send(owner, {:canonical_seed_failed, Exception.message(error)})
  catch
    kind, reason -> send(owner, {:canonical_seed_failed, {kind, reason}})
  end

  defp record_event(event, state) do
    state = index_attention(event, state)
    event = correlate_attention(event, state.attention_index)
    observed_at = state.clock.()

    with {:ok, fact} <- Event.normalize(event, observed_at),
         false <- MapSet.member?(state.seen, fact.event_id) do
      sample = Map.get(state.samples, fact.decision_id, Sample.new(fact.decision_id, fact.identifier))
      updated = Sample.observe(sample, fact.stage, fact)
      Writer.persist(Log.record(updated, fact, observed_at), state.writer)

      next_state =
        state
        |> Map.update!(:samples, &Map.put(&1, fact.decision_id, updated))
        |> remember_event(fact.event_id)
        |> bound_samples()

      {:ok, next_state}
    else
      true -> {:duplicate, state}
      :ignored -> {:ignored, state}
    end
  end

  defp index_attention(event, state) do
    case Event.attention_correlation(event) do
      {topic, decision_id} ->
        %{state | attention_index: Map.put(state.attention_index, topic, decision_id)}

      nil ->
        state
    end
  end

  defp correlate_attention(event, index) do
    topic = event_value(event, :topic)

    if attention_topic?(topic) and is_nil(event_value(event, :decision_id)) do
      case Map.get(index, topic) do
        nil -> event
        decision_id -> put_event_value(event, :decision_id, decision_id)
      end
    else
      event
    end
  end

  defp attention_topic?(topic) when is_binary(topic) do
    String.contains?(topic, ".agent.attention.") and not String.ends_with?(topic, ".resolved")
  end

  defp attention_topic?(_topic), do: false
  defp event_value(event, key), do: Map.get(event, key, Map.get(event, Atom.to_string(key)))

  defp put_event_value(event, key, value) do
    if Map.has_key?(event, Atom.to_string(key)),
      do: Map.put(event, Atom.to_string(key), value),
      else: Map.put(event, key, value)
  end

  defp bound_samples(state) when map_size(state.samples) <= state.sample_limit do
    state
  end

  defp bound_samples(state) do
    retained =
      state.samples
      |> Enum.sort_by(fn {_decision_id, sample} -> observed_sort_key(sample.last_observed_at) end, :desc)
      |> Enum.take(state.sample_limit)

    retained_ids = retained |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    %{
      state
      | samples: Map.new(retained),
        attention_index:
          Map.filter(state.attention_index, fn {_topic, decision_id} ->
            MapSet.member?(retained_ids, decision_id)
          end)
    }
  end

  defp observed_sort_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp observed_sort_key(_at), do: 0

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

  defp flush_writer(writer) do
    Writer.flush(writer)
  catch
    :exit, reason -> {:error, {:writer_exit, reason}}
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end
end
