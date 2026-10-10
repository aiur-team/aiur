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

  alias Aiur.LiveConversation.{Compactor, Normalizer, Notify, SnapshotState, Source}

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
          required(:projection_epoch) => String.t(),
          required(:revision) => non_neg_integer(),
          required(:source_revision) => non_neg_integer(),
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
    name = Keyword.get(opts, :name, __MODULE__)
    opts = Keyword.put_new(opts, :announce_restarts?, name == __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec activate(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def activate(source, opts \\ []) do
    history_known? = Keyword.get(opts, :history_known?, true)
    call({:activate, source, history_known?, runtime_subscriber(opts)}, opts)
  end

  @spec observe(source(), map(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def observe(source, event, opts \\ []) when is_map(event) do
    call({:observe, source, event, runtime_subscriber(opts)}, opts)
  end

  @spec observe_operator_message(source(), map(), keyword()) ::
          {:ok, snapshot()} | {:error, atom()}
  def observe_operator_message(source, event, opts \\ []) when is_map(event) do
    call({:observe_trusted, source, :user, event, runtime_subscriber(opts)}, opts)
  end

  @spec observe_tool_summary(source(), map(), keyword()) ::
          {:ok, snapshot()} | {:error, atom()}
  def observe_tool_summary(source, event, opts \\ []) when is_map(event) do
    call({:observe_trusted, source, :tool, event, runtime_subscriber(opts)}, opts)
  end

  @spec end_generation(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def end_generation(source, opts \\ []),
    do: call({:change_state, source, :ended, runtime_subscriber(opts)}, opts)

  @spec mark_unavailable(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def mark_unavailable(source, opts \\ []) do
    call({:change_state, source, :unavailable, runtime_subscriber(opts)}, opts)
  end

  @spec mark_stale(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def mark_stale(source, opts \\ []),
    do: call({:change_state, source, :stale, runtime_subscriber(opts)}, opts)

  @spec mark_degraded(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def mark_degraded(source, opts \\ []),
    do: call({:change_state, source, :degraded, runtime_subscriber(opts)}, opts)

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
      {:ok, key, _source} -> Notify.subscribe_with_restarts(Notify.source_topic(key))
      _error -> {:error, :invalid_source}
    end
  end

  @doc "Subscribe to coalesced changes for one opaque generation handle."
  @spec subscribe_handle(String.t()) :: :ok | {:error, :invalid_handle}
  def subscribe_handle(handle) do
    if Source.valid_handle?(handle) do
      Notify.subscribe_with_restarts(Notify.handle_topic(handle))
    else
      {:error, :invalid_handle}
    end
  end

  @doc "Unsubscribe from a previously subscribed opaque generation handle."
  @spec unsubscribe_handle(String.t()) :: :ok | {:error, :invalid_handle}
  def unsubscribe_handle(handle) do
    if Source.valid_handle?(handle) do
      :ok = Phoenix.PubSub.unsubscribe(Aiur.PubSub, Notify.handle_topic(handle))
      Phoenix.PubSub.unsubscribe(Aiur.PubSub, Notify.restart_topic())
    else
      {:error, :invalid_handle}
    end
  end

  @doc "Subscribe to projection-epoch changes so retained consumer caches can reset truthfully."
  @spec subscribe_restarts() :: :ok | {:error, term()}
  def subscribe_restarts, do: Phoenix.PubSub.subscribe(Aiur.PubSub, Notify.restart_topic())

  @impl true
  def init(opts) do
    announce_restarts? = Keyword.get(opts, :announce_restarts?, false)

    state = %{
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      handle_fun: Keyword.get(opts, :handle_fun, &Notify.random_handle/0),
      projection_epoch: Notify.random_epoch(),
      implicit_restart_unknown?: projection_restarted?(announce_restarts?),
      announce_restarts?: announce_restarts?,
      notification_delay_ms: Keyword.get(opts, :notification_delay_ms, 10),
      next_revision: 0,
      snapshots: %{},
      handles: %{},
      active_sources: %{},
      runtime_subscribers: %{},
      pending_notifications: %{}
    }

    {:ok, state, {:continue, :announce_restart}}
  end

  @impl true
  def handle_continue(:announce_restart, state) do
    if state.announce_restarts? do
      Phoenix.PubSub.broadcast(
        Aiur.PubSub,
        Notify.restart_topic(),
        {:live_conversation_restarted, state.projection_epoch, state.clock.()}
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:activate, source, history_known?, runtime}, _from, state) do
    case Source.canonical(source) do
      {:ok, key, source} ->
        case authorize_source(state, key, :activate) do
          {:ok, state} ->
            now = state.clock.()
            mode = history_mode(history_known?)
            {snapshot, state, created?} = fetch_or_create(state, key, source, now, mode)
            activated = SnapshotState.activate_snapshot(snapshot, now, created?, history_known?)
            changed? = created? or activated != snapshot
            {activated, state} = SnapshotState.persist_snapshot(state, key, activated, changed?)

            state =
              state
              |> register_runtime_subscriber(key, runtime)
              |> Notify.maybe_schedule_notification(key, source, changed?)

            {:reply, {:ok, SnapshotState.public(activated)}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:observe, source, event, runtime}, _from, state) do
    observe_normalized(source, state, runtime, fn now -> Normalizer.normalize(event, now) end)
  end

  def handle_call({:observe_trusted, source, role, event, runtime}, _from, state) do
    observe_normalized(source, state, runtime, fn now ->
      Normalizer.normalize_trusted(role, event, now)
    end)
  end

  def handle_call({:change_state, source, next_state, runtime}, _from, state) do
    change_state(source, state, next_state, runtime)
  end

  def handle_call({:snapshot, source}, _from, state) do
    case Source.canonical(source) do
      {:ok, key, source} ->
        snapshot =
          Map.get(
            state.snapshots,
            key,
            SnapshotState.restart_unknown_snapshot(source, state.clock.(), state.projection_epoch)
          )

        {:reply, SnapshotState.public(snapshot), state}

      _error ->
        {:reply, SnapshotState.unavailable_snapshot(state.clock.(), state.projection_epoch, :invalid_source), state}
    end
  end

  def handle_call({:resolve, handle}, _from, state) do
    snapshot =
      with {:ok, key} <- Map.fetch(state.handles, handle),
           {:ok, snapshot} <- Map.fetch(state.snapshots, key) do
        SnapshotState.public(snapshot)
      else
        _missing ->
          SnapshotState.restart_unknown_snapshot(nil, state.clock.(), state.projection_epoch, handle)
          |> SnapshotState.public()
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
          Map.get(
            state.snapshots,
            key,
            SnapshotState.restart_unknown_snapshot(source, state.clock.(), state.projection_epoch)
          )

        Notify.broadcast(key, SnapshotState.public(snapshot))
        notify_runtime_subscribers(state, key, snapshot)
        {:noreply, %{state | pending_notifications: pending_notifications}}
    end
  end

  defp observe_normalized(source, state, runtime, normalize_fun) do
    case Source.canonical(source) do
      {:ok, key, source} ->
        case authorize_source(state, key, :mutate) do
          {:ok, state} ->
            now = state.clock.()
            {snapshot, state, _created?} = fetch_or_create(state, key, source, now, :implicit)
            {snapshot, changed?} = Compactor.apply(snapshot, normalize_fun.(now))
            {snapshot, state} = SnapshotState.persist_snapshot(state, key, snapshot, changed?)

            state =
              state
              |> register_runtime_subscriber(key, runtime)
              |> Notify.maybe_schedule_notification(key, source, changed?)

            {:reply, {:ok, SnapshotState.public(snapshot)}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp change_state(source, state, next_state, runtime) do
    case Source.canonical(source) do
      {:ok, key, source} ->
        case authorize_source(state, key, :mutate) do
          {:ok, state} ->
            apply_change_state(state, key, source, next_state, runtime)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_change_state(state, key, source, next_state, runtime) do
    now = state.clock.()
    {snapshot, state, _created?} = fetch_or_create(state, key, source, now, :implicit)

    if snapshot.state == :ended do
      {:reply, {:ok, SnapshotState.public(snapshot)}, state}
    else
      {next_state, health, freshness} = SnapshotState.state_transition(next_state, snapshot)

      snapshot =
        Map.merge(snapshot, %{
          state: next_state,
          health: health,
          freshness: freshness,
          observed_at: now
        })

      {snapshot, state} = SnapshotState.persist_snapshot(state, key, snapshot, true)

      state =
        state
        |> register_runtime_subscriber(key, runtime)
        |> Notify.schedule_notification(key, source)

      {:reply, {:ok, SnapshotState.public(snapshot)}, state}
    end
  end

  defp history_mode(history_known?) do
    if history_known?, do: :known_history, else: :unknown_history
  end

  defp fetch_or_create(state, key, source, now, mode) do
    case Map.fetch(state.snapshots, key) do
      {:ok, snapshot} -> {snapshot, state, false}
      :error -> new_snapshot(state, source, now, mode)
    end
  end

  defp new_snapshot(state, source, now, mode) do
    handle = Notify.unique_handle(state)
    snapshot = SnapshotState.fresh_snapshot(source, now, handle, state.projection_epoch)

    snapshot =
      if mode == :unknown_history or
           (mode == :implicit and state.implicit_restart_unknown?) do
        SnapshotState.restart_unknown(snapshot)
      else
        snapshot
      end

    {snapshot, state, true}
  end

  defp authorize_source(state, key, mode) do
    scope = Source.scope(key)
    generation = Source.generation(key)

    case Map.get(state.active_sources, scope) do
      nil ->
        {:ok, put_active_source(state, scope, key, generation)}

      %{generation: active_generation} when generation < active_generation ->
        {:error, :stale_generation}

      %{generation: active_generation} when generation > active_generation ->
        {:ok, put_active_source(state, scope, key, generation)}

      %{key: ^key} ->
        {:ok, state}

      _active when mode == :activate ->
        {:ok, put_active_source(state, scope, key, generation)}

      _active ->
        {:error, :stale_source}
    end
  end

  defp put_active_source(state, scope, key, generation) do
    active = %{key: key, generation: generation, revision: state.next_revision}
    %{state | active_sources: Map.put(state.active_sources, scope, active)}
  end

  defp register_runtime_subscriber(state, _key, nil), do: state

  defp register_runtime_subscriber(state, key, {recipient, issue_id}) do
    subscribers =
      Map.update(state.runtime_subscribers, key, %{issue_id => recipient}, fn subscribers ->
        Map.put(subscribers, issue_id, recipient)
      end)

    %{state | runtime_subscribers: subscribers}
  end

  defp notify_runtime_subscribers(state, key, snapshot) do
    status =
      snapshot
      |> SnapshotState.public()
      |> Map.take([
        :projection_epoch,
        :revision,
        :source_revision,
        :generation_handle,
        :source,
        :state,
        :health,
        :freshness,
        :observed_at
      ])

    state.runtime_subscribers
    |> Map.get(key, %{})
    |> Enum.each(fn {issue_id, recipient} ->
      send(recipient, {:worker_runtime_info, issue_id, %{live_conversation: status}})
    end)

    :ok
  end

  defp runtime_subscriber(opts) do
    case Keyword.get(opts, :runtime_subscriber) do
      {recipient, issue_id} when is_pid(recipient) and is_binary(issue_id) ->
        {recipient, issue_id}

      _other ->
        nil
    end
  end

  defp projection_restarted?(false), do: false

  defp projection_restarted?(true) do
    key = {__MODULE__, :projection_started, Aiur.Boot.run_id()}
    restarted? = :persistent_term.get(key, false)
    :persistent_term.put(key, true)
    restarted?
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp call(message, opts), do: GenServer.call(server(opts), message)
end
