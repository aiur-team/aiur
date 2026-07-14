defmodule Aiur.Events.SubscriptionStore do
  @moduledoc """
  Per-issue GenServer that owns the persistent subscription state for one
  Aiur ticket.

  Persists to `<logs-root>/<repo>.<id>.subscriptions.json` via the
  atomic-rename helper in `Aiur.JsonStore`. On `init/1` it reads the file
  and re-registers every binding with `Aiur.Events.Exchange` so a BEAM
  restart doesn't drop subscriptions silently.

  ## State shape (on disk)

      {
        "subscribed_to": [
          {
            "topic": "ticket.42.branch.push",
            "reason": "auto:blocked_by(42)",
            "subscription_created_at_event_id": 4287
          }
        ],
        "last_seen_event_id": 4290,
        "open_attentions": ["needs-review"]
      }

  ## Per-binding `subscription_created_at_event_id`

  Each binding carries its own event-ID snapshot captured via
  `Aiur.Events.IdGenerator.peek/0` at the moment the subscription is
  created. The bootstrap-replay logic uses this floor when the
  subscription is fresh (`last_seen_event_id` is `nil`) — replay
  delivers historical events with `id > subscription_created_at_event_id`,
  not events older than the binding.

  **Why event-ID, not wall-clock**: a timestamp floor would re-deliver
  events after NTP step-backwards or VM clock drift. An event-ID floor
  uses the monotonic `IdGenerator` counter, so the floor is unambiguous
  regardless of system time.

  ## Registry lookup

  Registered as `{:via, Registry, {Aiur.Events.SubscriptionStoreRegistry,
  identifier}}`. The supervisor is a DynamicSupervisor — `attach/1` is
  idempotent and starts a writer on first call. The Registry value mirrors
  the durable `open_attentions` count so orchestrator snapshots can read it
  directly from Registry's ETS table without calling this GenServer.

  ## Lifecycle

  The orchestrator owns the lifecycle: `attach/1` when an issue enters
  the running set, `stop/1` when the issue reaches a terminal state.
  `terminate/2` flushes pending writes and unsubscribes every binding
  from the Exchange so ETS rows don't accumulate.
  """

  use GenServer

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Events.{DebugLog, Exchange, IdGenerator}
  alias Aiur.JsonStore
  alias Aiur.Orchestrator.CommentWake

  @registry Aiur.Events.SubscriptionStoreRegistry
  @supervisor Aiur.Events.SubscriptionStoreSupervisor

  @type subscription :: %{
          required(String.t()) => String.t() | non_neg_integer()
        }

  @type snapshot :: %{
          subscribed_to: [subscription()],
          last_seen_event_id: non_neg_integer() | nil,
          open_attentions: [String.t()]
        }

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: opts[:identifier],
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    GenServer.start_link(__MODULE__, opts, name: via(identifier))
  end

  @doc """
  Idempotently ensures a SubscriptionStore is running for `identifier`.
  Reuses an existing writer if present.
  """
  @spec attach(String.t()) :: :ok
  def attach(identifier) when is_binary(identifier) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, identifier: identifier}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("SubscriptionStore.attach(#{identifier}) failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Stops the SubscriptionStore for `identifier`. Triggers `terminate/2`
  flush + Exchange unbinding. No-op if no writer is running.
  """
  @spec stop(String.t()) :: :ok
  def stop(identifier) when is_binary(identifier) do
    case registry_lookup(identifier) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  defp registry_lookup(identifier) do
    Registry.lookup(@registry, identifier)
  rescue
    ArgumentError -> []
  end

  @doc """
  Adds a binding. The reason string is free-form metadata used for
  observability (`"auto:blocked_by(42)"`, `"manual:aiur_subscribe"`).
  Idempotent: re-adding an existing topic keeps the original reason and
  `subscription_created_at_event_id` so bootstrap replay isn't reset and
  reason-filtered removal cannot drop manually retained subscriptions.
  """
  @spec add_subscription(String.t(), String.t(), String.t()) :: :ok
  def add_subscription(identifier, topic, reason)
      when is_binary(identifier) and is_binary(topic) and is_binary(reason) do
    GenServer.call(via(identifier), {:add_subscription, topic, reason})
  end

  @spec remove_subscription(String.t(), String.t()) :: :ok
  def remove_subscription(identifier, topic)
      when is_binary(identifier) and is_binary(topic) do
    GenServer.call(via(identifier), {:remove_subscription, topic})
  end

  @doc """
  Remove an existing subscription only if its recorded `reason` matches
  `expected_reason`. Used by the orchestrator's auto-subscribe path
  so a `:dependency_removed` event tears down the auto-added
  `blocker:auto` / `blockee:auto` entries without accidentally dropping
  a manual subscription on the same topic.
  """
  @spec remove_subscription(String.t(), String.t(), String.t()) :: :ok
  def remove_subscription(identifier, topic, expected_reason)
      when is_binary(identifier) and is_binary(topic) and is_binary(expected_reason) do
    GenServer.call(via(identifier), {:remove_subscription, topic, expected_reason})
  end

  @doc """
  Advances `last_seen_event_id` to `last_id` if it's larger than the
  current value. Monotonic; never rewinds.
  """
  @spec advance_cursor(String.t(), non_neg_integer()) :: :ok
  def advance_cursor(identifier, last_id)
      when is_binary(identifier) and is_integer(last_id) do
    GenServer.call(via(identifier), {:advance_cursor, last_id})
  end

  @spec add_attention(String.t(), String.t()) :: :ok
  def add_attention(identifier, slug)
      when is_binary(identifier) and is_binary(slug) do
    GenServer.call(via(identifier), {:add_attention, slug})
  end

  @spec resolve_attention(String.t(), String.t()) :: :ok
  def resolve_attention(identifier, slug)
      when is_binary(identifier) and is_binary(slug) do
    GenServer.call(via(identifier), {:resolve_attention, slug})
  end

  @spec snapshot(String.t()) :: snapshot() | :not_found
  def snapshot(identifier) when is_binary(identifier) do
    case Registry.lookup(@registry, identifier) do
      [{pid, _}] -> GenServer.call(pid, :snapshot)
      [] -> :not_found
    end
  end

  @doc """
  Open-attention count for one ticket — shared by the CLI agent-list `❗N`
  badge and the OCC-5 fleet-state row. This is a direct Registry ETS lookup,
  never a synchronous call to the per-ticket store, so it is safe on the
  orchestrator snapshot path. A missing, torn-down, or restarting store reads
  as `0`; `init/1` restores the durable count before `attach/1` returns.
  """
  @spec open_attention_count(String.t()) :: non_neg_integer()
  def open_attention_count(identifier) when is_binary(identifier) do
    case registry_lookup(identifier) do
      [{pid, count}] when is_integer(count) and count >= 0 ->
        if Process.alive?(pid), do: count, else: 0

      _ ->
        0
    end
  end

  @doc false
  # Provided so tests can stub the enqueue call without invoking the
  # full orchestrator. Default behaviour: route to Aiur.Orchestrator.
  @spec set_enqueue_fn((String.t(), map() -> :ok) | nil) :: :ok
  def set_enqueue_fn(fun) when is_function(fun, 2) or is_nil(fun) do
    :persistent_term.put({__MODULE__, :enqueue_fn}, fun)
  end

  @impl true
  def init(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    path = path_for(identifier)

    state = %{
      identifier: identifier,
      path: path,
      subscribed_to: [],
      last_seen_event_id: nil,
      open_attentions: []
    }

    # Synchronous load + re-register bindings during init so attach/1
    # never returns to the caller before the Exchange bindings are
    # in the routing table. Otherwise a publish between attach/1 and
    # the binding registration silently drops the event.
    state = load_persisted(state)
    state = register_existing_bindings(state)
    :ok = publish_open_attention_count(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:add_subscription, topic, reason}, _from, state) do
    case Enum.find(state.subscribed_to, &(&1["topic"] == topic)) do
      nil ->
        floor = IdGenerator.peek()

        entry = %{
          "topic" => topic,
          "reason" => reason,
          "subscription_created_at_event_id" => floor
        }

        new_state = %{state | subscribed_to: state.subscribed_to ++ [entry]}
        :ok = persist(new_state)
        :ok = Exchange.subscribe(topic)
        {:reply, :ok, new_state}

      _existing ->
        # First-write-wins on `reason`. Overwriting the reason would let
        # an auto-sub pass (e.g., `blocker:auto`) clobber a prior manual
        # `manual:agent` claim — then `remove_subscription/3` scoped by
        # reason on the next dependency change would drop the manual
        # subscription as collateral. The original write wins; later
        # adds are no-ops at the persistence layer.
        {:reply, :ok, state}
    end
  end

  def handle_call({:remove_subscription, topic}, _from, state) do
    case Enum.find(state.subscribed_to, &(&1["topic"] == topic)) do
      nil ->
        {:reply, :ok, state}

      _entry ->
        updated = Enum.reject(state.subscribed_to, &(&1["topic"] == topic))
        new_state = %{state | subscribed_to: updated}
        :ok = persist(new_state)
        :ok = Exchange.unsubscribe(topic)
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:remove_subscription, topic, expected_reason}, _from, state) do
    case Enum.find(state.subscribed_to, &(&1["topic"] == topic and &1["reason"] == expected_reason)) do
      nil ->
        {:reply, :ok, state}

      _entry ->
        updated = Enum.reject(state.subscribed_to, &(&1["topic"] == topic))
        new_state = %{state | subscribed_to: updated}
        :ok = persist(new_state)
        :ok = Exchange.unsubscribe(topic)
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:advance_cursor, last_id}, _from, state) do
    new_last =
      case state.last_seen_event_id do
        nil -> last_id
        current -> max(current, last_id)
      end

    new_state = %{state | last_seen_event_id: new_last}
    :ok = persist(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:add_attention, slug}, _from, state) do
    if slug in state.open_attentions do
      {:reply, :ok, state}
    else
      new_state = %{state | open_attentions: state.open_attentions ++ [slug]}
      :ok = persist(new_state)
      :ok = publish_open_attention_count(new_state)
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:resolve_attention, slug}, _from, state) do
    if slug in state.open_attentions do
      new_state = %{state | open_attentions: Enum.reject(state.open_attentions, &(&1 == slug))}
      :ok = persist(new_state)
      :ok = publish_open_attention_count(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, to_snapshot(state), state}
  end

  @impl true
  def handle_info({:event, event}, state) do
    event_id = Map.get(event, :id) || Map.get(event, "id")

    cursor = state.last_seen_event_id || 0

    if is_integer(event_id) and event_id <= cursor do
      # Redelivery after restart — already consumed.
      {:noreply, state}
    else
      maybe_enqueue_event(state.identifier, event)
      Aiur.IssueLog.record_event(state.identifier, :consumed, event)
      topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"

      DebugLog.broadcast(:receive, topic,
        id: event_id,
        identifier: state.identifier,
        body: event
      )

      new_state = advance_cursor_inline(state, event_id)
      {:noreply, new_state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp advance_cursor_inline(state, event_id) when is_integer(event_id) do
    new_cursor = max(state.last_seen_event_id || 0, event_id)
    new_state = %{state | last_seen_event_id: new_cursor}
    _ = persist(new_state)
    new_state
  end

  defp advance_cursor_inline(state, _), do: state

  defp enqueue_event(identifier, event) do
    case :persistent_term.get({__MODULE__, :enqueue_fn}, nil) do
      fun when is_function(fun, 2) ->
        try do
          fun.(identifier, event)
        rescue
          _ -> :ok
        end

      _ ->
        # Default route: orchestrator's handle_call
        case Process.whereis(Aiur.Orchestrator) do
          nil ->
            :ok

          pid ->
            try do
              GenServer.call(pid, {:enqueue_event_digest, identifier, event}, 1_000)
            catch
              :exit, _ -> :ok
            end
        end
    end
  end

  defp maybe_enqueue_event(identifier, event) do
    if agent_authored_comment_event?(event) do
      Logger.info(
        "SubscriptionStore ignored agent-authored comment before queueing: " <>
          "identifier=#{identifier} topic=#{event_topic(event)}"
      )
    else
      enqueue_event(identifier, event)
    end
  end

  defp agent_authored_comment_event?(event) when is_map(event) do
    CommentWake.agent_authored_comment?(event) and comment_event_topic?(event_topic(event))
  end

  defp agent_authored_comment_event?(_event), do: false

  defp comment_event_topic?(topic) when is_binary(topic) do
    String.ends_with?(topic, ".issue.commented") or
      String.ends_with?(topic, ".pr.review_comment")
  end

  defp comment_event_topic?(_topic), do: false

  defp event_topic(event), do: Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"

  @impl true
  def terminate(_reason, state) do
    for entry <- state.subscribed_to do
      _ = safe_unsubscribe(entry["topic"])
    end

    _ = persist(state)
    :ok
  end

  defp via(identifier), do: {:via, Registry, {@registry, identifier}}

  defp path_for(identifier) do
    safe = Paths.sanitize(identifier)
    Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.#{safe}.subscriptions.json")
  end

  defp load_persisted(state) do
    case JsonStore.read(state.path) do
      {:ok, %{} = data} ->
        %{
          state
          | subscribed_to: Map.get(data, "subscribed_to", []),
            last_seen_event_id: Map.get(data, "last_seen_event_id"),
            open_attentions: Map.get(data, "open_attentions", [])
        }

      {:ok, nil} ->
        state

      {:error, reason} ->
        Logger.warning(
          "SubscriptionStore(#{state.identifier}) corrupt file at #{state.path}: " <>
            inspect(reason) <> "; starting empty"
        )

        state
    end
  end

  defp register_existing_bindings(state) do
    for entry <- state.subscribed_to do
      try do
        :ok = Exchange.subscribe(entry["topic"])
      rescue
        error ->
          Logger.warning(
            "SubscriptionStore(#{state.identifier}) failed to re-register " <>
              entry["topic"] <> ": " <> Exception.message(error)
          )
      end
    end

    state
  end

  defp persist(state) do
    JsonStore.write!(state.path, %{
      "subscribed_to" => state.subscribed_to,
      "last_seen_event_id" => state.last_seen_event_id,
      "open_attentions" => state.open_attentions
    })
  rescue
    error ->
      Logger.warning("SubscriptionStore(#{state.identifier}) persist failed: " <> Exception.message(error))

      :error
  end

  defp safe_unsubscribe(topic) do
    Exchange.unsubscribe(topic)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp publish_open_attention_count(state) do
    _ = Registry.update_value(@registry, state.identifier, fn _current -> length(state.open_attentions) end)
    :ok
  end

  defp to_snapshot(state) do
    %{
      subscribed_to: state.subscribed_to,
      last_seen_event_id: state.last_seen_event_id,
      open_attentions: state.open_attentions
    }
  end
end
