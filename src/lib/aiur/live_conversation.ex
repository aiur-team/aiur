defmodule Aiur.LiveConversation do
  @moduledoc """
  Supervised in-memory projection of bounded, generation-isolated conversation
  evidence.

  Runtime adapters supply trusted structured events. Reads resolve either an
  exact internal source (for compatibility callers) or an opaque generation
  handle (for dashboard consumers); neither path performs provider, process,
  workspace, or log-file I/O.
  """

  use GenServer

  alias Aiur.LiveConversation.{Compactor, Normalizer, Retention, Source}

  @version 1
  @topic "live-conversation:changed"

  @type source :: Source.input()
  @type public_source :: Source.public()

  @type message :: %{
          required(:id) => String.t(),
          required(:role) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:observed_at) => DateTime.t()
        }

  @type snapshot :: %{
          required(:version) => pos_integer(),
          required(:generation_handle) => String.t() | nil,
          required(:source) => public_source() | nil,
          required(:state) => :live | :ended | :known_empty | :stale | :unavailable | :restart_unknown,
          required(:health) => :healthy | :unavailable | :unknown,
          required(:freshness) => :current | :stale | :unknown,
          required(:messages) => [message()],
          required(:observed_at) => DateTime.t(),
          required(:diagnostic_counts) => %{optional(atom()) => non_neg_integer()},
          required(:truncated?) => boolean(),
          required(:evicted_count) => non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec activate(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def activate(source, opts \\ []), do: call({:activate, source}, opts)

  @spec observe(source(), map(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def observe(source, event, opts \\ []) when is_map(event) do
    call({:observe, source, event}, opts)
  end

  @spec observe_operator_message(source(), map(), keyword()) ::
          {:ok, snapshot()} | {:error, atom()}
  def observe_operator_message(source, event, opts \\ []) when is_map(event) do
    call({:observe_trusted, source, :user, event}, opts)
  end

  @spec observe_tool_summary(source(), map(), keyword()) ::
          {:ok, snapshot()} | {:error, atom()}
  def observe_tool_summary(source, event, opts \\ []) when is_map(event) do
    call({:observe_trusted, source, :tool, event}, opts)
  end

  @spec end_generation(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def end_generation(source, opts \\ []), do: call({:change_state, source, :ended}, opts)

  @spec mark_unavailable(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def mark_unavailable(source, opts \\ []) do
    call({:change_state, source, :unavailable}, opts)
  end

  @spec mark_stale(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def mark_stale(source, opts \\ []), do: call({:change_state, source, :stale}, opts)

  @spec mark_degraded(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def mark_degraded(source, opts \\ []), do: call({:change_state, source, :degraded}, opts)

  @spec snapshot(source(), keyword()) :: snapshot()
  def snapshot(source, opts \\ []), do: GenServer.call(server(opts), {:snapshot, source})

  @doc "Resolve an opaque current-run generation handle without external I/O."
  @spec resolve(String.t(), keyword()) :: {:ok, snapshot()} | {:error, :invalid_handle}
  def resolve(handle, opts \\ []) do
    if Source.valid_handle?(handle) do
      GenServer.call(server(opts), {:resolve, handle})
    else
      {:error, :invalid_handle}
    end
  end

  @spec subscribe(source()) :: :ok | {:error, term()}
  def subscribe(source) do
    case Source.canonical(source) do
      {:ok, key, _source} -> Phoenix.PubSub.subscribe(Aiur.PubSub, source_topic(key))
      _error -> {:error, :invalid_source}
    end
  end

  @doc "Subscribe to coalesced changes for one opaque generation handle."
  @spec subscribe_handle(String.t()) :: :ok | {:error, :invalid_handle}
  def subscribe_handle(handle) do
    if Source.valid_handle?(handle) do
      Phoenix.PubSub.subscribe(Aiur.PubSub, handle_topic(handle))
    else
      {:error, :invalid_handle}
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       handle_fun: Keyword.get(opts, :handle_fun, &random_handle/0),
       snapshots: %{},
       handles: %{},
       pending_notifications: %{}
     }}
  end

  @impl true
  def handle_call({:activate, source}, _from, state) do
    with {:ok, key, source} <- Source.canonical(source) do
      now = state.clock.()
      created? = not Map.has_key?(state.snapshots, key)
      {snapshot, state} = fetch_or_create(state, key, source, now)
      activated = activate_snapshot(snapshot, now)
      changed? = created? or activated != snapshot
      state = put_snapshot(state, key, activated)
      state = maybe_schedule_notification(state, key, source, changed?)
      {:reply, {:ok, public(activated)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:observe, source, event}, _from, state) do
    observe_normalized(source, state, fn now -> Normalizer.normalize(event, now) end)
  end

  def handle_call({:observe_trusted, source, role, event}, _from, state) do
    observe_normalized(source, state, fn now ->
      Normalizer.normalize_trusted(role, event, now)
    end)
  end

  def handle_call({:change_state, source, next_state}, _from, state) do
    change_state(source, state, next_state)
  end

  def handle_call({:snapshot, source}, _from, state) do
    case Source.canonical(source) do
      {:ok, key, source} ->
        snapshot =
          Map.get(state.snapshots, key, restart_unknown_snapshot(source, state.clock.()))

        {:reply, public(snapshot), state}

      _error ->
        {:reply, unavailable_snapshot(state.clock.(), :invalid_source), state}
    end
  end

  def handle_call({:resolve, handle}, _from, state) do
    snapshot =
      with {:ok, key} <- Map.fetch(state.handles, handle),
           {:ok, snapshot} <- Map.fetch(state.snapshots, key) do
        public(snapshot)
      else
        _missing -> restart_unknown_snapshot(nil, state.clock.(), handle) |> public()
      end

    {:reply, {:ok, snapshot}, state}
  end

  @impl true
  def handle_info({:notify, key}, state) do
    case Map.pop(state.pending_notifications, key) do
      {nil, pending_notifications} ->
        {:noreply, %{state | pending_notifications: pending_notifications}}

      {source, pending_notifications} ->
        snapshot =
          Map.get(state.snapshots, key, restart_unknown_snapshot(source, state.clock.()))

        broadcast(key, public(snapshot))
        {:noreply, %{state | pending_notifications: pending_notifications}}
    end
  end

  defp observe_normalized(source, state, normalize_fun) do
    with {:ok, key, source} <- Source.canonical(source) do
      now = state.clock.()
      {snapshot, state} = fetch_or_create(state, key, source, now)
      {snapshot, changed?} = Compactor.apply(snapshot, normalize_fun.(now))
      snapshot = Retention.retain(snapshot, &public/1)
      state = put_snapshot(state, key, snapshot)
      state = maybe_schedule_notification(state, key, source, changed?)
      {:reply, {:ok, public(snapshot)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp change_state(source, state, next_state) do
    with {:ok, key, source} <- Source.canonical(source) do
      now = state.clock.()
      {snapshot, state} = fetch_or_create(state, key, source, now)

      if snapshot.state == :ended do
        {:reply, {:ok, public(snapshot)}, state}
      else
        {next_state, health, freshness} = state_transition(next_state, snapshot)

        snapshot =
          snapshot
          |> Map.merge(%{
            state: next_state,
            health: health,
            freshness: freshness,
            observed_at: now
          })
          |> Retention.retain(&public/1)

        state = state |> put_snapshot(key, snapshot) |> schedule_notification(key, source)
        {:reply, {:ok, public(snapshot)}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_or_create(state, key, source, now) do
    case Map.fetch(state.snapshots, key) do
      {:ok, snapshot} -> {snapshot, state}
      :error -> new_snapshot(state, source, now)
    end
  end

  defp new_snapshot(state, source, now) do
    handle = unique_handle(state)
    {fresh_snapshot(source, now, handle), state}
  end

  defp fresh_snapshot(source, now, handle) do
    %{
      version: @version,
      generation_handle: handle,
      source: source,
      state: :known_empty,
      health: :healthy,
      freshness: :current,
      messages: [],
      seen: %{},
      observed_at: now,
      diagnostic_counts: %{},
      truncated?: false,
      evicted_count: 0
    }
  end

  defp restart_unknown_snapshot(source, now, handle \\ nil) do
    %{
      fresh_snapshot(source, now, handle)
      | state: :restart_unknown,
        health: :unknown,
        freshness: :unknown
    }
  end

  defp unavailable_snapshot(now, reason) do
    %{
      version: @version,
      generation_handle: nil,
      source: nil,
      state: :unavailable,
      health: :unavailable,
      freshness: :unknown,
      messages: [],
      observed_at: now,
      diagnostic_counts: %{reason => 1},
      truncated?: false,
      evicted_count: 0
    }
  end

  defp activate_snapshot(%{state: :ended} = snapshot, _now), do: snapshot

  defp activate_snapshot(snapshot, now) do
    next_state = if snapshot.messages == [], do: :known_empty, else: :live

    snapshot
    |> Map.merge(%{
      state: next_state,
      health: :healthy,
      freshness: :current,
      observed_at: now
    })
    |> Retention.retain(&public/1)
  end

  defp state_transition(:degraded, %{messages: []}),
    do: {:unavailable, :unavailable, :unknown}

  defp state_transition(:degraded, _snapshot),
    do: {:stale, :unavailable, :stale}

  defp state_transition(state, _snapshot),
    do: {state, health_for(state), freshness_for(state)}

  defp health_for(:unavailable), do: :unavailable
  defp health_for(_state), do: :healthy

  defp freshness_for(:stale), do: :stale
  defp freshness_for(:unavailable), do: :unknown
  defp freshness_for(_state), do: :current

  defp public(snapshot) do
    snapshot
    |> Map.take([
      :version,
      :generation_handle,
      :source,
      :state,
      :health,
      :freshness,
      :messages,
      :observed_at,
      :diagnostic_counts,
      :truncated?,
      :evicted_count
    ])
    |> Map.update!(:messages, fn messages ->
      Enum.map(messages, &Normalizer.public_message/1)
    end)
  end

  defp put_snapshot(state, key, snapshot) do
    snapshots =
      state.snapshots
      |> Map.put(key, snapshot)
      |> Retention.retain_snapshots()

    handles =
      Map.new(snapshots, fn {snapshot_key, retained} ->
        {retained.generation_handle, snapshot_key}
      end)

    %{state | snapshots: snapshots, handles: handles}
  end

  defp maybe_schedule_notification(state, _key, _source, false), do: state
  defp maybe_schedule_notification(state, key, source, true), do: schedule_notification(state, key, source)

  defp schedule_notification(%{pending_notifications: pending} = state, key, source) do
    if Map.has_key?(pending, key) do
      state
    else
      Process.send_after(self(), {:notify, key}, 10)
      %{state | pending_notifications: Map.put(pending, key, source)}
    end
  end

  defp unique_handle(state) do
    candidate = state.handle_fun.()
    candidate = if Source.valid_handle?(candidate), do: candidate, else: random_handle()

    if Map.has_key?(state.handles, candidate), do: unique_handle(state), else: candidate
  end

  defp random_handle do
    "conversation:" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end

  defp source_topic(key), do: topic("source", key)
  defp handle_topic(handle), do: @topic <> ":v#{@version}:handle:" <> handle

  defp topic(kind, value) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(value))
      |> Base.url_encode64(padding: false)

    @topic <> ":v#{@version}:#{kind}:" <> digest
  end

  defp broadcast(key, snapshot) do
    :ok =
      Phoenix.PubSub.broadcast(
        Aiur.PubSub,
        source_topic(key),
        {:live_conversation_changed, snapshot}
      )

    case snapshot.generation_handle do
      handle when is_binary(handle) ->
        Phoenix.PubSub.broadcast(
          Aiur.PubSub,
          handle_topic(handle),
          {:live_conversation_changed, snapshot}
        )

      _handle ->
        :ok
    end
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp call(message, opts), do: GenServer.call(server(opts), message)
end
