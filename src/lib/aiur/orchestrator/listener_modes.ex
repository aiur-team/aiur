defmodule Aiur.Orchestrator.ListenerModes do
  @moduledoc "Serialized mode control and pending listener delivery updates."

  require Logger
  alias Aiur.{AgentQueueStore, TrackerIdentity}
  alias Aiur.Listener.{Effective, ModeStore, Scheduler}
  alias Aiur.Orchestrator.OperatorMessages.{Capabilities, DeliveryPolicy}
  alias Aiur.Orchestrator.State

  @spec get_mode(State.t(), Aiur.Listener.target()) :: tuple()
  def get_mode(state, target) do
    reply = with {:ok, id, entry} <- resolve(state, target), do: {:ok, view(state, id, entry, ModeStore.get(id))}
    {:reply, reply, state}
  end

  @spec set_mode(State.t(), Aiur.Listener.target(), ModeStore.mode(), keyword()) :: tuple()
  def set_mode(state, target, mode, opts) do
    reply =
      with version when is_integer(version) and version >= 0 <- opts[:expected_version],
           {:ok, id, entry} <- resolve(state, target) do
        meta = %{actor: Keyword.get(opts, :actor, :human), idempotency_key: opts[:idempotency_key]}

        case ModeStore.put(id, mode, version, meta) do
          {:ok, record} ->
            result = view(state, id, entry, record)
            Logger.info("listener_mode_set issue=#{id} requested=#{result.requested} effective=#{inspect(result.effective)} version=#{result.version} actor=#{result.actor}")
            {:ok, result}

          {:error, {:mode_conflict, record}} ->
            {:error, {:mode_conflict, view(state, id, entry, record)}}

          {:error, _} = error ->
            error
        end
      else
        {:error, _} = error -> error
        _invalid_version -> {:error, :invalid_expected_version}
      end

    next_state =
      with {:ok, result} <- reply,
           {:ok, id, _entry} <- resolve(state, target) do
        mode_view_changed(state, id, result)
      else
        _error -> state
      end

    {:reply, reply, next_state}
  end

  @doc "Re-stamp pending listener rows after a serialized mode or harness-view change."
  @spec mode_view_changed(State.t(), String.t(), map()) :: State.t()
  def mode_view_changed(state, id, view) do
    store = AgentQueueStore.update_pending_delivery(state.queue_store, id, Scheduler.restamp_fun(view))
    pending = AgentQueueStore.list_pending(store, id)
    changed = Enum.find(pending, fn item -> item.delivery != AgentQueueStore.get(state.queue_store, item.id).delivery end)
    next_state = %{state | queue_store: store}
    if changed, do: DeliveryPolicy.notify_running_queue_update(next_state, State.find_running_by_identifier(state.running, id), changed)
    next_state
  end

  defp view(state, id, entry, record), do: Effective.compute(record, Capabilities.harness_delivery(state, id, entry))

  defp resolve(state, %TrackerIdentity{} = identity) do
    case State.find_unique_running_by_identity(state.running, identity) do
      {:ok, entry, id} -> {:ok, id, entry}
      {:error, :no_running_agent} -> stopped_identity(state, identity.identifier)
      {:error, _} = error -> error
    end
  end

  defp resolve(state, id) when is_binary(id), do: {:ok, id, State.find_running_by_identifier(state.running, id)}

  defp stopped_identity(state, id) do
    if State.find_running_by_identifier(state.running, id), do: {:error, :ambiguous_identifier}, else: {:ok, id, nil}
  end
end
