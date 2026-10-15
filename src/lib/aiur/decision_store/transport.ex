defmodule Aiur.DecisionStore.Transport do
  @moduledoc false

  require Logger

  alias Aiur.Decision
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.AppendRecovery
  alias Aiur.DecisionStore.FailureAttention
  alias Aiur.DecisionStore.Persistence
  alias Aiur.DecisionStore.Settlement

  @spec apply_transport_transition(term(), term(), term(), term()) :: term()
  def apply_transport_transition(state, type, item, reason) do
    case correlated_transport_context(state, item) do
      {:ok, decision, attempt, context} when is_map(attempt) ->
        if type == :delivered and attempt.status == :failed do
          persist_restored_attempt_delivery(state, decision, context)
        else
          persist_transport_transition(state, decision, attempt, context, type, reason)
        end

      {:ok, decision, :missing_attempt, context} when type == :delivered ->
        persist_missing_attempt_delivery(state, decision, context)

      {:ok, _decision, :missing_attempt, _context} ->
        {{:error, :attempt_not_found}, state}

      {:ok, :ignored} ->
        {{:ok, :ignored}, state}

      {:error, reason} ->
        {{:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  # This is the last check before a queued answer reaches the provider. It is
  # keyed to the ticket, not to the worker session, so it also guards a later
  # worker of the same ticket: a mooted Command or a replaced (non-active)
  # action is refused here even if its queue item was created earlier (#2711).
  defp validate_transport_delivery(state, item) do
    case withdrawn_delivery(state, item) do
      {:withdrawn, why} -> {:error, {:answer_withdrawn, why}}
      :not_withdrawn -> validate_correlated_delivery(state, item)
    end
  end

  # The gate and the provider confirmation are separate steps, and the send
  # happens between them. A moot or supersede in that window would race the
  # send, so an accepted item is durably marked as handed off before the worker
  # sends it. From then on the answer counts as in flight and cannot be
  # withdrawn (#2711). If the mark cannot be written, the gate fails closed and
  # the worker retries the item.
  @spec validate_and_hand_off(term(), term()) :: term()
  def validate_and_hand_off(state, item) do
    case validate_transport_delivery(state, item) do
      {:ok, :accepted} -> record_handoff(state, item)
      other -> {other, state}
    end
  end

  defp record_handoff(state, item) do
    case correlated_transport_context(state, item) do
      {:ok, decision, attempt, context} when is_map(attempt) ->
        if handoff_recorded?(attempt),
          do: {{:ok, :accepted}, state},
          else: persist_handoff(state, decision, context)

      {:ok, decision, :missing_attempt, context} ->
        persist_missing_attempt_handoff(state, decision, context)

      _other ->
        {{:ok, :accepted}, state}
    end
  end

  # A send after a recorded failure or restore is a new flight, so it gets a
  # fresh handoff mark.
  defp handoff_recorded?(attempt), do: Decision.attempt_in_flight?(attempt) or not is_nil(attempt.delivered_at)

  defp persist_handoff(state, decision, context) do
    data = %{action_id: context.action_id, attempt_id: context.attempt_id, queue_item_id: context.queue_item_id}

    case Persistence.build_and_persist_event(:handed_off, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, _updated} -> {{:ok, :accepted}, next_state}
      {:error, reason} -> {{:error, {:handoff_not_recorded, reason}}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp persist_missing_attempt_handoff(state, decision, context) do
    data = %{action_id: context.action_id, attempt_id: context.attempt_id, queue_item_id: context.queue_item_id}
    event_type = if Settlement.revision_action?(decision, context.action_id), do: :revision_dispatched, else: :dispatch_queued

    case Persistence.build_and_persist_event(event_type, decision, data, DateTime.utc_now(), state) do
      {:ok, %{writable?: true} = queued_state, queued_decision} -> persist_handoff(queued_state, queued_decision, context)
      {:ok, queued_state, _queued_decision} -> {{:error, {:store_unavailable, queued_state.health}}, queued_state}
      {:error, reason} -> {{:error, {:handoff_not_recorded, reason}}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp withdrawn_delivery(state, item) do
    case correlated_decision_context(state, item) do
      {:ok, %Decision{decision_status: :moot}, _context} -> {:withdrawn, :moot}
      {:ok, %Decision{active_action_id: active}, %{action_id: action_id}} when active != action_id -> {:withdrawn, :superseded}
      _other -> :not_withdrawn
    end
  end

  defp validate_correlated_delivery(state, item) do
    case correlated_transport_context(state, item) do
      {:ok, _decision, %{status: status}, _context}
      when status in [:queued, :restored, :delivered] ->
        {:ok, :accepted}

      {:ok, _decision, %{status: status}, _context} ->
        {:error, {:delivery_attempt_not_ready, status}}

      {:ok, _decision, :missing_attempt, _context} ->
        {:ok, :accepted}

      {:ok, :ignored} ->
        {:ok, :ignored}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp correlated_transport_context(state, item) do
    with {:ok, decision, context} <- correlated_decision_context(state, item),
         {:ok, attempt} <- resolve_dispatch_attempt(decision, context) do
      {:ok, decision, attempt, context}
    end
  end

  defp correlated_decision_context(state, item) do
    correlation = Map.get(item, :correlation)
    action_id = Map.get(item, :action_id)

    if is_map(correlation) and is_binary(action_id) do
      with {:ok, context} <- normalize_transport_context(item, correlation, action_id),
           {:ok, decision} <- Answers.fetch_decision(state, context.decision_id),
           :ok <- validate_transport_decision(decision, context) do
        {:ok, decision, context}
      end
    else
      {:ok, :ignored}
    end
  end

  defp resolve_dispatch_attempt(decision, context) do
    case fetch_dispatch_attempt(decision, context) do
      {:error, :attempt_not_found} -> resolve_missing_dispatch_attempt(decision, context.action_id)
      result -> result
    end
  end

  defp resolve_missing_dispatch_attempt(decision, action_id) do
    if Enum.any?(decision.dispatch_attempts, &(&1.action_id == action_id)),
      do: {:error, :attempt_not_found},
      else: {:ok, :missing_attempt}
  end

  defp normalize_transport_context(item, correlation, action_id) do
    context = %{
      decision_id: correlation_value(correlation, :decision_id),
      decision_version: correlation_value(correlation, :decision_version),
      action_id: correlation_value(correlation, :action_id),
      attempt_id: correlation_value(correlation, :attempt_id),
      queue_item_id: Map.get(item, :id),
      target: Map.get(item, :target_issue_identifier)
    }

    case validate_transport_context(context, action_id) do
      :ok -> {:ok, context}
      error -> error
    end
  end

  defp validate_transport_context(context, action_id) do
    cond do
      not is_binary(context.decision_id) -> {:error, :invalid_decision_correlation}
      not positive_integer?(context.decision_version) -> {:error, :invalid_decision_correlation}
      context.action_id != action_id -> {:error, :action_mismatch}
      not is_binary(context.attempt_id) -> {:error, :invalid_decision_correlation}
      not positive_integer?(context.queue_item_id) -> {:error, :invalid_decision_correlation}
      not is_binary(context.target) -> {:error, :invalid_decision_correlation}
      true -> :ok
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  @spec correlation_value(term(), term()) :: term()
  def correlation_value(correlation, key),
    do: Map.get(correlation, key, Map.get(correlation, Atom.to_string(key)))

  defp validate_transport_decision(decision, context) do
    answer = Decision.answer_for_action(decision, context.action_id)

    cond do
      decision.ticket.identifier != context.target -> {:error, :ticket_mismatch}
      is_nil(answer) -> {:error, :action_mismatch}
      answer.decision_version != context.decision_version -> {:error, :version_mismatch}
      true -> :ok
    end
  end

  defp fetch_dispatch_attempt(decision, context) do
    case Enum.find(decision.dispatch_attempts, &(&1.attempt_id == context.attempt_id)) do
      nil -> {:error, :attempt_not_found}
      %{queue_item_id: queue_item_id} = attempt when queue_item_id == context.queue_item_id -> {:ok, attempt}
      attempt -> if adoptable_attempt?(attempt), do: {:ok, :missing_attempt}, else: {:error, :queue_item_mismatch}
    end
  end

  # An attempt with no queue item on record is adoptable: an `:unknown`
  # (timed-out) attempt, or any dispatch-level failure, such as an older
  # build's `orchestrator_timeout`. An item that carries that attempt id proves
  # the Orchestrator queued it after the caller gave up or saw an error, so it
  # is adopted as that attempt, the same way as an item with no attempt record,
  # instead of being refused as a mismatch (#2717).
  @spec adoptable_attempt?(term()) :: term()
  def adoptable_attempt?(%{queue_item_id: nil, status: status}) when status in [:unknown, :failed], do: true
  def adoptable_attempt?(_attempt), do: false

  defp persist_missing_attempt_delivery(state, decision, context) do
    data = %{
      action_id: context.action_id,
      attempt_id: context.attempt_id,
      queue_item_id: context.queue_item_id
    }

    event_type = if Settlement.revision_action?(decision, context.action_id), do: :revision_dispatched, else: :dispatch_queued

    case Persistence.build_and_persist_event(event_type, decision, data, DateTime.utc_now(), state) do
      {:ok, %{writable?: true} = queued_state, queued_decision} ->
        {:ok, attempt} = fetch_dispatch_attempt(queued_decision, context)
        persist_transport_transition(queued_state, queued_decision, attempt, context, :delivered, nil)

      {:ok, queued_state, _queued_decision} ->
        {{:error, {:store_unavailable, queued_state.health}}, queued_state}

      {:error, reason} ->
        {{:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp persist_restored_attempt_delivery(state, decision, context) do
    data = %{
      action_id: context.action_id,
      attempt_id: context.attempt_id,
      queue_item_id: context.queue_item_id
    }

    case Persistence.build_and_persist_event(:restored, decision, data, DateTime.utc_now(), state) do
      {:ok, %{writable?: true} = restored_state, restored_decision} ->
        {:ok, restored_attempt} = fetch_dispatch_attempt(restored_decision, context)
        persist_transport_transition(restored_state, restored_decision, restored_attempt, context, :delivered, nil)

      {:ok, restored_state, _restored_decision} ->
        {{:error, {:store_unavailable, restored_state.health}}, restored_state}

      {:error, reason} ->
        {{:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp persist_transport_transition(state, decision, attempt, context, type, reason) do
    case append_transport_transition(state, decision, attempt, context, type, reason) do
      {:ok, :duplicate, next_state, nil} ->
        {{:ok, :duplicate}, next_state}

      {:ok, :accepted, next_state, {updated, event}} ->
        finalized = Persistence.repair_and_notify_lifecycle(next_state, [{updated, event}])
        finalized = FailureAttention.maybe_project_delivery_attention(finalized, decision, updated, type, context.action_id)
        FailureAttention.maybe_alert_withdrawn_delivery(updated, type, context.action_id)
        {{:ok, :accepted}, finalized}

      {:error, transition_reason} ->
        {{:error, transition_reason}, Persistence.journal_failure_state(state, transition_reason)}
    end
  end

  defp append_transport_transition(state, decision, attempt, context, type, reason) do
    reason_class = if type == :failed, do: transport_failure_class(reason)

    if duplicate_transport_transition?(attempt, type, reason_class) do
      {:ok, :duplicate, state, nil}
    else
      data = %{
        action_id: context.action_id,
        attempt_id: context.attempt_id,
        queue_item_id: context.queue_item_id,
        reason_class: reason_class
      }

      case Persistence.build_and_append_event(type, decision, data, DateTime.utc_now(), state) do
        {:ok, next_state, updated, event} ->
          {:ok, :accepted, next_state, {updated, event}}

        {:error, transition_reason} ->
          {:error, transition_reason}
      end
    end
  end

  @spec apply_transport_transitions(term(), term(), term(), term()) :: term()
  def apply_transport_transitions(state, type, items, reason) do
    items
    |> Enum.reduce({state, []}, &apply_transport_transition_item(&1, &2, type, reason))
    |> finalize_transport_transitions(type)
  end

  defp apply_transport_transition_item(item, {state, events}, type, reason) do
    case correlated_transport_context(state, item) do
      {:ok, decision, attempt, context} when is_map(attempt) ->
        append_transport_transition_item(state, events, decision, attempt, context, type, reason)

      {:ok, _decision, :missing_attempt, _context} ->
        Logger.warning("aiur_decision_store phase=transport_batch_missing_attempt type=#{type}")
        {state, events}

      {:ok, :ignored} ->
        {state, events}

      {:error, context_reason} ->
        Logger.warning("aiur_decision_store phase=transport_batch_rejected type=#{type} reason=#{inspect(context_reason)}")
        {state, events}
    end
  end

  defp append_transport_transition_item(state, events, decision, attempt, context, type, reason) do
    case append_transport_transition(state, decision, attempt, context, type, reason) do
      {:ok, :duplicate, duplicate_state, nil} ->
        {duplicate_state, events}

      {:ok, :accepted, appended_state, {updated, event}} ->
        {appended_state, [{decision, updated, event} | events]}

      {:error, append_reason} ->
        {AppendRecovery.recover_background_append(state, decision, context.action_id, type, append_reason), events}
    end
  end

  defp finalize_transport_transitions({next_state, lifecycle_events}, type) do
    ordered_events = Enum.reverse(lifecycle_events)

    finalized =
      case ordered_events do
        [] -> next_state
        events -> Persistence.repair_and_notify_lifecycle(next_state, lifecycle_event_pairs(events))
      end

    Enum.reduce(ordered_events, finalized, fn {prior, updated, event}, state_acc ->
      FailureAttention.maybe_project_delivery_attention(state_acc, prior, updated, type, event.data.action_id)
    end)
  end

  defp lifecycle_event_pairs(events) do
    Enum.map(events, fn {_prior, updated, event} -> {updated, event} end)
  end

  defp duplicate_transport_transition?(attempt, :delivered, _reason),
    do: attempt.status in [:delivered, :consumed, :failed] and not is_nil(attempt.delivered_at)

  defp duplicate_transport_transition?(attempt, :restored, _reason),
    do: attempt.status == :queued and not is_nil(attempt.restored_at)

  defp duplicate_transport_transition?(attempt, :consumed, _reason), do: attempt.status == :consumed

  defp duplicate_transport_transition?(attempt, :failed, reason),
    do: attempt.status == :failed and attempt.failure_reason_class == reason

  @spec transport_failure_class(term()) :: term()
  def transport_failure_class(:response_timeout), do: "response_timeout"
  def transport_failure_class(:turn_timeout), do: "turn_timeout"
  def transport_failure_class(:send_failed), do: "send_failed"
  def transport_failure_class({:turn_start_failed, _reason}), do: "turn_start_failed"
  def transport_failure_class({:turn_interrupted, _payload}), do: "turn_interrupted"
  def transport_failure_class({:turn_cancelled, _payload}), do: "turn_cancelled"
  def transport_failure_class(_reason), do: "turn_failed"
end
