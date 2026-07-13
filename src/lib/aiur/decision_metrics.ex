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

  alias Aiur.DecisionMetrics.{Bootstrap, Collector, Options, Sample, Window, Writer}
  alias Aiur.DecisionPubSub
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

  @doc "Returns every retained redacted Decision snapshot keyed by Decision ID."
  @spec snapshots(GenServer.server()) :: %{String.t() => map()}
  def snapshots(server \\ __MODULE__), do: GenServer.call(server, :snapshots)

  @doc "Flushes queued metric snapshots to the bounded stream."
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)

  @doc "Waits for the asynchronous canonical recovery pass to finish."
  @spec await_seed(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_seed(server \\ __MODULE__, timeout \\ 30_000), do: GenServer.call(server, :await_seed, timeout)

  @doc "Absolute path of the bounded decision latency metrics stream."
  @spec metrics_file() :: Path.t()
  def metrics_file, do: Metrics.file(:decision_metrics_path, @metrics_filename, :decision_state)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe?, true), do: Enum.each(@patterns, &Exchange.subscribe/1)

    {writer, owned_writer?} = Bootstrap.writer(opts)
    loaded = Writer.load(writer)
    sample_limit = Options.positive(opts, :sample_limit, @sample_limit)
    seen_limit = Options.positive(opts, :seen_limit, @seen_limit)
    seed_status = if Keyword.get(opts, :seed?, true), do: :pending, else: :complete

    state =
      %{
        samples: loaded.samples,
        seen: Window.new(seen_limit, loaded.event_ids),
        sample_limit: sample_limit,
        attention_index: %{},
        clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
        decision_store: Keyword.get(opts, :decision_store, DecisionStore),
        metrics_changed_fun: Keyword.get(opts, :metrics_changed_fun, &DecisionPubSub.broadcast_metrics_changed/0),
        writer: writer,
        owned_writer?: owned_writer?,
        seed_status: seed_status,
        seed_waiters: []
      }
      |> Collector.bound()

    Bootstrap.start_seed(self(), state.decision_store, sample_limit, opts)
    {:ok, state}
  end

  @impl true
  def handle_call({:observe, event}, _from, state) do
    {reply, next_state} = Collector.record(event, state)
    notify_if_recorded(reply, next_state.metrics_changed_fun)
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

  def handle_call(:snapshots, _from, state) do
    snapshots = Map.new(state.samples, fn {decision_id, sample} -> {decision_id, Sample.to_map(sample)} end)
    {:reply, snapshots, state}
  end

  def handle_call(:flush, _from, state) do
    {:reply, flush_writer(state.writer), state}
  end

  def handle_call(:await_seed, _from, %{seed_status: :complete} = state), do: {:reply, :ok, state}

  def handle_call(:await_seed, _from, %{seed_status: {:error, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call(:await_seed, from, state) do
    {:noreply, Map.update!(state, :seed_waiters, &[from | &1])}
  end

  @impl true
  def handle_info({:event, event}, state) when is_map(event) do
    {reply, next_state} = Collector.record(event, state)
    notify_if_recorded(reply, next_state.metrics_changed_fun)
    {:noreply, next_state}
  end

  def handle_info({:canonical_seed, %{events: events, attention_index: index}}, state) do
    next_state = events |> Collector.seed(index, state) |> finish_seed(:complete)
    if events != [], do: next_state.metrics_changed_fun.()
    {:noreply, next_state}
  end

  def handle_info({:canonical_seed_failed, reason}, state) do
    Logger.warning("decision_metrics canonical_seed_failed reason=#{inspect(reason)}")
    {:noreply, finish_seed(state, {:error, reason})}
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

  defp finish_seed(state, status) do
    reply = if status == :complete, do: :ok, else: status
    Enum.each(state.seed_waiters, &GenServer.reply(&1, reply))
    %{state | seed_status: status, seed_waiters: []}
  end

  defp flush_writer(writer) do
    Writer.flush(writer)
  catch
    :exit, reason -> {:error, {:writer_exit, reason}}
  end

  defp notify_if_recorded(:ok, metrics_changed_fun), do: metrics_changed_fun.()
  defp notify_if_recorded(_result, _metrics_changed_fun), do: :ok
end
