defmodule Aiur.Events.SubscriptionStore.Persistence do
  @moduledoc false
  # aiur:event-bus-boundary-member

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Events.{AgentSubscriptionPolicy, Exchange}
  alias Aiur.JsonStore

  @state_leaf "subscriptions"
  @registry Aiur.Events.SubscriptionStoreRegistry

  @doc """
  Absolute path of the subscription file for `identifier`.

  The file lives in the durable runtime state directory. When that directory
  cannot be resolved, the per-launch log directory is the only place left,
  which keeps the old behavior instead of dropping subscriptions.
  """
  @spec path_for(String.t()) :: Path.t()
  def path_for(identifier) when is_binary(identifier) do
    file_name = "#{Paths.repo_name()}.#{Paths.sanitize(identifier)}.subscriptions.json"

    case Paths.runtime_state_dir() do
      {:ok, root} ->
        dir = Path.join(root, @state_leaf)
        Path.join(dir, file_name)

      {:error, _reason} ->
        Path.join(Paths.log_root_dir(), file_name)
    end
  end

  @doc false
  @spec load_persisted(map()) :: map()
  def load_persisted(state) do
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

  @doc false
  @spec register_existing_bindings(map()) :: map()
  def register_existing_bindings(state) do
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

  @doc false
  @spec prune_unsafe_manual_subscriptions(map()) :: map()
  def prune_unsafe_manual_subscriptions(state) do
    {unsafe, retained} =
      Enum.split_with(state.subscribed_to, fn entry ->
        Map.get(entry, "reason") == "manual:agent" and
          AgentSubscriptionPolicy.validate(Map.get(entry, "topic", "")) != :ok
      end)

    case unsafe do
      [] ->
        state

      entries ->
        topics = Enum.map(entries, &Map.get(&1, "topic"))
        new_state = %{state | subscribed_to: retained}

        Logger.warning(
          "SubscriptionStore(#{state.identifier}) pruned unsafe manual agent bindings: " <>
            inspect(topics)
        )

        if persist(new_state) != :ok do
          Logger.warning(
            "SubscriptionStore(#{state.identifier}) could not persist pruned manual agent bindings; " <>
              "unsafe topics remain excluded in memory and cleanup will retry on attach"
          )
        end

        new_state
    end
  end

  @doc false
  @spec persist(map()) :: :ok | :error
  def persist(state) do
    JsonStore.write!(state.path, %{
      "subscribed_to" => state.subscribed_to,
      "last_seen_event_id" => state.last_seen_event_id,
      "open_attentions" => state.open_attentions
    })

    _ = Registry.update_value(@registry, {state.identifier, :subscriptions}, fn _ -> state.subscribed_to end)
    :ok
  rescue
    error ->
      Logger.warning("SubscriptionStore(#{state.identifier}) persist failed: " <> Exception.message(error))

      :error
  end

  @doc false
  @spec safe_unsubscribe(String.t()) :: :ok
  def safe_unsubscribe(topic) do
    Exchange.unsubscribe(topic)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
