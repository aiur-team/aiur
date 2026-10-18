defmodule Aiur.DecisionProjection.DeliveryReducers do
  @moduledoc false

  alias Aiur.{Decision, DecisionEvent}
  alias Aiur.DecisionProjection.TransitionValidation

  @spec transition(term(), term()) :: {:ok, term()} | {:error, term()}
  def transition(%Decision{} = decision, %DecisionEvent{type: type} = event)
      when type in [:dispatch_queued, :revision_dispatched] do
    with {:ok, _answer} <- TransitionValidation.answer_for_event(decision, event),
         :ok <- TransitionValidation.require_revision_dispatch_kind(decision, event) do
      queue_dispatch_attempt(decision, event)
    end
  end

  # The delivery gate records that it handed an answer to a worker for sending.
  # It changes no status: it only marks the attempt so that a withdrawal can
  # no longer race the send (#2711).
  def transition(%Decision{} = decision, %DecisionEvent{type: :handed_off} = event) do
    with {:ok, _answer} <- TransitionValidation.answer_for_event(decision, event),
         {:ok, attempt} <- fetch_attempt(decision, event.data) do
      handed_off = Map.put(attempt, :handed_off_at, event.occurred_at)
      attempts = Enum.map(decision.dispatch_attempts, &if(&1.attempt_id == attempt.attempt_id, do: handed_off, else: &1))
      {:ok, %{decision | dispatch_attempts: attempts}}
    end
  end

  def transition(%Decision{} = decision, %DecisionEvent{type: type} = event)
      when type in [:delivered, :restored, :consumed, :failed] do
    with {:ok, _answer} <- TransitionValidation.answer_for_event(decision, event) do
      transition_transport(decision, event)
    end
  end

  # The caller of a dispatch timed out, so the queue item may or may not exist
  # (#2717). The attempt is recorded as `:unknown`, not failed. A later
  # `dispatch_queued` for the same attempt adopts the item that did arrive.
  def transition(%Decision{} = decision, %DecisionEvent{type: :dispatch_outcome_unknown} = event) do
    with {:ok, _answer} <- TransitionValidation.answer_for_event(decision, event),
         :ok <- require_new_attempt(decision, event.data) do
      attempt = %{
        action_id: event.data.action_id,
        attempt_id: event.data.attempt_id,
        queue_item_id: nil,
        run_id: event.run_id,
        status: :unknown,
        attempted_at: event.occurred_at,
        queued_at: nil,
        delivered_at: nil,
        restored_at: nil,
        consumed_at: nil,
        failed_at: nil,
        failure_reason_class: event.data.reason_class
      }

      updated = %{decision | dispatch_attempts: decision.dispatch_attempts ++ [attempt]}

      if decision.active_action_id == event.data.action_id,
        do: {:ok, %{updated | delivery_status: :pending}},
        else: {:ok, updated}
    end
  end

  defp require_new_attempt(decision, data) do
    # Queue item IDs are scoped to one Orchestrator lifetime and can restart
    # from the same integer. The durable attempt ID, not the queue-local ID,
    # is the cross-restart identity.
    duplicate_attempt? = Enum.any?(decision.dispatch_attempts, &(&1.attempt_id == data.attempt_id))

    if duplicate_attempt?, do: {:error, :duplicate_attempt}, else: :ok
  end

  defp queue_dispatch_attempt(decision, event) do
    case Enum.find(decision.dispatch_attempts, &(&1.attempt_id == event.data.attempt_id)) do
      %{status: status, queue_item_id: nil} = failed when status in [:failed, :unknown] ->
        queued = %{
          failed
          | queue_item_id: event.data.queue_item_id,
            run_id: event.run_id,
            status: :queued,
            queued_at: event.occurred_at
        }

        attempts = Enum.map(decision.dispatch_attempts, &if(&1.attempt_id == failed.attempt_id, do: queued, else: &1))
        {:ok, apply_dispatch_result(%{decision | dispatch_attempts: attempts}, event)}

      nil ->
        append_queued_dispatch_attempt(decision, event)

      _existing ->
        {:error, :duplicate_attempt}
    end
  end

  defp append_queued_dispatch_attempt(decision, event) do
    with :ok <- require_new_attempt(decision, event.data) do
      attempt = %{
        action_id: event.data.action_id,
        attempt_id: event.data.attempt_id,
        queue_item_id: event.data.queue_item_id,
        run_id: event.run_id,
        status: :queued,
        attempted_at: event.occurred_at,
        queued_at: event.occurred_at,
        handed_off_at: nil,
        delivered_at: nil,
        restored_at: nil,
        consumed_at: nil,
        failed_at: nil,
        failure_reason_class: nil
      }

      {:ok, apply_dispatch_result(%{decision | dispatch_attempts: decision.dispatch_attempts ++ [attempt]}, event)}
    end
  end

  defp apply_dispatch_result(decision, %DecisionEvent{type: :revision_dispatched} = event) do
    outcome = TransitionValidation.revision_outcome(:dispatched, nil, event)

    decision = %{decision | revision_outcomes: Map.put(decision.revision_outcomes, event.data.action_id, outcome)}

    if decision.active_action_id == event.data.action_id,
      do: %{decision | delivery_status: :queued, revision_result: :dispatched},
      else: decision
  end

  defp apply_dispatch_result(decision, event) do
    if decision.active_action_id == event.data.action_id,
      do: %{decision | delivery_status: :queued},
      else: decision
  end

  defp fetch_attempt(decision, data) do
    case Enum.find(decision.dispatch_attempts, &(&1.attempt_id == data.attempt_id)) do
      nil ->
        {:error, :attempt_not_found}

      attempt ->
        if data.queue_item_id in [nil, attempt.queue_item_id] do
          {:ok, attempt}
        else
          {:error, :queue_item_mismatch}
        end
    end
  end

  defp transition_transport(decision, %DecisionEvent{type: :failed} = event) do
    case fetch_attempt(decision, event.data) do
      {:ok, attempt} -> update_existing_transport_attempt(decision, attempt, event)
      {:error, :attempt_not_found} when is_nil(event.data.queue_item_id) -> append_failed_dispatch_attempt(decision, event)
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition_transport(decision, event) do
    with {:ok, attempt} <- fetch_attempt(decision, event.data) do
      update_existing_transport_attempt(decision, attempt, event)
    end
  end

  defp update_existing_transport_attempt(decision, attempt, event) do
    with :ok <- require_transport_transition(attempt.status, event.type) do
      updated_attempt = update_attempt(attempt, event)
      attempts = Enum.map(decision.dispatch_attempts, &if(&1.attempt_id == attempt.attempt_id, do: updated_attempt, else: &1))

      updated = %{decision | dispatch_attempts: attempts}

      if decision.active_action_id == event.data.action_id,
        do: {:ok, %{updated | delivery_status: delivery_status(event.type)}},
        else: {:ok, updated}
    end
  end

  defp append_failed_dispatch_attempt(decision, event) do
    with :ok <- require_new_attempt(decision, event.data) do
      attempt = %{
        action_id: event.data.action_id,
        attempt_id: event.data.attempt_id,
        queue_item_id: event.data.queue_item_id,
        run_id: event.run_id,
        status: :failed,
        attempted_at: event.occurred_at,
        queued_at: nil,
        handed_off_at: nil,
        delivered_at: nil,
        restored_at: nil,
        consumed_at: nil,
        failed_at: event.occurred_at,
        failure_reason_class: event.data.reason_class
      }

      updated = %{decision | dispatch_attempts: decision.dispatch_attempts ++ [attempt]}

      if decision.active_action_id == event.data.action_id,
        do: {:ok, %{updated | delivery_status: :failed}},
        else: {:ok, updated}
    end
  end

  defp require_transport_transition(status, :delivered) when status in [:queued, :restored], do: :ok
  defp require_transport_transition(:delivered, :restored), do: :ok
  defp require_transport_transition(:failed, :restored), do: :ok
  defp require_transport_transition(:delivered, :consumed), do: :ok
  defp require_transport_transition(status, :failed) when status in [:queued, :restored, :delivered], do: :ok
  defp require_transport_transition(_status, _type), do: {:error, :illegal_transport_transition}

  defp update_attempt(attempt, %DecisionEvent{type: :delivered, occurred_at: at}) do
    %{attempt | status: :delivered, delivered_at: at, failure_reason_class: nil}
  end

  defp update_attempt(attempt, %DecisionEvent{type: :restored, occurred_at: at}) do
    %{attempt | status: :queued, restored_at: at, failure_reason_class: nil}
  end

  defp update_attempt(attempt, %DecisionEvent{type: :consumed, occurred_at: at}) do
    %{attempt | status: :consumed, consumed_at: at, failure_reason_class: nil}
  end

  defp update_attempt(attempt, %DecisionEvent{type: :failed, occurred_at: at, data: data}) do
    %{attempt | status: :failed, failed_at: at, failure_reason_class: data.reason_class}
  end

  defp delivery_status(:delivered), do: :delivered
  defp delivery_status(:restored), do: :queued
  defp delivery_status(:consumed), do: :consumed
  defp delivery_status(:failed), do: :failed
end
