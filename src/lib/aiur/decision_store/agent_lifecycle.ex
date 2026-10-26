defmodule Aiur.DecisionStore.AgentLifecycle do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionEvent
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.FailureAttention
  alias Aiur.DecisionStore.Persistence

  @spec apply_agent_lifecycle(term(), term(), term(), term()) :: term()
  def apply_agent_lifecycle(state, type, payload, opts) do
    with {:ok, context} <- normalize_agent_lifecycle(type, payload, opts),
         {:ok, decision} <- Answers.fetch_decision(state, context.decision_id),
         :ok <- validate_agent_lifecycle_target(decision, context),
         {:ok, outcome} <- evaluate_agent_lifecycle(decision, type, context.data) do
      persist_or_replay_agent_lifecycle(state, decision, type, context.data, outcome)
    else
      {:error, reason} -> {{:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp normalize_agent_lifecycle(type, payload, opts) do
    decision_id = payload_value(payload, :decision_id)
    action_id = payload_value(payload, :action_id)
    expected_version = payload_value(payload, :expected_version)
    detail = payload_value(payload, :detail)
    ticket_identifier = Keyword.get(opts, :ticket_identifier)
    actor = Keyword.get(opts, :actor)
    source = Keyword.get(opts, :source, %{})
    event_data = %{action_id: action_id, actor: actor, source: source, detail: detail}

    with true <- (is_binary(decision_id) and decision_id != "") or {:error, :invalid_decision_id},
         true <- (is_binary(ticket_identifier) and ticket_identifier != "") or {:error, :invalid_ticket},
         true <- is_map(actor) or {:error, :invalid_actor},
         {:ok, candidate} <-
           DecisionEvent.new(type, decision_id, expected_version, event_data,
             event_id: "lifecycle-validation",
             run_id: "lifecycle-validation"
           ),
         true <- candidate.data.actor.kind == :agent or {:error, :invalid_actor} do
      {:ok,
       %{
         decision_id: decision_id,
         expected_version: expected_version,
         ticket_identifier: ticket_identifier,
         data: candidate.data
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec payload_value(term(), term()) :: term()
  def payload_value(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))

  defp validate_agent_lifecycle_target(decision, context) do
    active_answer = Decision.active_answer(decision)

    cond do
      decision.ticket.identifier != context.ticket_identifier ->
        {:error, {:conflict, {:ticket_mismatch, context.ticket_identifier, decision.ticket.identifier}}}

      is_nil(active_answer) ->
        {:error, {:invalid_transition, :answer_missing}}

      active_answer.action_id != context.data.action_id ->
        {:error, {:conflict, {:action_mismatch, context.data.action_id, active_answer.action_id}}}

      active_answer.decision_version != context.expected_version ->
        {:error, {:conflict, {:stale_version, context.expected_version, active_answer.decision_version}}}

      true ->
        :ok
    end
  end

  defp evaluate_agent_lifecycle(decision, :acknowledged, data) do
    case decision.acknowledgement do
      nil -> if delivered_once?(decision), do: {:ok, :accept}, else: {:error, {:invalid_transition, :not_delivered}}
      fact -> compare_lifecycle_replay(fact, data, :already_acknowledged)
    end
  end

  defp evaluate_agent_lifecycle(decision, :resolved, data) do
    cond do
      is_nil(decision.acknowledgement) -> {:error, {:invalid_transition, :not_acknowledged}}
      is_nil(decision.resolution) -> {:ok, :accept}
      true -> compare_lifecycle_replay(decision.resolution, data, :already_resolved)
    end
  end

  defp delivered_once?(decision) do
    Enum.any?(Decision.active_dispatch_attempts(decision), &(not is_nil(&1.delivered_at)))
  end

  defp compare_lifecycle_replay(fact, data, conflict) do
    if fact.action_id == data.action_id and fact.actor == data.actor and fact.detail == data.detail do
      {:ok, :duplicate}
    else
      {:error, {:conflict, {conflict, fact.action_id}}}
    end
  end

  defp persist_or_replay_agent_lifecycle(state, decision, type, _data, :duplicate) do
    result = agent_lifecycle_result(:duplicate, decision, type)
    {{:ok, result}, state}
  end

  defp persist_or_replay_agent_lifecycle(state, decision, type, data, :accept) do
    case Persistence.build_and_persist_event(type, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state = FailureAttention.project_delivery_attention(next_state, decision, updated, type)
        {{:ok, agent_lifecycle_result(:accepted, updated, type)}, next_state}

      {:error, reason} ->
        {{:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp agent_lifecycle_result(status, decision, type) do
    active_answer = Decision.active_answer(decision)

    %{
      status: status,
      lifecycle: type,
      decision_id: decision.decision_id,
      version: decision.version,
      answered_version: active_answer.decision_version,
      action_id: active_answer.action_id,
      decision_status: decision.decision_status
    }
  end
end
