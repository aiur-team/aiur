defmodule Aiur.DecisionMetrics do
  @moduledoc """
  Append-only Decision lifecycle latency metrics.

  This worker observes existing `Aiur.Events.Exchange` notifications only
  after `DecisionStore` has persisted them. It appends redacted snapshots to
  `metrics/decision_latency.ndjson`; the Decision audit stays canonical.

  Missing milestones remain `nil` rather than being inferred. The snapshots
  retain request→decision, decision→dispatch, dispatch→delivery,
  delivery→acknowledgement, observed blocked time, reminder count, actor class,
  and whether a revision was observed. For a blocking Decision, blocked time
  ends at acknowledgement (or resolution when no acknowledgement exists) and
  otherwise advances only when another lifecycle fact is observed.
  """

  use GenServer

  alias Aiur.DecisionMetrics.{Event, Log, Sample}
  alias Aiur.Events.Exchange
  alias Aiur.Metrics

  @patterns ["ticket.*.agent.decision.#", "ticket.*.agent.attention.#"]
  @metrics_filename "decision_latency.ndjson"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Synchronously observes one already-persisted Exchange event."
  @spec observe(map(), GenServer.server()) :: :ok | :duplicate | :ignored
  def observe(event, server \\ __MODULE__) when is_map(event) do
    GenServer.call(server, {:observe, event})
  end

  @doc "Returns the current redacted snapshot for one Decision."
  @spec snapshot(String.t(), GenServer.server()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:snapshot, decision_id})
  end

  @doc "Absolute path of the append-only decision latency metrics stream."
  @spec metrics_file() :: Path.t()
  def metrics_file, do: Metrics.file(:decision_metrics_path, @metrics_filename)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, metrics_file())
    {samples, seen} = Log.replay(path)
    if Keyword.get(opts, :subscribe?, true), do: Enum.each(@patterns, &Exchange.subscribe/1)

    {:ok, %{path: path, samples: samples, seen: seen, clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)}}
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

  @impl true
  def handle_info({:event, event}, state) when is_map(event) do
    {_reply, next_state} = record_event(event, state)
    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp record_event(event, state) do
    observed_at = state.clock.()

    with {:ok, fact} <- Event.normalize(event, observed_at),
         false <- MapSet.member?(state.seen, fact.event_id) do
      sample = Map.get(state.samples, fact.decision_id, Sample.new(fact.decision_id, fact.identifier))
      updated = Sample.observe(sample, fact.stage, fact)
      Log.append(state.path, updated, fact, observed_at)

      next_state = %{
        state
        | samples: Map.put(state.samples, fact.decision_id, updated),
          seen: MapSet.put(state.seen, fact.event_id)
      }

      {:ok, next_state}
    else
      true -> {:duplicate, state}
      :ignored -> {:ignored, state}
    end
  end
end
