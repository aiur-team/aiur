defmodule Aiur.DecisionMetrics do
  @moduledoc """
  Append-only Decision lifecycle latency metrics.

  This worker observes existing `Aiur.Events.Exchange` notifications only
  after `DecisionStore` has persisted them. It appends redacted snapshots to
  the stable Decision-state `metrics/decision_latency.ndjson`; the Decision
  audit stays canonical.

  Startup replays that projection and seeds missing lifecycle facts from
  `DecisionStore`, covering the canonical service's best-effort notification gap.

  Missing milestones remain `nil` rather than being inferred. The snapshots
  retain request→decision, decision→dispatch, dispatch→delivery,
  delivery→acknowledgement, observed blocked time, reminder count, actor class,
  and whether a revision was observed. For a blocking Decision, blocked time
  ends at acknowledgement (or resolution when no acknowledgement exists) and
  otherwise advances only when another lifecycle fact is observed.
  """

  use GenServer

  alias Aiur.DecisionMetrics.{Canonical, Event, Log, Sample}
  alias Aiur.DecisionStore
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
  def metrics_file, do: Metrics.file(:decision_metrics_path, @metrics_filename, :decision_state)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, metrics_file())
    if Keyword.get(opts, :subscribe?, true), do: Enum.each(@patterns, &Exchange.subscribe/1)
    replay = Keyword.get(opts, :replay, &Log.replay/1)
    {samples, seen} = replay.(path)

    state = %{
      path: path,
      samples: samples,
      seen: seen,
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      decision_store: Keyword.get(opts, :decision_store, DecisionStore)
    }

    state = seed_canonical(state, Keyword.get(opts, :seed?, true))
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

  @impl true
  def handle_info({:event, event}, state) when is_map(event) do
    {_reply, next_state} = record_event(event, state)
    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp seed_canonical(state, false), do: state

  defp seed_canonical(state, true) do
    state.decision_store
    |> Canonical.events()
    |> Enum.reduce(state, fn event, acc ->
      {_reply, next_state} = record_event(event, acc)
      next_state
    end)
  end

  defp record_event(event, state) do
    event = correlate_attention(event, state.decision_store)
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

  defp correlate_attention(event, server) do
    topic = event_value(event, :topic)

    if attention_topic?(topic) and is_nil(event_value(event, :decision_id)) do
      case Canonical.decision_id_for_attention(server, topic) do
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
end
