defmodule Aiur.DecisionStore.Persistence do
  @moduledoc false

  require Logger

  alias Aiur.Boot
  alias Aiur.Decision
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionEvent
  alias Aiur.DecisionProjection
  alias Aiur.DecisionPubSub
  alias Aiur.DecisionRevision
  alias Aiur.DecisionStore.AppendRecovery
  alias Aiur.DecisionStore.Audit
  alias Aiur.DecisionStore.Index
  alias Aiur.DecisionStore.ProjectionRecovery
  alias Aiur.DecisionStore.Requests
  alias Aiur.DecisionStore.RetainedSnapshot
  alias Aiur.Events.Publisher
  alias Aiur.Journal
  alias Aiur.Signal

  @spec repair_projection(term()) :: term()
  def repair_projection(state), do: ProjectionRecovery.repair(state, &notify_projection_event/3)

  defp notify_projection_event(decision, %{type: :requested} = event, state), do: Audit.notify(decision, ProjectionRecovery.cursor_id(event), state)
  defp notify_projection_event(decision, event, _state), do: notify_lifecycle(decision, event, ProjectionRecovery.cursor_id(event))

  @spec persist_and_notify(term(), term(), term()) :: term()
  def persist_and_notify(decision, event_id, state) do
    with {:ok, event} <-
           DecisionEvent.new(:requested, decision.decision_id, decision.version, decision,
             event_id: event_id,
             run_id: Boot.run_id(),
             now: decision.created_at
           ),
         :ok <- append_event(state, event) do
      current = project_request(state, event)

      new_state =
        %{
          state
          | current: Map.put(state.current, decision.decision_id, current),
            decision_index:
              Index.update_decision_index(
                state.decision_index,
                Map.get(state.current, decision.decision_id),
                current
              ),
            retained_index:
              RetainedSnapshot.update_index(
                state.retained_index,
                Map.get(state.current, decision.decision_id),
                current
              ),
            history: Map.update(state.history, decision.decision_id, [decision], &[decision | &1]),
            audit_history: Map.update(state.audit_history, decision.decision_id, [event], &(&1 ++ [event])),
            recent_audit: Audit.remember_recent_audit(state.recent_audit, event)
        }
        |> ProjectionRecovery.enqueue(current, event)
        |> repair_projection()

      {:reply, {:ok, %{status: :accepted, decision: current}}, new_state}
    else
      {:error, reason} -> {:reply, {:error, {:append_failed, reason}}, journal_failure_state(state, reason)}
    end
  end

  defp project_request(state, event) do
    records =
      case Map.get(state.current, event.decision_id) do
        nil -> [event]
        existing -> [existing, event]
      end

    DecisionProjection.reduce(records).current[event.decision_id]
  end

  @spec build_and_persist_event(term(), term(), term(), term(), term()) :: term()
  def build_and_persist_event(type, decision, data, occurred_at, state) do
    with {:ok, next_state, updated, event} <-
           build_and_append_event(type, decision, data, occurred_at, state) do
      finalized = repair_and_notify_lifecycle(next_state, [{updated, event}])
      {:ok, finalized, updated}
    end
  end

  @spec build_and_append_event(term(), term(), term(), term(), term()) :: term()
  def build_and_append_event(type, decision, data, occurred_at, state) do
    with {:ok, event_id} <- state.event_id_reserver.(),
         {:ok, event} <-
           DecisionEvent.new(type, decision.decision_id, lifecycle_version(decision, data), data,
             event_id: event_id,
             run_id: Boot.run_id(),
             now: occurred_at
           ),
         {:ok, updated} <- validate_transition(decision, event),
         :ok <- append_event(state, event) do
      {:ok, apply_appended_event(state, decision, updated, event), updated, event}
    else
      {:error, :not_durable} -> {:error, :event_id_not_durable}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec apply_appended_event(term(), term(), term(), term()) :: term()
  def apply_appended_event(state, decision, updated, event) do
    %{
      state
      | current: Map.put(state.current, decision.decision_id, updated),
        decision_index: Index.update_decision_index(state.decision_index, decision, updated),
        retained_index: RetainedSnapshot.update_index(state.retained_index, decision, updated),
        audit_history: Map.update(state.audit_history, decision.decision_id, [event], &(&1 ++ [event])),
        recent_audit: Audit.remember_recent_audit(state.recent_audit, event)
    }
  end

  @spec append_event(term(), term()) :: term()
  def append_event(%{writable?: false, health: health}, _event), do: {:error, {:store_unavailable, health}}

  def append_event(state, event) do
    case Journal.append(state.ndjson_path, DecisionEvent.to_json_safe(event), file_ops: state.file_ops) do
      :accepted -> :ok
      {:failed, reason} -> {:error, reason}
      {:ambiguous, _reason} -> reconcile_append(state, event)
    end
  end

  @spec reconcile_append(term(), term()) :: term()
  def reconcile_append(state, event) do
    case verify_journal(state) do
      :ok ->
        case Journal.reconcile_ambiguous(state.ndjson_path, event.event_id, &DecisionProjection.decode_record/1) do
          :accepted -> :ok
          :failed -> retry_missing_append(state, event)
          {:ambiguous, reason} -> {:error, {:journal_ambiguous, event, reason}}
        end

      {:error, reason} ->
        {:error, {:journal_ambiguous, event, reason}}
    end
  end

  @spec verify_journal(term()) :: term()
  def verify_journal(state) do
    case Journal.replay(state.ndjson_path, &DecisionProjection.decode_record/1) do
      {:ok, records, nil} ->
        case DecisionProjection.reduce_checked(records) do
          {_projection, nil} -> :ok
          {_projection, corruption} -> {:error, corruption}
        end

      {:ok, _records, corruption} ->
        {:error, corruption}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_missing_append(state, event) do
    case Journal.append(state.ndjson_path, DecisionEvent.to_json_safe(event), file_ops: state.file_ops) do
      :accepted -> :ok
      {:failed, reason} -> {:error, reason}
      {:ambiguous, reason} -> {:error, {:journal_ambiguous, event, reason}}
    end
  end

  @spec journal_failure_state(term(), term()) :: term()
  def journal_failure_state(state, {:journal_ambiguous, event, reason}) do
    _ = Signal.agent_alert("decision_store.append_ambiguous", "Decision journal outcome is unknown; writes are held.", reason: "Event #{event.event_id}: #{inspect(reason)}", needs_attention: true)
    %{state | writable?: false, health: {:journal_ambiguous, event.event_id, reason}}
  end

  def journal_failure_state(state, _reason), do: state

  @spec repair_and_notify_lifecycle(term(), term()) :: term()
  def repair_and_notify_lifecycle(state, lifecycle_events) do
    next_state = Enum.reduce(lifecycle_events, state, fn {decision, event}, acc -> ProjectionRecovery.enqueue(acc, decision, event) end)

    next_state =
      Enum.reduce(lifecycle_events, next_state, fn {decision, event}, state_acc ->
        case Map.get(event.data, :action_id) do
          action_id when is_binary(action_id) ->
            AppendRecovery.resolve_lifecycle_append_failure(state_acc, decision, action_id)

          _action_id ->
            state_acc
        end
      end)

    repair_projection(next_state)
  end

  defp lifecycle_version(_decision, %DecisionAnswer{decision_version: version}), do: version
  defp lifecycle_version(_decision, %DecisionRevision{decision_version: version}), do: version

  defp lifecycle_version(decision, %{action_id: action_id}) do
    case Decision.answer_for_action(decision, action_id) do
      %DecisionAnswer{decision_version: version} -> version
      nil -> decision.version
    end
  end

  defp lifecycle_version(decision, %{actor: _actor}), do: decision.version
  defp lifecycle_version(decision, %{reason_class: _reason_class}), do: decision.version

  defp lifecycle_version(decision, _data), do: Decision.active_answer(decision).decision_version

  @spec validate_transition(term(), term()) :: term()
  def validate_transition(decision, event) do
    case DecisionProjection.reduce_checked([decision, event]) do
      {%{current: current}, nil} -> {:ok, current[decision.decision_id]}
      {_projection, {:corrupt, _line, {:invalid_transition, reason}}} -> {:error, {:invalid_transition, reason}}
    end
  end

  defp notify_lifecycle(decision, event, cursor_event_id) do
    topic = "ticket.#{decision.ticket.identifier}.agent.decision.#{Requests.lifecycle_slug(event.type)}"

    try do
      Publisher.publish_persisted(topic, DecisionEvent.to_json_safe(event), cursor_event_id, digest_source: :orchestrator)
    rescue
      error -> Logger.warning("aiur_decision_store phase=lifecycle_publisher_failed error=#{Exception.message(error)}")
    end

    if event.type == :decision_deferred do
      Requests.notify_deferred_executor(decision)
    end

    if event.type in [:answer_recorded, :decision_dismissed, :decision_expired, :decision_mooted] do
      Requests.resolve_executor_escalation(decision)
    end

    try do
      DecisionPubSub.broadcast_changed(decision.decision_id, decision.version)
    rescue
      error -> Logger.warning("aiur_decision_store phase=lifecycle_pubsub_failed error=#{Exception.message(error)}")
    end

    :ok
  end
end
