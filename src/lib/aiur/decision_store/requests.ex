defmodule Aiur.DecisionStore.Requests do
  @moduledoc false

  require Logger

  alias Aiur.DecisionProjection.AuthorityReclassification
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.Audit
  alias Aiur.DecisionStore.Dedup
  alias Aiur.DecisionStore.Persistence
  alias Aiur.DecisionValidation
  alias Aiur.Events.IdGenerator
  alias Aiur.ExecutorCommandAttention
  alias Aiur.ExecutorEvents

  @spec handle_executor_escalation(term(), term(), term()) :: term()
  def handle_executor_escalation(decision_id, payload, state) do
    expected_version = Map.get(payload, :expected_version, Map.get(payload, "expected_version"))
    executor_id = present_executor_field(payload, :executor_id)
    reason = present_executor_field(payload, :reason)

    with true <- is_integer(expected_version) and expected_version > 0,
         executor_id when is_binary(executor_id) <- executor_id,
         reason when is_binary(reason) <- reason,
         {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         :ok <- validate_executor_escalation(decision, expected_version) do
      record_executor_escalation(state, decision, executor_id, reason)
    else
      false -> {:reply, {:error, :invalid_expected_version}, state}
      nil -> {:reply, {:error, :invalid_escalation}, state}
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  @spec handle_authority_reclassification(term(), term(), term()) :: term()
  def handle_authority_reclassification(decision_id, payload, state) do
    expected_version = Map.get(payload, :expected_version, Map.get(payload, "expected_version"))
    executor_id = present_executor_field(payload, :executor_id)
    rationale = present_executor_field(payload, :rationale)

    with true <- is_integer(expected_version) and expected_version > 0,
         executor_id when is_binary(executor_id) <- executor_id,
         rationale when is_binary(rationale) <- rationale,
         {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         :ok <- validate_reclassification(decision, expected_version),
         {:ok, next_state, updated} <- persist_reclassification(state, decision, executor_id, rationale) do
      {:reply, {:ok, %{status: :accepted, decision: updated}}, next_state}
    else
      false -> {:reply, {:error, :invalid_expected_version}, state}
      nil -> {:reply, {:error, :invalid_reclassification}, state}
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp validate_reclassification(decision, expected_version) do
    cond do
      decision.version != expected_version ->
        {:error, {:stale_version, expected_version, decision.version}}

      decision.authority != :human_required ->
        {:error, {:not_human_required, decision.authority}}

      not AuthorityReclassification.reclassifiable?(decision) ->
        {:error, :human_required_basis_cannot_be_reclassified}

      is_nil(decision.answer) and decision.decision_status in [:open, :deferred] ->
        :ok

      true ->
        {:error, {:not_open, decision.decision_status}}
    end
  end

  defp persist_reclassification(state, decision, executor_id, rationale) do
    data = %{
      actor: %{kind: :executor, id: executor_id},
      authority: :supervisor_allowed,
      detail: rationale,
      expected_version: decision.version
    }

    case Persistence.build_and_persist_event(:authority_reclassified, decision, data, DateTime.utc_now(), state) do
      {:ok, next_state, updated} -> {:ok, next_state, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  # "The Executor decided" and "the Executor deferred to the human" are both
  # decisions about the same Command, so both are appended to the same durable
  # event log before any alert is attempted. The alert marker can be cleaned
  # up, replaced, or lost; the DecisionEvent is what makes the escalation
  # auditable and attributable afterwards.
  defp record_executor_escalation(state, decision, executor_id, reason) do
    if executor_escalation_recorded?(state, decision) do
      open_and_reply(state, decision, executor_id, reason)
    else
      data = %{actor: %{kind: :executor, id: executor_id}, detail: reason}

      case Persistence.build_and_persist_event(:executor_escalated, decision, data, DateTime.utc_now(), state) do
        {:ok, next_state, updated} -> open_and_reply(next_state, updated, executor_id, reason)
        {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
      end
    end
  end

  # Re-escalating an already-recorded Command version is a no-op append: the
  # attention opener is separately idempotent and reports `:already_open`.
  defp executor_escalation_recorded?(state, decision) do
    state.audit_history
    |> Map.get(decision.decision_id, [])
    |> Enum.any?(&(&1.type == :executor_escalated and &1.decision_version == decision.version))
  end

  defp open_and_reply(state, decision, executor_id, reason) do
    case open_executor_attention(state, decision, executor_id, reason) do
      {:ok, status} -> {:reply, {:ok, %{status: status, decision: decision}}, state}
      {:error, failure} -> {:reply, {:error, failure}, state}
    end
  end

  defp validate_executor_escalation(decision, expected_version) do
    cond do
      decision.version != expected_version ->
        {:error, {:stale_version, expected_version, decision.version}}

      not is_nil(decision.answer) ->
        {:error, :already_answered}

      decision.decision_status not in [:open, :deferred] ->
        {:error, {:not_open, decision.decision_status}}

      true ->
        :ok
    end
  end

  defp open_executor_attention(state, decision, executor_id, reason) do
    state.executor_attention_opener.(decision, executor_id, reason)
  rescue
    error -> {:error, {:attention_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:attention_unavailable, reason}}
  end

  defp present_executor_field(payload, key) do
    case Map.get(payload, key, Map.get(payload, Atom.to_string(key))) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _value ->
        nil
    end
  end

  @spec handle_request(term(), term(), term()) :: term()
  def handle_request(payload, opts, state) do
    with {:ok, requested_version} <- fetch_requested_version(payload),
         {:ok, decision} <- DecisionValidation.normalize(payload, opts) do
      evaluate_and_apply(decision, requested_version, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  @spec fetch_requested_version(term(), term()) :: term()
  def fetch_requested_version(payload, default \\ 1) do
    case raw_version(payload) do
      nil -> {:ok, default}
      version when is_integer(version) and version > 0 -> {:ok, version}
      _other -> {:error, {:version, :invalid_type}}
    end
  end

  @spec raw_version(term()) :: term()
  def raw_version(payload), do: Map.get(payload, "version", Map.get(payload, :version))

  @spec evaluate_and_apply(term(), term(), term()) :: term()
  def evaluate_and_apply(decision, requested_version, state) do
    case evaluate(decision, requested_version, state) do
      {:duplicate, existing} ->
        {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}

      {:reject, reason} ->
        {:reply, {:error, {:conflict, reason}}, state}

      {:accept, decision} ->
        accept(decision, state)

      {:supersede_expired, decision, expired} ->
        accept_expired_reraise(decision, expired, state)
    end
  end

  # Persist and publish the replacement before retiring the old expired row.
  # If the replacement append fails, the existing answerable record stays
  # available for an Executor instead of being lost to a premature moot.
  defp accept_expired_reraise(decision, expired, state) do
    case accept(decision, state) do
      {:reply, {:ok, result}, accepted_state} ->
        case Dedup.moot_expired_reraise(accepted_state, expired, decision) do
          {:ok, next_state} -> {:reply, {:ok, result}, next_state}
          {:error, reason} -> {:reply, {:ok, result}, Persistence.journal_failure_state(accepted_state, reason)}
        end

      other ->
        other
    end
  end

  defp evaluate(decision, requested_version, state) do
    case Map.get(state.current, decision.decision_id) do
      nil -> evaluate_fresh(decision, requested_version, state)
      existing -> evaluate_against_existing(decision, requested_version, existing)
    end
  end

  # A fresh Command is still deduplicated at creation (#2099): the same agent
  # on the same ticket may file several phrasings of one question within a short
  # window, and each would otherwise land as its own row (different `source_id`
  # → different `decision_id`). If a live Command from the same agent on the
  # same ticket asks substantially the same question within the window, reject
  # the new one as a duplicate of the existing Command rather than appending it.
  defp evaluate_fresh(decision, 1, state) do
    case Dedup.find_creation_duplicate(decision, state) do
      nil ->
        decision = %{decision | version: 1}

        case Dedup.find_expired_reraise_duplicate(decision, state) do
          nil -> {:accept, decision}
          expired -> {:supersede_expired, decision, expired}
        end

      existing ->
        {:duplicate, existing}
    end
  end

  defp evaluate_fresh(_decision, requested_version, _state),
    do: {:reject, {:version_gap, requested_version, nil}}

  defp evaluate_against_existing(decision, requested_version, existing) do
    case identical_expired_retry(decision, requested_version, existing) do
      true -> {:accept, %{decision | version: existing.version + 1}}
      false -> evaluate_existing_version(decision, requested_version, existing)
    end
  end

  defp identical_expired_retry(decision, requested_version, existing) do
    expired_unanswered_blocking?(existing) and requested_version == existing.version and
      decision.content_hash == existing.content_hash
  end

  defp evaluate_existing_version(decision, requested_version, existing) do
    cond do
      requested_version == existing.version + 1 ->
        {:accept, %{decision | version: requested_version}}

      requested_version == existing.version and decision.content_hash == existing.content_hash ->
        {:duplicate, existing}

      requested_version == existing.version ->
        {:reject, {:idempotency_conflict, requested_version}}

      requested_version < existing.version ->
        {:reject, {:stale_version, requested_version, existing.version}}

      true ->
        {:reject, {:version_gap, requested_version, existing.version}}
    end
  end

  defp expired_unanswered_blocking?(decision) do
    decision.decision_status == :expired and decision.blocking and is_nil(decision.answer)
  end

  @spec accept(term(), term()) :: term()
  def accept(decision, state) do
    case IdGenerator.reserve_durable_id() do
      {:ok, event_id} -> Persistence.persist_and_notify(decision, event_id, state)
      {:error, :not_durable} -> {:reply, {:error, :event_id_not_durable}, state}
    end
  end

  @spec resolve_executor_escalation(term()) :: term()
  def resolve_executor_escalation(decision) do
    case ExecutorCommandAttention.resolve(decision) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("aiur_decision_store phase=executor_escalation_resolution_failed reason=#{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("aiur_decision_store phase=executor_escalation_resolution_failed error=#{Exception.message(error)}")
  end

  @spec reconcile_deferred_executor_notifications(term()) :: term()
  def reconcile_deferred_executor_notifications(state) do
    state.current
    |> Map.values()
    |> Enum.filter(&(&1.decision_status == :deferred))
    |> Enum.each(&notify_deferred_executor/1)
  end

  @spec reconcile_requested_executor_notifications(term()) :: term()
  def reconcile_requested_executor_notifications(state) do
    decisions =
      state.current
      |> Map.values()
      |> Enum.filter(&(&1.decision_status in [:open, :deferred]))

    reconcile_requested_executor_notifications(decisions, state)
  end

  defp reconcile_requested_executor_notifications(decisions, state) do
    case state.executor_request_boot_reconciler.(decisions) do
      {:ok, _published_count} ->
        :ok

      {:error, reason} ->
        Logger.warning("aiur_decision_store phase=executor_request_reconciliation_failed reason=#{inspect(reason)}")
        Enum.each(decisions, &Audit.schedule_executor_request_retry(&1, state, 0))
    end
  rescue
    error ->
      Logger.warning("aiur_decision_store phase=executor_request_reconciliation_failed error=#{Exception.message(error)}")
      Enum.each(decisions, &Audit.schedule_executor_request_retry(&1, state, 0))
  catch
    :exit, reason ->
      Logger.warning("aiur_decision_store phase=executor_request_reconciliation_failed exit=#{inspect(reason)}")
      Enum.each(decisions, &Audit.schedule_executor_request_retry(&1, state, 0))
  end

  @spec notify_deferred_executor(term()) :: term()
  def notify_deferred_executor(decision) do
    case ExecutorEvents.publish_deferred(decision) do
      {:ok, _id, _subscribers} -> :ok
      {:error, reason} -> Logger.warning("aiur_decision_store phase=executor_notification_failed reason=#{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("aiur_decision_store phase=executor_notification_failed error=#{Exception.message(error)}")
  end

  @spec lifecycle_slug(term()) :: term()
  def lifecycle_slug(:answer_recorded), do: "answered"
  def lifecycle_slug(:decision_expired), do: "expired"
  def lifecycle_slug(:decision_mooted), do: "mooted"
  def lifecycle_slug(:decision_dismissed), do: "dismissed"
  def lifecycle_slug(:decision_deferred), do: "deferred"
  def lifecycle_slug(:executor_escalated), do: "executor-escalated"
  def lifecycle_slug(:authority_reclassified), do: "authority-reclassified"
  def lifecycle_slug(:enriched), do: "enriched"
  def lifecycle_slug(:revision_recorded), do: "revision-recorded"
  def lifecycle_slug(:dispatch_queued), do: "queued"
  def lifecycle_slug(:dispatch_outcome_unknown), do: "dispatch-outcome-unknown"
  def lifecycle_slug(:revision_dispatched), do: "revision-dispatched"
  def lifecycle_slug(:revision_no_longer_applicable), do: "revision-no-longer-applicable"
  def lifecycle_slug(:follow_up_required), do: "revision-follow-up-required"
  def lifecycle_slug(:follow_up_handled), do: "revision-follow-up-handled"
  def lifecycle_slug(:handed_off), do: "handed-off"
  def lifecycle_slug(:delivered), do: "delivered"
  def lifecycle_slug(:restored), do: "restored"
  def lifecycle_slug(:consumed), do: "consumed"
  def lifecycle_slug(:failed), do: "failed"
  def lifecycle_slug(:acknowledged), do: "acknowledged"
  def lifecycle_slug(:resolved), do: "resolved"
end
