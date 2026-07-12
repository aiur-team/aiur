defmodule Aiur.DecisionProjection do
  @moduledoc """
  Pure reducer over the canonical Decision audit stream.

  OCC-1 wrote complete request snapshots without an event discriminator.
  Those records continue to decode through the original request ingress
  validation. OCC-3 records use `Aiur.DecisionEvent`; replay validates the
  envelope hash and then this reducer validates each state transition in
  stream order. `reduce_checked/1` stops at the first invalid transition and
  returns the usable prefix plus its exact corrupt line.
  """

  alias Aiur.{Decision, DecisionAnswer, DecisionEvent, DecisionValidation}

  @type projection :: %{
          current: %{String.t() => Decision.t()},
          history: %{String.t() => [Decision.t()]},
          audit_history: %{String.t() => [Decision.t() | DecisionEvent.t()]}
        }

  @doc "Decode one legacy request record or one discriminated lifecycle event."
  @spec decode_record(map()) :: {:ok, Decision.t() | DecisionEvent.t()} | {:error, term()}
  def decode_record(raw) when is_map(raw) do
    if Map.has_key?(raw, "event_type") do
      DecisionEvent.from_json_safe(raw)
    else
      decode_request_record(raw)
    end
  end

  def decode_record(_other), do: {:error, :not_a_map}

  @doc "Decode an OCC-1 request snapshot through the canonical ingress validator."
  @spec decode_request_record(map()) :: {:ok, Decision.t()} | {:error, term()}
  def decode_request_record(raw) when is_map(raw) do
    with {:ok, ticket} <- fetch_map(raw, "ticket", :ticket),
         {:ok, source} <- fetch_map(raw, "source", :source),
         {:ok, version} <- fetch_pos_integer(raw, "version", :version),
         {:ok, persisted_decision_id} <- fetch_string(raw, "decision_id", :decision_id),
         {:ok, persisted_content_hash} <- fetch_string(raw, "content_hash", :content_hash),
         {:ok, created_at} <- fetch_timestamp(raw, "created_at", :created_at) do
      replay_payload = Map.put(raw, "created_at", Map.get(raw, "source_created_at"))

      case DecisionValidation.normalize(replay_payload, ticket: ticket, source: source, now: created_at) do
        {:ok, decision} -> verify_request_hash(decision, persisted_decision_id, version, persisted_content_hash)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def decode_request_record(_other), do: {:error, :not_a_map}

  defp verify_request_hash(decision, persisted_decision_id, version, persisted_content_hash) do
    if decision.content_hash == persisted_content_hash do
      {:ok, %{decision | decision_id: persisted_decision_id, version: version}}
    else
      {:error, :content_hash_mismatch}
    end
  end

  @doc "Reduce a valid stream. For repair-aware replay use `reduce_checked/1`."
  @spec reduce([Decision.t() | DecisionEvent.t()]) :: projection()
  def reduce(records) when is_list(records) do
    {projection, _corruption} = reduce_checked(records)
    projection
  end

  @doc "Reduce until the first invalid transition, returning the valid prefix and corrupt line."
  @spec reduce_checked([Decision.t() | DecisionEvent.t()]) ::
          {projection(), Aiur.DecisionLog.corruption() | nil}
  def reduce_checked(records) when is_list(records) do
    records
    |> Enum.with_index(1)
    |> Enum.reduce_while({empty_projection(), MapSet.new()}, fn {record, line}, {projection, seen_ids} ->
      with {:ok, seen_ids} <- reserve_event_identity(record, seen_ids),
           {:ok, projection} <- apply_record(projection, record) do
        {:cont, {projection, seen_ids}}
      else
        {:error, reason} -> {:halt, {{projection, seen_ids}, {:corrupt, line, {:invalid_transition, reason}}}}
      end
    end)
    |> finish_checked_reduce()
  end

  defp finish_checked_reduce({{projection, _seen_ids}, corruption}), do: {projection, corruption}
  defp finish_checked_reduce({projection, _seen_ids}), do: {projection, nil}

  defp empty_projection, do: %{current: %{}, history: %{}, audit_history: %{}}

  defp reserve_event_identity(%DecisionEvent{event_id: event_id}, seen_ids) do
    if MapSet.member?(seen_ids, event_id) do
      {:error, :duplicate_event_id}
    else
      {:ok, MapSet.put(seen_ids, event_id)}
    end
  end

  defp reserve_event_identity(%Decision{}, seen_ids), do: {:ok, seen_ids}
  defp reserve_event_identity(_other, _seen_ids), do: {:error, :unknown_record}

  defp apply_record(projection, %Decision{} = decision), do: apply_request(projection, decision, decision)

  defp apply_record(projection, %DecisionEvent{type: :requested, data: %Decision{} = decision} = event) do
    apply_request(projection, decision, event)
  end

  defp apply_record(projection, %DecisionEvent{} = event), do: apply_lifecycle(projection, event)
  defp apply_record(_projection, _record), do: {:error, :unknown_record}

  defp apply_request(projection, decision, audit_record) do
    existing = Map.get(projection.current, decision.decision_id)
    current = maybe_replace_current(existing, decision)

    {:ok,
     %{
       projection
       | current: Map.put(projection.current, decision.decision_id, current),
         history: append(projection.history, decision.decision_id, decision),
         audit_history: append(projection.audit_history, decision.decision_id, audit_record)
     }}
  end

  defp maybe_replace_current(nil, decision), do: decision

  defp maybe_replace_current(%Decision{version: existing_version} = existing, %Decision{version: version} = decision)
       when version >= existing_version do
    preserve_lifecycle(decision, existing)
  end

  defp maybe_replace_current(existing, _older), do: existing

  defp preserve_lifecycle(decision, existing) do
    %{
      decision
      | decision_status: existing.decision_status,
        delivery_status: existing.delivery_status,
        answer: existing.answer,
        dispatch_attempts: existing.dispatch_attempts,
        acknowledgement: existing.acknowledgement,
        resolution: existing.resolution
    }
  end

  defp apply_lifecycle(projection, %DecisionEvent{} = event) do
    with {:ok, current} <- fetch_current(projection, event.decision_id),
         {:ok, updated} <- transition(current, event) do
      {:ok,
       %{
         projection
         | current: Map.put(projection.current, event.decision_id, updated),
           audit_history: append(projection.audit_history, event.decision_id, event)
       }}
    end
  end

  defp fetch_current(projection, decision_id) do
    case Map.fetch(projection.current, decision_id) do
      {:ok, decision} -> {:ok, decision}
      :error -> {:error, :decision_not_found}
    end
  end

  defp transition(%Decision{} = decision, %DecisionEvent{type: :answer_recorded, data: answer} = event) do
    with :ok <- require_current_version(decision, event.decision_version),
         :ok <- require_answer_identity(decision, answer),
         :ok <- require_option(decision, answer),
         :ok <- require_unanswered(decision) do
      {:ok,
       %{
         decision
         | answer: answer,
           decision_status: :decided,
           delivery_status: :pending
       }}
    end
  end

  defp transition(%Decision{} = decision, %DecisionEvent{type: :dispatch_queued} = event) do
    with {:ok, answer} <- require_answer(decision),
         :ok <- require_answer_event(answer, event) do
      queue_dispatch_attempt(decision, event)
    end
  end

  defp transition(%Decision{} = decision, %DecisionEvent{type: type} = event)
       when type in [:delivered, :restored, :consumed, :failed] do
    with {:ok, answer} <- require_answer(decision),
         :ok <- require_answer_event(answer, event) do
      transition_transport(decision, event)
    end
  end

  defp transition(%Decision{} = decision, %DecisionEvent{type: :acknowledged} = event) do
    with {:ok, answer} <- require_answer(decision),
         :ok <- require_answer_event(answer, event),
         :ok <- require_absent(decision.acknowledgement, :already_acknowledged) do
      acknowledgement = lifecycle_fact(event)
      {:ok, %{decision | decision_status: :acknowledged, acknowledgement: acknowledgement}}
    end
  end

  defp transition(%Decision{} = decision, %DecisionEvent{type: :resolved} = event) do
    with {:ok, answer} <- require_answer(decision),
         :ok <- require_answer_event(answer, event),
         :ok <- require_present(decision.acknowledgement, :not_acknowledged),
         :ok <- require_absent(decision.resolution, :already_resolved) do
      resolution = lifecycle_fact(event)
      {:ok, %{decision | decision_status: :resolved, resolution: resolution}}
    end
  end

  defp transition(_decision, _event), do: {:error, :unsupported_event}

  defp require_current_version(%Decision{version: version}, version), do: :ok
  defp require_current_version(_decision, _version), do: {:error, :version_mismatch}

  defp require_answer_identity(decision, answer) do
    if answer.decision_id == decision.decision_id and answer.decision_version == decision.version do
      :ok
    else
      {:error, :answer_identity_mismatch}
    end
  end

  defp require_option(_decision, %DecisionAnswer{selected_option_id: nil}), do: :ok

  defp require_option(decision, %DecisionAnswer{selected_option_id: option_id}) do
    if Enum.any?(decision.options, &(&1.id == option_id)), do: :ok, else: {:error, :unknown_option}
  end

  defp require_unanswered(%Decision{answer: nil}), do: :ok
  defp require_unanswered(_decision), do: {:error, :already_answered}

  defp require_answer(%Decision{answer: %DecisionAnswer{} = answer}), do: {:ok, answer}
  defp require_answer(_decision), do: {:error, :answer_missing}

  defp require_answer_event(answer, event) do
    cond do
      event.data.action_id != answer.action_id -> {:error, :action_mismatch}
      event.decision_version != answer.decision_version -> {:error, :version_mismatch}
      true -> :ok
    end
  end

  defp require_new_attempt(decision, data) do
    duplicate_attempt? = Enum.any?(decision.dispatch_attempts, &(&1.attempt_id == data.attempt_id))

    duplicate_queue? =
      data.queue_item_id != nil and
        Enum.any?(decision.dispatch_attempts, &(&1.queue_item_id == data.queue_item_id))

    cond do
      duplicate_attempt? -> {:error, :duplicate_attempt}
      duplicate_queue? -> {:error, :duplicate_queue_item}
      true -> :ok
    end
  end

  defp queue_dispatch_attempt(decision, event) do
    case Enum.find(decision.dispatch_attempts, &(&1.attempt_id == event.data.attempt_id)) do
      %{status: :failed, queue_item_id: nil} = failed ->
        queued = %{
          failed
          | queue_item_id: event.data.queue_item_id,
            run_id: event.run_id,
            status: :queued,
            queued_at: event.occurred_at
        }

        attempts = Enum.map(decision.dispatch_attempts, &if(&1.attempt_id == failed.attempt_id, do: queued, else: &1))
        {:ok, %{decision | dispatch_attempts: attempts, delivery_status: :queued}}

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
        delivered_at: nil,
        restored_at: nil,
        consumed_at: nil,
        failed_at: nil,
        failure_reason_class: nil
      }

      {:ok, %{decision | dispatch_attempts: decision.dispatch_attempts ++ [attempt], delivery_status: :queued}}
    end
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

      {:ok, %{decision | dispatch_attempts: attempts, delivery_status: delivery_status(event.type)}}
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
        delivered_at: nil,
        restored_at: nil,
        consumed_at: nil,
        failed_at: event.occurred_at,
        failure_reason_class: event.data.reason_class
      }

      {:ok, %{decision | dispatch_attempts: decision.dispatch_attempts ++ [attempt], delivery_status: :failed}}
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

  defp lifecycle_fact(event) do
    %{
      action_id: event.data.action_id,
      actor: event.data.actor,
      source: event.data.source,
      detail: event.data.detail,
      occurred_at: event.occurred_at,
      event_id: event.event_id,
      run_id: event.run_id
    }
  end

  defp require_absent(nil, _reason), do: :ok
  defp require_absent(_value, reason), do: {:error, reason}
  defp require_present(nil, reason), do: {:error, reason}
  defp require_present(_value, _reason), do: :ok

  defp append(map, key, value), do: Map.update(map, key, [value], &(&1 ++ [value]))

  @doc "JSON-safe shape for one Decision in the current-state projection."
  @spec to_json_safe(Decision.t()) :: map()
  def to_json_safe(%Decision{} = decision) do
    %{
      "schema_version" => decision.schema_version,
      "decision_id" => decision.decision_id,
      "source_id" => decision.source_id,
      "version" => decision.version,
      "ticket" => stringify_keys(decision.ticket),
      "source" => stringify_keys(decision.source),
      "kind" => decision.kind,
      "authority" => Atom.to_string(decision.authority),
      "urgency" => Atom.to_string(decision.urgency),
      "blocking" => decision.blocking,
      "reversibility" => Atom.to_string(decision.reversibility),
      "question" => decision.question,
      "context" => stringify_keys(decision.context),
      "options" => Enum.map(decision.options, &stringify_keys/1),
      "recommendation" => decision.recommendation && stringify_keys(decision.recommendation),
      "consequence_of_delay" => decision.consequence_of_delay,
      "artifacts" => Enum.map(decision.artifacts, &stringify_artifact/1),
      "created_at" => DateTime.to_iso8601(decision.created_at),
      "source_created_at" => decision.source_created_at && DateTime.to_iso8601(decision.source_created_at),
      "content_hash" => decision.content_hash,
      "decision_status" => Atom.to_string(decision.decision_status),
      "delivery_status" => Atom.to_string(decision.delivery_status),
      "answer" => decision.answer && DecisionAnswer.to_json_safe(decision.answer),
      "dispatch_attempts" => Enum.map(decision.dispatch_attempts, &attempt_to_json_safe/1),
      "acknowledgement" => fact_to_json_safe(decision.acknowledgement),
      "resolution" => fact_to_json_safe(decision.resolution)
    }
  end

  @doc "JSON-safe shape for the `decisions.json` current-state projection."
  @spec serialize_current(%{String.t() => Decision.t()}) :: map()
  def serialize_current(current) when is_map(current) do
    %{
      "schema_version" => Decision.schema_version(),
      "decisions" => current |> Map.values() |> Enum.map(&to_json_safe/1)
    }
  end

  defp attempt_to_json_safe(attempt) do
    %{
      "action_id" => attempt.action_id,
      "attempt_id" => attempt.attempt_id,
      "queue_item_id" => attempt.queue_item_id,
      "run_id" => attempt.run_id,
      "status" => Atom.to_string(attempt.status),
      "attempted_at" => DateTime.to_iso8601(attempt.attempted_at),
      "queued_at" => timestamp(attempt.queued_at),
      "delivered_at" => timestamp(attempt.delivered_at),
      "restored_at" => timestamp(attempt.restored_at),
      "consumed_at" => timestamp(attempt.consumed_at),
      "failed_at" => timestamp(attempt.failed_at),
      "failure_reason_class" => attempt.failure_reason_class
    }
  end

  defp fact_to_json_safe(nil), do: nil

  defp fact_to_json_safe(fact) do
    %{
      "action_id" => fact.action_id,
      "actor" => %{"kind" => Atom.to_string(fact.actor.kind), "id" => fact.actor.id},
      "source" => stringify_keys(fact.source),
      "detail" => fact.detail,
      "occurred_at" => DateTime.to_iso8601(fact.occurred_at),
      "event_id" => fact.event_id,
      "run_id" => fact.run_id
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp stringify_artifact(%{kind: kind, value: value}), do: %{"kind" => Atom.to_string(kind), "value" => value}

  defp stringify_keys(nil), do: nil
  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp fetch_map(raw, key, field) do
    case Map.get(raw, key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  defp fetch_pos_integer(raw, key, field) do
    case Map.get(raw, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  defp fetch_string(raw, key, field) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  defp fetch_timestamp(raw, key, field) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          {:error, _reason} -> {:error, {field, :invalid_timestamp}}
        end

      _other ->
        {:error, {field, :missing_or_invalid}}
    end
  end
end
