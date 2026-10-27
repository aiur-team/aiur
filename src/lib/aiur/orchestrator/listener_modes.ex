defmodule Aiur.Orchestrator.ListenerModes do
  @moduledoc "Serialized mode reads and compare-and-set writes; queue state is unchanged."

  require Logger
  alias Aiur.AgentPubSub
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
      with version when is_integer(version) and version >= 0 <- opts[:expected_version],
           {:ok, id, entry} <- resolve(state, target) do
        meta = %{actor: Keyword.get(opts, :actor, :human), idempotency_key: opts[:idempotency_key]}

        case ModeStore.put(id, mode, version, meta) do
          {:ok, record} ->
            result = view(state, id, entry, record)
            Logger.info("listener_mode_set issue=#{id} requested=#{result.requested} effective=#{inspect(result.effective)} version=#{result.version} actor=#{result.actor}")
            {:ok, id, result}

          {:error, {:mode_conflict, record}} ->
            {:error, {:mode_conflict, view(state, id, entry, record)}}

          {:error, _} = error ->
            error
        end
      else
        {:error, _} = error -> error
        _invalid_version -> {:error, :invalid_expected_version}
      end

    case reply do
      {:ok, id, result} ->
        AgentPubSub.broadcast_listen_mode(id, event_payload(result))
        key = State.find_running_key_by_identifier(state.running, id)
        next = if key, do: put_in(state.running[key][:listener_effective], result), else: state
        {:reply, {:ok, result}, next}

      _error ->
        {:reply, reply, state}
    end
  end

  @doc "Refresh derived listener mode and control flags after a session or dispatch update."
  @spec on_session_execution(State.t(), String.t(), map() | nil) :: State.t()
  def on_session_execution(state, issue_id, previous_entry) do
    entry = Map.fetch!(state.running, issue_id)
    id = entry.identifier
    record = ModeStore.get(id)
    result = %{view(state, id, entry, record) | actor: :system}
    previous = if previous_entry, do: previous_entry[:listener_effective] || view(state, id, previous_entry, record)

    if is_nil(previous) or {previous.effective, previous.effective_reason} != {result.effective, result.effective_reason} do
      AgentPubSub.broadcast_listen_mode(id, event_payload(result))
    end

    updated = entry |> Map.put(:listener_effective, result) |> refresh_control(Capabilities.harness_delivery(state, id, entry))
    put_in(state.running[issue_id], updated)
  end

  defp refresh_control(entry, %{harness_id: backend}) do
    flags = Capabilities.backend_control_flags(backend)
    Map.update(entry, :control, flags, &Map.merge(&1, flags))
  end

  defp event_payload(result), do: Map.take(result, [:requested, :effective, :effective_reason, :version, :actor])

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
