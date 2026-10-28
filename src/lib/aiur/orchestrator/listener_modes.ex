defmodule Aiur.Orchestrator.ListenerModes do
  @moduledoc "Serialized mode control and pending listener delivery updates."

  require Logger
  alias Aiur.{AgentPubSub, AgentQueueStore, Events, TrackerIdentity}
  alias Aiur.Events.Catalog
  alias Aiur.Listener.{Effective, ModeStore, Scheduler}
  alias Aiur.Orchestrator.{ListenerTransitions, State}
  alias Aiur.Orchestrator.OperatorMessages.{Capabilities, DeliveryPolicy, Unread}

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
        previous = ModeStore.get(id)

        case ModeStore.put(id, mode, version, meta) do
          {:ok, record} ->
            result = view(state, id, entry, record)
            Logger.info("listener_mode_set issue=#{id} requested=#{result.requested} effective=#{inspect(result.effective)} version=#{result.version} actor=#{result.actor}")
            {store, backlog} = transition(state.queue_store, id, previous, result, opts)
            {:ok, id, result, store, backlog}

          {:error, {:mode_conflict, record}} ->
            {:error, {:mode_conflict, view(state, id, entry, record)}}

          {:error, _} = error ->
            error
        end
      else
        {:error, _} = error -> error
        _invalid_version -> {:error, :invalid_expected_version}
      end

    finish_set_mode(state, reply)
  end

  defp finish_set_mode(state, reply) do
    case reply do
      {:ok, id, result, store, backlog} ->
        key = State.find_running_key_by_identifier(state.running, id)
        broadcast(id, if(backlog, do: Map.put(result, :backlog, backlog), else: result), if(key, do: state.running[key]))
        next = %{state | queue_store: store}
        next = if key, do: put_in(next.running[key][:listener_effective], result), else: next
        next = mode_view_changed(next, id, result)
        if backlog, do: notify_notice(next, id)
        {:reply, {:ok, result}, next}

      _error ->
        {:reply, reply, state}
    end
  end

  defp transition(store, id, previous, result, opts) do
    if Scheduler.routing(opts) == :listener,
      do: ListenerTransitions.on_change(store, id, previous, result),
      else: {store, nil}
  end

  defp notify_notice(state, id) do
    item = Enum.find(AgentQueueStore.list_pending(state.queue_store, id), &(&1.event_type == :async_backlog_notice))
    if item, do: DeliveryPolicy.notify_running_queue_update(state, State.find_running_by_identifier(state.running, id), item)
  end

  @doc "Re-stamp pending listener rows after a serialized mode or harness-view change."
  @spec mode_view_changed(State.t(), String.t(), map()) :: State.t()
  def mode_view_changed(state, id, view) do
    store = AgentQueueStore.update_pending_delivery(state.queue_store, id, Scheduler.restamp_fun(view))
    pending = AgentQueueStore.list_pending(store, id)
    changed = Enum.find(pending, fn item -> item.delivery != AgentQueueStore.get(state.queue_store, item.id).delivery end)
    Unread.broadcast_change(state.queue_store, store, id)
    next_state = %{state | queue_store: store}
    if changed, do: DeliveryPolicy.notify_running_queue_update(next_state, State.find_running_by_identifier(state.running, id), changed)
    next_state
  end

  @doc "Refresh derived listener mode and control flags after a session or dispatch update."
  @spec on_session_execution(State.t(), String.t(), map() | nil) :: State.t()
  def on_session_execution(state, issue_id, previous_entry) do
    entry = Map.fetch!(state.running, issue_id)
    harness = Capabilities.harness_delivery(state, to_string(issue_id), entry)
    updated = entry |> refresh_view(state, previous_entry, harness) |> refresh_control(harness)
    next = put_in(state.running[issue_id], updated)

    case updated do
      %{identifier: id, listener_effective: result} -> mode_view_changed(next, id, result)
      _identifierless -> next
    end
  end

  defp refresh_view(%{identifier: id} = entry, state, previous_entry, harness) when is_binary(id) and id != "" do
    record = ModeStore.get(id)
    result = %{compute(record, harness, entry) | actor: :system}
    previous = if previous_entry, do: previous_entry[:listener_effective] || view(state, id, previous_entry, record)

    if is_nil(previous) or {previous.effective, previous.effective_reason} != {result.effective, result.effective_reason} do
      broadcast(id, result, entry)
    end

    Map.put(entry, :listener_effective, result)
  end

  # Identifier-less tracker entries can still dispatch and report their running backend.
  defp refresh_view(entry, _state, _previous_entry, _harness), do: entry

  defp refresh_control(entry, %{harness_id: backend}) do
    flags = Capabilities.backend_control_flags(backend)
    Map.update(entry, :control, flags, &Map.merge(&1, flags))
  end

  defp broadcast(id, result, entry) do
    payload = event_payload(result)
    AgentPubSub.broadcast_listen_mode(id, payload)
    issue_id = entry && entry[:issue] && entry.issue.id
    publish(id, payload, "issue_id=#{issue_id || "unknown"} issue_identifier=#{id}")
  end

  defp publish(id, payload, context) do
    topic = "ticket.#{id}.agent.listen-mode.changed"

    if Catalog.lookup(topic).pattern == "ticket.*.agent.listen-mode.changed" do
      case Events.publish(topic, payload, issue_number: id) do
        {:ok, _, _} -> :ok
        outcome when outcome in [:filtered, :deduped] -> Logger.debug("listener_mode_publish #{context} outcome=#{outcome}")
        {:error, reason} -> Logger.warning("listener_mode_publish #{context} error=#{inspect(reason)}")
      end
    end
  rescue
    error -> Logger.warning("listener_mode_publish #{context} error=#{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("listener_mode_publish #{context} exit=#{inspect(reason)}")
  end

  defp event_payload(result), do: Map.take(result, [:requested, :effective, :effective_reason, :version, :actor, :backlog])

  defp view(state, id, entry, record), do: compute(record, Capabilities.harness_delivery(state, id, entry), entry)

  defp compute(record, harness, entry) do
    installed? = get_in(entry || %{}, [:session_execution, :pull_tool_installed]) == true
    Effective.compute(record, harness, pull_tool_installed?: installed?)
  end

  defp resolve(state, %TrackerIdentity{} = identity) do
    case State.find_unique_running_by_identity(state.running, identity) do
      {:ok, entry, id} -> {:ok, id, entry}
      {:error, :no_running_agent} -> stopped_identity(state, identity.identifier)
      {:error, _} = error -> error
    end
  end

  defp resolve(state, id) when is_binary(id) do
    canonical = Enum.find_value(state.last_polled_issues, fn {key, issue} -> if id in [to_string(key), issue.identifier], do: issue.identifier end)
    entry = State.find_running_by_identifier(state.running, canonical || id)

    if entry || canonical,
      do: {:ok, canonical || id, entry},
      else: {:error, :issue_not_found}
  end

  defp stopped_identity(state, id) do
    if State.find_running_by_identifier(state.running, id), do: {:error, :ambiguous_identifier}, else: resolve(state, id)
  end
end
