defmodule Aiur.Events.SubscriptionStore do
  @moduledoc """
  Per-issue GenServer that owns the persistent subscription state for one
  Aiur ticket.

  Persists to `<runtime-state>/subscriptions/<repo>.<id>.subscriptions.json`
  via the atomic-rename helper in `Aiur.JsonStore`. On `init/1` it reads the
  file and re-registers every binding with `Aiur.Events.Exchange` so a BEAM
  restart doesn't drop subscriptions silently.

  The runtime state directory (`Aiur.Config.Paths.runtime_state_dir/0`)
  survives a daemon restart; the per-launch log directory where these files
  used to live does not (#2722). Legacy subscriptions are never imported;
  subscriptions saved from that boot onward are durable.

  ## State shape (on disk)

      {
        "subscribed_to": [
          {
            "topic": "ticket.42.branch.push",
            "reason": "blocker:auto",
            "subscription_created_at_event_id": 4287
          }
        ],
        "last_seen_event_id": 4290,
        "open_attentions": ["needs-review"]
      }

  Each binding records a monotonic `subscription_created_at_event_id`: fresh
  bootstrap replay delivers newer IDs, so clock drift cannot replay old events.

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
  # aiur:event-bus-boundary-member
  use GenServer

  require Logger

  alias Aiur.Events.{AgentSubscriptionPolicy, Exchange, IdGenerator}
  alias Aiur.Events.SubscriptionStore.{Persistence, Processing}

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
    registry_lookup_fn = :persistent_term.get({__MODULE__, :registry_lookup_fn}, nil)

    case registry_lookup_fn do
      fun when is_function(fun, 2) -> fun.(@registry, identifier)
      nil -> Registry.lookup(@registry, identifier)
    end
  rescue
    ArgumentError -> []
  end

  @doc false
  @spec set_registry_lookup_fn((atom(), String.t() -> [{pid(), term()}]) | nil) :: :ok
  def set_registry_lookup_fn(fun) when is_function(fun, 2) or is_nil(fun) do
    :persistent_term.put({__MODULE__, :registry_lookup_fn}, fun)
  end

  @doc """
  Adds a binding. The reason string is free-form metadata used for
  observability (e.g. `"blocker:auto"`, `"own_comments:auto"`, or
  `"manual:agent"` for an explicit `aiur_subscribe`).
  Idempotent: re-adding an existing topic keeps the original reason and
  `subscription_created_at_event_id` so bootstrap replay isn't reset and
  reason-filtered removal cannot drop manually retained subscriptions.
  """
  @spec add_subscription(String.t(), String.t(), String.t()) ::
          :ok | {:error, :agent_subscription_scope_forbidden}
  def add_subscription(identifier, topic, "manual:agent")
      when is_binary(identifier) and is_binary(topic) do
    with :ok <- AgentSubscriptionPolicy.validate(topic) do
      GenServer.call(via(identifier), {:add_subscription, topic, "manual:agent"})
    end
  end

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
    case registry_lookup(identifier) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :snapshot)
        catch
          :exit, reason when reason in [:noproc, :normal, :shutdown] -> :not_found
          :exit, {reason, {GenServer, :call, _args}} when reason in [:noproc, :normal, :shutdown] -> :not_found
        end

      [] ->
        :not_found
    end
  end

  @doc "Bindings mirrored in Registry ETS; safe while the store waits on the Orchestrator."
  @spec subscriptions(String.t()) :: [subscription()]
  def subscriptions(identifier) when is_binary(identifier) do
    case Registry.lookup(@registry, {identifier, :subscriptions}) do
      [{pid, subscriptions}] -> if Process.alive?(pid), do: subscriptions, else: []
      [] -> []
    end
  rescue
    ArgumentError -> []
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
    case open_attention_count_result(identifier) do
      {:ok, count} -> count
      {:error, :unavailable} -> 0
    end
  end

  @doc "Returns the direct-read count without collapsing a missing or restarting store to an exact zero."
  @spec open_attention_count_result(String.t()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def open_attention_count_result(identifier) when is_binary(identifier) do
    case registry_lookup(identifier) do
      [{pid, count}] when is_integer(count) and count >= 0 ->
        if Process.alive?(pid), do: {:ok, count}, else: {:error, :unavailable}

      _ ->
        {:error, :unavailable}
    end
  end

  @doc false
  # Provided so tests can stub the enqueue call without invoking the
  # full orchestrator. Default behaviour: route to the configured delivery sink.
  @spec set_enqueue_fn((String.t(), map() -> :ok | {:error, term()}) | nil) :: :ok
  def set_enqueue_fn(fun) when is_function(fun, 2) or is_nil(fun) do
    :persistent_term.put({__MODULE__, :enqueue_fn}, fun)
  end

  @impl true
  def init(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    path = path_for(identifier)

    state = %{
      identifier: identifier,
      delivery: Application.fetch_env!(:aiur, Aiur.Events.Delivery),
      path: path,
      subscribed_to: [],
      last_seen_event_id: nil,
      open_attentions: [],
      stall: nil,
      stalled_buffer: []
    }

    # Register bindings before attach/1 returns so concurrent events are not lost.
    state = Persistence.load_persisted(state)
    state = Persistence.prune_unsafe_manual_subscriptions(state)
    state = Persistence.register_existing_bindings(state)
    :ok = publish_open_attention_count(state)
    {:ok, _} = Registry.register(@registry, {identifier, :subscriptions}, state.subscribed_to)

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
        :ok = Persistence.persist(new_state)
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
        :ok = Persistence.persist(new_state)
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
        :ok = Persistence.persist(new_state)
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
    :ok = Persistence.persist(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:add_attention, slug}, _from, state) do
    if slug in state.open_attentions do
      {:reply, :ok, state}
    else
      new_state = %{state | open_attentions: state.open_attentions ++ [slug]}
      :ok = Persistence.persist(new_state)
      :ok = publish_open_attention_count(new_state)
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:resolve_attention, slug}, _from, state) do
    if slug in state.open_attentions do
      new_state = %{state | open_attentions: Enum.reject(state.open_attentions, &(&1 == slug))}
      :ok = Persistence.persist(new_state)
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
  defdelegate handle_info(message, state), to: Processing

  @impl true
  def terminate(_reason, state) do
    for entry <- state.subscribed_to do
      _ = Persistence.safe_unsubscribe(entry["topic"])
    end

    _ = Persistence.persist(state)
    :ok
  end

  defp via(identifier), do: {:via, Registry, {@registry, identifier}}

  @doc """
  Absolute path of the subscription file for `identifier`.

  The file lives in the durable runtime state directory. When that directory
  cannot be resolved, the per-launch log directory is the only place left,
  which keeps the old behavior instead of dropping subscriptions.
  """
  @spec path_for(String.t()) :: Path.t()
  defdelegate path_for(identifier), to: Persistence

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
