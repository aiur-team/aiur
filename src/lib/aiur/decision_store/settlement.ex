defmodule Aiur.DecisionStore.Settlement do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionRevision
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.AppendRecovery
  alias Aiur.DecisionStore.Audit
  alias Aiur.DecisionStore.Dispatch
  alias Aiur.DecisionStore.FailureAttention
  alias Aiur.DecisionStore.Persistence
  alias Aiur.DecisionStore.Retry
  alias Aiur.DecisionStore.Transport

  @spec settle_dispatch(term(), term(), term(), term(), term()) :: term()
  def settle_dispatch(state, decision_id, action_id, attempt_id, result) do
    with true <- state.writable? and state.health == :writable,
         {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         %DecisionAnswer{action_id: ^action_id} <- Decision.answer_for_action(decision, action_id) do
      case result do
        {:ok, %{status: status, item: %{id: queue_item_id} = item}}
        when status in [:accepted, :duplicate, :retried] and is_integer(queue_item_id) and queue_item_id > 0 ->
          settle_queue_result(state, decision, action_id, attempt_id, status, item)

        {:no_longer_applicable, reason} ->
          settle_revision_no_longer_applicable(state, decision, action_id, reason)

        {:error, reason} ->
          settle_dispatch_error(state, decision, action_id, attempt_id, reason)

        _other ->
          settle_dispatch_failure(state, decision, action_id, attempt_id, :invalid_dispatch_result)
      end
    else
      _other -> state
    end
  end

  defp settle_revision_no_longer_applicable(state, decision, action_id, reason) do
    if decision.active_action_id == action_id and revision_action?(decision, action_id) do
      data = %{action_id: action_id, reason_class: revision_non_applicability_reason(reason)}

      case Persistence.build_and_persist_event(:revision_no_longer_applicable, decision, data, DateTime.utc_now(), state) do
        {:ok, next_state, updated} ->
          ensure_revision_follow_up_required(next_state, updated)

        {:error, append_reason} ->
          AppendRecovery.recover_background_append(state, decision, action_id, :revision_no_longer_applicable, append_reason)
      end
    else
      state
    end
  end

  defp revision_non_applicability_reason(:missing), do: "target_missing"
  defp revision_non_applicability_reason({:terminal, _state}), do: "target_terminal"
  defp revision_non_applicability_reason(_reason), do: "target_no_longer_applicable"

  @spec ensure_revision_follow_up_required(term(), term()) :: term()
  def ensure_revision_follow_up_required(
        state,
        %Decision{revision_result: :no_longer_applicable, active_action_id: action_id} = decision
      ) do
    case Map.get(decision.revision_follow_ups, action_id) do
      nil -> persist_revision_follow_up_required(state, decision, action_id)
      _follow_up -> Dispatch.maybe_schedule_revision_follow_up_projection(state, decision, action_id)
    end
  end

  def ensure_revision_follow_up_required(state, _decision), do: state

  defp persist_revision_follow_up_required(state, decision, action_id) do
    revision = Enum.find(decision.revisions, &(&1.action_id == action_id))

    data = %{
      action_id: action_id,
      slug: DecisionRevision.follow_up_slug(revision),
      question: DecisionRevision.follow_up_question(revision, decision.ticket.identifier)
    }

    case Persistence.build_and_persist_event(:follow_up_required, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} -> Dispatch.maybe_schedule_revision_follow_up_projection(next_state, updated, action_id)
      {:error, reason} -> AppendRecovery.retry_follow_up_append(state, decision, :follow_up_required, data, reason)
    end
  end

  @spec ensure_superseded_revision_follow_ups(term(), term()) :: term()
  def ensure_superseded_revision_follow_ups(state, decision) do
    decision.revision_follow_ups
    |> Enum.filter(fn {action_id, follow_up} ->
      action_id != decision.active_action_id and is_nil(follow_up.handled_at)
    end)
    |> Enum.reduce(state, fn {action_id, follow_up}, state_acc ->
      current = Map.fetch!(state_acc.current, decision.decision_id)

      data = %{
        action_id: action_id,
        slug: follow_up.slug,
        actor: Audit.system_actor(),
        detail: "Superseded by revision #{decision.active_action_id}"
      }

      case Persistence.build_and_persist_event(:follow_up_handled, current, data, DateTime.utc_now(), state_acc) do
        {:ok, next_state, updated} -> Dispatch.maybe_schedule_revision_follow_up_resolution(next_state, updated, action_id)
        {:error, reason} -> AppendRecovery.retry_follow_up_append(state_acc, current, :follow_up_handled, data, reason)
      end
    end)
  end

  defp settle_queue_result(state, decision, action_id, attempt_id, :retried, item) do
    restored_attempt_id = item_attempt_id(item) || attempt_id

    case find_queue_attempt(decision, restored_attempt_id, item.id) do
      nil ->
        settle_retried_queue_item(state, decision, action_id, restored_attempt_id, item)

      attempt ->
        reconcile_existing_queue_snapshot(state, decision, attempt, item)
    end
  end

  defp settle_queue_result(state, decision, action_id, attempt_id, :duplicate, item) do
    accepted_attempt_id = item_attempt_id(item) || attempt_id

    case find_queue_attempt(decision, accepted_attempt_id, item.id) do
      nil -> settle_queue_acceptance(state, decision, action_id, accepted_attempt_id, item)
      attempt -> reconcile_existing_queue_snapshot(state, decision, attempt, item)
    end
  end

  defp settle_queue_result(state, decision, action_id, attempt_id, _status, item) do
    accepted_attempt_id = item_attempt_id(item) || attempt_id

    case find_queue_attempt(decision, accepted_attempt_id, item.id) do
      nil -> settle_queue_acceptance(state, decision, action_id, accepted_attempt_id, item)
      attempt -> reconcile_existing_queue_snapshot(state, decision, attempt, item)
    end
  end

  # A restored item whose attempt has no queue item on record is the late item
  # of a timed-out dispatch that was refused before this build (#2717). It is
  # adopted as that attempt, so a refused orphan never strands the answer.
  defp settle_retried_queue_item(state, decision, action_id, attempt_id, item) do
    adoptable? =
      Enum.any?(decision.dispatch_attempts, &(&1.attempt_id == attempt_id and Transport.adoptable_attempt?(&1)))

    if adoptable?,
      do: settle_queue_acceptance(state, decision, action_id, attempt_id, item),
      else: persist_restored_queue_item(state, decision, action_id, attempt_id, item)
  end

  defp persist_restored_queue_item(state, decision, action_id, restored_attempt_id, item) do
    data = %{
      action_id: action_id,
      attempt_id: restored_attempt_id,
      queue_item_id: item.id
    }

    case Persistence.build_and_persist_event(:restored, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state
        |> FailureAttention.maybe_project_delivery_attention(decision, updated, :restored, action_id)
        |> then(&%{&1 | retry_counts: Map.delete(&1.retry_counts, action_id)})

      {:error, reason} ->
        AppendRecovery.recover_background_append(state, decision, action_id, :restored, reason)
    end
  end

  defp item_attempt_id(item) do
    case Map.get(item, :correlation) do
      correlation when is_map(correlation) -> Transport.correlation_value(correlation, :attempt_id)
      _other -> nil
    end
  end

  defp find_queue_attempt(decision, attempt_id, queue_item_id) do
    Enum.find(decision.dispatch_attempts, fn attempt ->
      attempt.attempt_id == attempt_id and attempt.queue_item_id == queue_item_id
    end)
  end

  @spec revision_action?(term(), term()) :: term()
  def revision_action?(decision, action_id) do
    Enum.any?(decision.revisions, &(&1.action_id == action_id))
  end

  defp settle_queue_acceptance(state, decision, action_id, attempt_id, item) do
    data = %{action_id: action_id, attempt_id: attempt_id, queue_item_id: item.id}
    event_type = if revision_action?(decision, action_id), do: :revision_dispatched, else: :dispatch_queued

    case Persistence.build_and_persist_event(event_type, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state
        |> FailureAttention.maybe_project_delivery_attention(decision, updated, event_type, action_id)
        |> then(&%{&1 | retry_counts: Map.delete(&1.retry_counts, action_id)})
        |> reconcile_queue_snapshot(updated, item, data)

      {:error, reason} ->
        AppendRecovery.recover_background_append(state, decision, action_id, event_type, reason)
    end
  end

  defp reconcile_queue_snapshot(%{writable?: false} = state, _decision, _item, _data), do: state

  defp reconcile_queue_snapshot(state, decision, %{status: :delivered}, data) do
    persist_snapshot_transitions(state, decision, data, [:delivered])
  end

  defp reconcile_queue_snapshot(state, decision, %{status: :consumed}, data) do
    persist_snapshot_transitions(state, decision, data, [:delivered, :consumed])
  end

  defp reconcile_queue_snapshot(state, decision, %{status: :failed} = item, data) do
    reason_class = item |> Map.get(:failure_reason) |> Transport.transport_failure_class()
    persist_snapshot_transitions(state, decision, Map.put(data, :reason_class, reason_class), [:failed])
  end

  defp reconcile_queue_snapshot(state, _decision, _item, _data), do: state

  defp reconcile_existing_queue_snapshot(state, decision, attempt, item) do
    data = %{
      action_id: attempt.action_id,
      attempt_id: attempt.attempt_id,
      queue_item_id: attempt.queue_item_id
    }

    data =
      if Map.get(item, :status) == :failed do
        Map.put(data, :reason_class, Transport.transport_failure_class(Map.get(item, :failure_reason)))
      else
        data
      end

    types = missing_snapshot_transitions(attempt.status, Map.get(item, :status))
    persist_snapshot_transitions(state, decision, data, types)
  end

  defp missing_snapshot_transitions(status, :delivered) when status in [:queued, :restored], do: [:delivered]
  defp missing_snapshot_transitions(status, :consumed) when status in [:queued, :restored], do: [:delivered, :consumed]
  defp missing_snapshot_transitions(:delivered, :consumed), do: [:consumed]
  defp missing_snapshot_transitions(status, :failed) when status in [:queued, :restored, :delivered], do: [:failed]
  defp missing_snapshot_transitions(_current, _snapshot), do: []

  defp persist_snapshot_transitions(state, decision, data, types) do
    Enum.reduce_while(types, {state, decision}, fn type, {state_acc, decision_acc} ->
      event_data = if type == :failed, do: data, else: Map.delete(data, :reason_class)

      case Persistence.build_and_persist_event(type, decision_acc, event_data, DateTime.utc_now(), state_acc) do
        {:ok, next_state, updated} ->
          next_state = FailureAttention.maybe_project_delivery_attention(next_state, decision_acc, updated, type, data.action_id)
          {:cont, {next_state, updated}}

        {:error, reason} ->
          {:halt, {AppendRecovery.recover_background_append(state_acc, decision_acc, data.action_id, type, reason), decision_acc}}
      end
    end)
    |> elem(0)
  end

  # A timed-out dispatch may still have queued its item: the Orchestrator
  # handles the call after the caller gave up (#2717). The attempt is recorded
  # as an unknown outcome, never as a failure, and no failure alert is raised.
  # The bounded retry is kept: the retry is idempotent by action id, so it
  # either queues the item once or returns the late item, which the store then
  # adopts as this attempt. The delivery gate adopts it the same way.
  defp settle_dispatch_outcome_unknown(state, decision, action_id, attempt_id, reason) do
    data = %{action_id: action_id, attempt_id: attempt_id, queue_item_id: nil, reason_class: Retry.dispatch_failure_class(reason)}

    case Persistence.build_and_persist_event(:dispatch_outcome_unknown, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        Retry.maybe_retry_transient(next_state, updated, action_id, data.reason_class)

      {:error, append_reason} ->
        AppendRecovery.recover_background_append(state, decision, action_id, :dispatch_outcome_unknown, append_reason)
    end
  end

  defp settle_dispatch_error(state, decision, action_id, attempt_id, reason) do
    if dispatch_outcome_unknown?(reason),
      do: settle_dispatch_outcome_unknown(state, decision, action_id, attempt_id, reason),
      else: settle_dispatch_failure(state, decision, action_id, attempt_id, reason)
  end

  defp dispatch_outcome_unknown?({:outcome_unknown, _info}), do: true
  defp dispatch_outcome_unknown?(:timeout), do: true
  defp dispatch_outcome_unknown?(_reason), do: false

  @spec settle_dispatch_failure(term(), term(), term(), term(), term()) :: term()
  def settle_dispatch_failure(state, decision, action_id, attempt_id, reason) do
    reason_class = Retry.dispatch_failure_class(reason)
    data = %{action_id: action_id, attempt_id: attempt_id, queue_item_id: nil, reason_class: reason_class}

    case Persistence.build_and_persist_event(:failed, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} ->
        next_state
        |> FailureAttention.maybe_project_delivery_attention(decision, updated, :failed, action_id)
        |> Retry.maybe_retry_transient(updated, action_id, reason_class)

      {:error, append_reason} ->
        AppendRecovery.recover_background_append(state, decision, action_id, :failed, append_reason)
    end
  end
end
