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

  alias Aiur.{Decision, DecisionAnswer, DecisionEvent, DecisionProvenance, DecisionRevision, DecisionValidation}
  alias Aiur.DecisionEvent.Unrecognized
  alias Aiur.DecisionProjection.Reducers

  @type projection :: %{
          current: %{String.t() => Decision.t()},
          history: %{String.t() => [Decision.t()]},
          audit_history: %{String.t() => [Decision.t() | DecisionEvent.t()]}
        }

  @doc """
  Decode one legacy request record or one discriminated lifecycle event.

  A lifecycle event whose type this binary does not know decodes to an opaque
  `Aiur.DecisionEvent.Unrecognized`, which is retained in the replayed record
  list and skipped when folding the projection.
  """
  @spec decode_record(map()) :: {:ok, Decision.t() | DecisionEvent.t() | Unrecognized.t()} | {:error, term()}
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
  def decode_request_record(raw) when is_map(raw), do: decode_request_record(raw, nil)
  def decode_request_record(_other), do: {:error, :not_a_map}

  @doc false
  @spec decode_request_record(map(), DecisionProvenance.t() | nil) :: {:ok, Decision.t()} | {:error, term()}
  def decode_request_record(raw, trusted_provenance) when is_map(raw) do
    with {:ok, ticket} <- fetch_map(raw, "ticket", :ticket),
         {:ok, source} <- fetch_map(raw, "source", :source),
         {:ok, version} <- fetch_pos_integer(raw, "version", :version),
         {:ok, persisted_decision_id} <- fetch_string(raw, "decision_id", :decision_id),
         {:ok, persisted_content_hash} <- fetch_string(raw, "content_hash", :content_hash),
         {:ok, created_at} <- fetch_timestamp(raw, "created_at", :created_at),
         {:ok, provenance} <- trusted_provenance(trusted_provenance) do
      replay_payload =
        raw
        |> Map.delete("provenance")
        |> Map.delete(:provenance)
        |> Map.delete("provenance_hash")
        |> Map.delete(:provenance_hash)
        |> Map.delete("provenance_state")
        |> Map.delete(:provenance_state)
        |> Map.put("created_at", Map.get(raw, "source_created_at"))

      case DecisionValidation.normalize(replay_payload,
             ticket: ticket,
             source: source,
             now: created_at,
             legacy_attention: Map.get(raw, "legacy_attention"),
             provenance: provenance,
             legacy_replay: true
           ) do
        {:ok, decision} -> verify_request_hash(decision, persisted_decision_id, version, persisted_content_hash)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def decode_request_record(_other, _trusted_provenance), do: {:error, :not_a_map}

  defp trusted_provenance(nil), do: {:ok, nil}
  defp trusted_provenance(%DecisionProvenance{} = provenance), do: {:ok, provenance}
  defp trusted_provenance(_other), do: {:error, :untrusted_provenance}

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
          {projection(), Aiur.Journal.corruption() | nil}
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

  # An unrecognized event still occupies its event id, so replaying one twice
  # is duplication exactly as it is for a known event.
  defp reserve_event_identity(%Unrecognized{event_id: event_id}, seen_ids) do
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

  defp apply_record(projection, %DecisionEvent{type: :enriched} = event) do
    apply_enrichment(projection, event)
  end

  defp apply_record(projection, %DecisionEvent{} = event), do: apply_lifecycle(projection, event)

  # Retained, not projected. This binary cannot know what the event means, so
  # the one safe fold is the identity: leave every Decision exactly as the
  # events it *does* understand left it. The record stays in the replayed list
  # and on disk for a binary that knows the type.
  defp apply_record(projection, %Unrecognized{}), do: {:ok, projection}

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
    # A dismissed Command is closed on the operator's judgement, not on the
    # underlying condition. When the source re-files it with changed
    # evidence or a changed question, that judgement was made against content
    # that no longer exists, so re-arm it. This holds for every kind: gating
    # on `legacy_attention` left an agent-filed Command unable to return once
    # dismissed, with nothing re-checking whether it was still blocking.
    rearmed? =
      existing.decision_status == :dismissed and
        decision.content_hash != existing.content_hash

    %{
      decision
      | decision_status: if(rearmed?, do: :open, else: existing.decision_status),
        delivery_status: if(rearmed?, do: :not_dispatched, else: existing.delivery_status),
        answer: existing.answer,
        active_action_id: existing.active_action_id,
        revision_sequence: existing.revision_sequence,
        revisions: existing.revisions,
        revision_result: existing.revision_result,
        revision_outcomes: existing.revision_outcomes,
        revision_follow_ups: existing.revision_follow_ups,
        dispatch_attempts: existing.dispatch_attempts,
        acknowledgement: existing.acknowledgement,
        resolution: existing.resolution,
        acknowledgements: existing.acknowledgements,
        resolutions: existing.resolutions
    }
  end

  defp apply_enrichment(projection, %DecisionEvent{data: data} = event) do
    with {:ok, current} <- fetch_current(projection, event.decision_id),
         :ok <- require_enrichment_version(current, event),
         :ok <- require_enrichment_base(current, data.decision) do
      apply_request(projection, data.decision, event)
    end
  end

  defp require_enrichment_version(current, event) do
    if event.data.expected_version == current.version and event.decision_version == current.version + 1 do
      :ok
    else
      {:error, :enrichment_version_mismatch}
    end
  end

  defp require_enrichment_base(current, candidate) do
    immutable_fields = [
      :schema_version,
      :decision_id,
      :source_id,
      :ticket,
      :source,
      :kind,
      :authority,
      :urgency,
      :blocking,
      :reversibility,
      :question,
      :created_at,
      :source_created_at,
      :legacy_attention,
      :provenance
    ]

    if Map.take(current, immutable_fields) == Map.take(candidate, immutable_fields) do
      :ok
    else
      {:error, :enrichment_forbidden_change}
    end
  end

  defp apply_lifecycle(projection, %DecisionEvent{} = event) do
    with {:ok, current} <- fetch_current(projection, event.decision_id),
         {:ok, updated} <- Reducers.transition(current, event) do
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
      "active_action_id" => decision.active_action_id,
      "revision_sequence" => decision.revision_sequence,
      "revisions" => Enum.map(decision.revisions, &DecisionRevision.to_json_safe(&1, fn answer -> DecisionAnswer.to_json_safe(answer) end)),
      "revision_result" => decision.revision_result && Atom.to_string(decision.revision_result),
      "revision_outcomes" => stringify_action_map(decision.revision_outcomes, &revision_outcome_to_json_safe/1),
      "revision_follow_ups" => stringify_action_map(decision.revision_follow_ups, &follow_up_to_json_safe/1),
      "dispatch_attempts" => Enum.map(decision.dispatch_attempts, &attempt_to_json_safe/1),
      "acknowledgement" => fact_to_json_safe(decision.acknowledgement),
      "resolution" => fact_to_json_safe(decision.resolution),
      "acknowledgements" => stringify_action_map(decision.acknowledgements, &fact_to_json_safe/1),
      "resolutions" => stringify_action_map(decision.resolutions, &fact_to_json_safe/1)
    }
    |> maybe_put_legacy_attention(decision.legacy_attention)
    |> maybe_put_provenance(decision.provenance)
  end

  @doc "Normalized request-shaped content for adapter-owned enrichment merges."
  @spec to_request_payload(Decision.t()) :: map()
  def to_request_payload(%Decision{} = decision) do
    persisted = to_json_safe(decision)

    persisted
    |> Map.take([
      "source_id",
      "kind",
      "authority",
      "urgency",
      "blocking",
      "reversibility",
      "question",
      "context",
      "options",
      "recommendation",
      "consequence_of_delay",
      "artifacts"
    ])
    |> maybe_put_source_created_at(decision.source_created_at)
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
      "handed_off_at" => timestamp(Map.get(attempt, :handed_off_at)),
      "delivered_at" => timestamp(attempt.delivered_at),
      "restored_at" => timestamp(attempt.restored_at),
      "consumed_at" => timestamp(attempt.consumed_at),
      "failed_at" => timestamp(attempt.failed_at),
      "failure_reason_class" => attempt.failure_reason_class
    }
  end

  defp revision_outcome_to_json_safe(outcome) do
    %{
      "result" => Atom.to_string(outcome.result),
      "reason_class" => outcome.reason_class,
      "occurred_at" => DateTime.to_iso8601(outcome.occurred_at),
      "event_id" => outcome.event_id,
      "run_id" => outcome.run_id
    }
  end

  defp follow_up_to_json_safe(follow_up) do
    %{
      "action_id" => follow_up.action_id,
      "slug" => follow_up.slug,
      "question" => follow_up.question,
      "required_at" => DateTime.to_iso8601(follow_up.required_at),
      "required_event_id" => follow_up.required_event_id,
      "handled_at" => timestamp(follow_up.handled_at),
      "handled_event_id" => follow_up.handled_event_id,
      "handled_by" => actor_to_json_safe(follow_up.handled_by),
      "handled_detail" => follow_up.handled_detail
    }
  end

  defp stringify_action_map(map, mapper) do
    Map.new(map, fn {action_id, value} -> {action_id, mapper.(value)} end)
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

  defp actor_to_json_safe(nil), do: nil
  defp actor_to_json_safe(actor), do: %{"kind" => Atom.to_string(actor.kind), "id" => actor.id}

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp stringify_artifact(%{kind: kind, value: value}), do: %{"kind" => Atom.to_string(kind), "value" => value}

  defp maybe_put_legacy_attention(map, nil), do: map

  defp maybe_put_legacy_attention(map, legacy_attention) do
    Map.put(map, "legacy_attention", stringify_keys(legacy_attention))
  end

  defp maybe_put_provenance(map, nil), do: map

  defp maybe_put_provenance(map, provenance) do
    Map.put(map, "provenance", DecisionProvenance.to_json_safe(provenance))
  end

  defp maybe_put_source_created_at(payload, nil), do: payload

  defp maybe_put_source_created_at(payload, source_created_at) do
    Map.put(payload, "created_at", DateTime.to_iso8601(source_created_at))
  end

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
