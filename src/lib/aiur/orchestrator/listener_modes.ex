defmodule Aiur.Orchestrator.ListenerModes do
  @moduledoc "Serialized mode reads and compare-and-set writes; queue state is unchanged."

  require Logger
  alias Aiur.Listener.{Effective, ModeStore}
  alias Aiur.Orchestrator.OperatorMessages.Capabilities
  alias Aiur.Orchestrator.State
  alias Aiur.TrackerIdentity

  @spec get_mode(State.t(), Aiur.Listener.target()) :: tuple()
  def get_mode(state, target) do
    reply = with {:ok, id, entry} <- resolve(state, target), do: {:ok, view(state, id, entry, ModeStore.get(id))}
    {:reply, reply, state}
  end

  @spec set_mode(State.t(), Aiur.Listener.target(), ModeStore.mode(), keyword()) :: tuple()
  def set_mode(state, target, mode, opts) do
    reply =
      with {:ok, id, entry} <- resolve(state, target) do
        meta = %{actor: Keyword.get(opts, :actor, :human), idempotency_key: opts[:idempotency_key]}

        case ModeStore.put(id, mode, Keyword.fetch!(opts, :expected_version), meta) do
          {:ok, record} ->
            result = view(state, id, entry, record)
            Logger.info("listener_mode_set issue=#{id} requested=#{result.requested} effective=#{inspect(result.effective)} version=#{result.version} actor=#{result.actor}")
            {:ok, result}

          {:error, {:mode_conflict, record}} ->
            {:error, {:mode_conflict, view(state, id, entry, record)}}

          {:error, _} = error ->
            error
        end
      end

    {:reply, reply, state}
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
