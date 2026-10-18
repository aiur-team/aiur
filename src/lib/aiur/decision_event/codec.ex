defmodule Aiur.DecisionEvent.Codec do
  @moduledoc false

  alias Aiur.{Decision, DecisionAnswer, DecisionProjection, DecisionRevision}
  alias Aiur.DecisionEvent.{AuthorityReclassification, Validation}
  @identity_max 256
  @reason_max 200
  @detail_max 2_000
  @transport_types [:dispatch_queued, :revision_dispatched, :handed_off, :delivered, :restored, :consumed, :failed, :dispatch_outcome_unknown]
  @actor_types [:acknowledged, :resolved]

  @spec normalize_data(term(), term(), term(), term(), term()) :: {:ok, term()} | {:error, term()}
  def normalize_data(:requested, %Decision{} = decision, decision_id, version, _trusted_provenance) do
    if decision.decision_id == decision_id and decision.version == version do
      {:ok, decision}
    else
      {:error, {:event_data, :request_identity_mismatch}}
    end
  end

  def normalize_data(:requested, raw, decision_id, version, trusted_provenance) when is_map(raw) do
    with {:ok, decision} <- DecisionProjection.decode_request_record(raw, trusted_provenance),
         true <- decision.decision_id == decision_id and decision.version == version do
      {:ok, decision}
    else
      false -> {:error, {:event_data, :request_identity_mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_data(:enriched, raw, decision_id, version, trusted_provenance) when is_map(raw) do
    with {:ok, decision} <-
           normalize_enrichment_decision(Validation.get(raw, :decision), decision_id, version, trusted_provenance),
         {:ok, actor} <- normalize_actor(Validation.get(raw, :actor)),
         :ok <- require_supervisor_actor(actor),
         {:ok, expected_version} <- Validation.map_required_pos_integer(raw, :expected_version),
         true <- expected_version + 1 == version do
      {:ok, %{decision: decision, actor: actor, expected_version: expected_version}}
    else
      false -> {:error, {:event_data, :enrichment_version_mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_data(:answer_recorded, %DecisionAnswer{} = answer, decision_id, version, _trusted_provenance) do
    if answer.decision_id == decision_id and answer.decision_version == version do
      {:ok, answer}
    else
      {:error, {:event_data, :answer_identity_mismatch}}
    end
  end

  def normalize_data(:decision_dismissed, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, actor} <- normalize_actor(Validation.get(raw, :actor)) do
      {:ok, %{actor: actor}}
    end
  end

  def normalize_data(:decision_deferred, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, actor} <- normalize_actor(Validation.get(raw, :actor)) do
      {:ok, %{actor: actor}}
    end
  end

  # Executor escalation records the Executor's reason and durable attribution.
  def normalize_data(:executor_escalated, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, actor} <- normalize_actor(Validation.get(raw, :actor)),
         :ok <- require_executor_actor(actor),
         {:ok, detail} <- Validation.bounded_required(Validation.get(raw, :detail), @detail_max, :detail) do
      {:ok, %{actor: actor, detail: detail}}
    end
  end

  def normalize_data(:authority_reclassified, raw, _decision_id, _version, _trusted_provenance), do: AuthorityReclassification.normalize(raw)

  def normalize_data(:decision_expired, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, reason_class} <- Validation.bounded_required(Validation.get(raw, :reason_class), @reason_max, :reason_class),
         {:ok, actor} <- normalize_actor(Validation.get(raw, :actor)),
         :ok <- require_system_actor(actor) do
      {:ok, %{reason_class: reason_class, actor: actor}}
    end
  end

  # Retiring a Command whose ticket closed or whose originating agent is gone.
  # Unlike an expiry (system-only, no prose) and unlike a dismissal (no reason,
  # refused for agent-filed blocking Commands), a moot records who retired it,
  # a bounded reason class, and optional free-text detail — and it deliberately
  # carries no answer, so the durable record can never be mistaken for a real
  # decision. Any actor may retire a Command; the attribution stays the actor's.
  def normalize_data(:decision_mooted, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, reason_class} <- Validation.bounded_required(Validation.get(raw, :reason_class), @reason_max, :reason_class),
         {:ok, detail} <- Validation.bounded_optional(Validation.get(raw, :detail), @detail_max, :detail),
         {:ok, actor} <- normalize_actor(Validation.get(raw, :actor)) do
      {:ok, %{reason_class: reason_class, detail: detail, actor: actor}}
    end
  end

  def normalize_data(:answer_recorded, raw, decision_id, version, _trusted_provenance) when is_map(raw) do
    with {:ok, answer} <- DecisionAnswer.from_json_safe(raw),
         true <- answer.decision_id == decision_id and answer.decision_version == version do
      {:ok, answer}
    else
      false -> {:error, {:event_data, :answer_identity_mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_data(:revision_recorded, %DecisionRevision{} = revision, decision_id, version, _trusted_provenance) do
    if revision.decision_id == decision_id and revision.decision_version == version do
      {:ok, revision}
    else
      {:error, {:event_data, :revision_identity_mismatch}}
    end
  end

  def normalize_data(:revision_recorded, raw, decision_id, version, _trusted_provenance) when is_map(raw) do
    with {:ok, revision} <- DecisionRevision.from_json_safe(raw, &DecisionAnswer.from_json_safe/1),
         true <- revision.decision_id == decision_id and revision.decision_version == version do
      {:ok, revision}
    else
      false -> {:error, {:event_data, :revision_identity_mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_data(:revision_no_longer_applicable, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, @identity_max),
         {:ok, reason_class} <- Validation.bounded_required(Validation.get(raw, :reason_class), @reason_max, :reason_class) do
      {:ok, %{action_id: action_id, reason_class: reason_class}}
    end
  end

  def normalize_data(:follow_up_required, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, @identity_max),
         {:ok, slug} <- Validation.map_required_string(raw, :slug, 64),
         :ok <- Validation.validate_attention_slug(slug),
         {:ok, question} <- Validation.bounded_required(Validation.get(raw, :question), @detail_max, :question) do
      {:ok, %{action_id: action_id, slug: slug, question: question}}
    end
  end

  def normalize_data(:follow_up_handled, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, @identity_max),
         {:ok, slug} <- Validation.map_required_string(raw, :slug, 64),
         :ok <- Validation.validate_attention_slug(slug),
         {:ok, actor} <- normalize_actor(Validation.get(raw, :actor)),
         {:ok, detail} <- Validation.bounded_optional(Validation.get(raw, :detail), @detail_max, :detail) do
      {:ok, %{action_id: action_id, slug: slug, actor: actor, detail: detail}}
    end
  end

  def normalize_data(type, raw, _decision_id, _version, _trusted_provenance) when type in @transport_types and is_map(raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, @identity_max),
         {:ok, attempt_id} <- Validation.map_required_string(raw, :attempt_id, @identity_max),
         {:ok, queue_item_id} <- Validation.map_optional_pos_integer(raw, :queue_item_id),
         {:ok, reason_class} <- normalize_reason(type, Validation.get(raw, :reason_class)) do
      {:ok,
       %{
         action_id: action_id,
         attempt_id: attempt_id,
         queue_item_id: queue_item_id,
         reason_class: reason_class
       }}
    end
  end

  def normalize_data(type, raw, _decision_id, _version, _trusted_provenance) when type in @actor_types and is_map(raw) do
    with {:ok, action_id} <- Validation.map_required_string(raw, :action_id, @identity_max),
         {:ok, actor} <- normalize_actor(Validation.get(raw, :actor)),
         {:ok, source} <- normalize_lifecycle_source(Validation.get(raw, :source)),
         {:ok, detail} <- Validation.bounded_optional(Validation.get(raw, :detail), @detail_max, :detail) do
      {:ok, %{action_id: action_id, actor: actor, source: source, detail: detail}}
    end
  end

  def normalize_data(_type, _data, _decision_id, _version, _trusted_provenance), do: {:error, {:event_data, :invalid}}

  defp normalize_enrichment_decision(%Decision{} = decision, decision_id, version, _trusted_provenance) do
    if decision.decision_id == decision_id and decision.version == version do
      {:ok, request_snapshot(decision)}
    else
      {:error, {:event_data, :enrichment_identity_mismatch}}
    end
  end

  defp normalize_enrichment_decision(raw, decision_id, version, trusted_provenance) when is_map(raw) do
    with {:ok, decision} <- DecisionProjection.decode_request_record(raw, trusted_provenance),
         true <- decision.decision_id == decision_id and decision.version == version do
      {:ok, request_snapshot(decision)}
    else
      false -> {:error, {:event_data, :enrichment_identity_mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_enrichment_decision(_raw, _decision_id, _version, _trusted_provenance),
    do: {:error, {:event_data, :enrichment_invalid}}

  defp request_snapshot(decision) do
    %{
      decision
      | decision_status: :open,
        delivery_status: :not_dispatched,
        answer: nil,
        active_action_id: nil,
        revision_sequence: 0,
        revisions: [],
        revision_result: nil,
        revision_outcomes: %{},
        revision_follow_ups: %{},
        dispatch_attempts: [],
        acknowledgement: nil,
        resolution: nil,
        acknowledgements: %{},
        resolutions: %{}
    }
  end

  defp normalize_reason(:failed, reason), do: Validation.bounded_required(reason, @reason_max, :reason_class)

  defp normalize_reason(:dispatch_outcome_unknown, reason),
    do: Validation.bounded_required(reason, @reason_max, :reason_class)

  defp normalize_reason(_type, nil), do: {:ok, nil}
  defp normalize_reason(_type, _reason), do: {:error, {:reason_class, :unexpected}}

  defp normalize_actor(actor) when is_map(actor) do
    kind = Validation.get(actor, :kind)

    with {:ok, kind} <- decode_actor_kind(kind),
         {:ok, id} <- Validation.bounded_optional(Validation.get(actor, :id), @identity_max, :actor_id) do
      {:ok, %{kind: kind, id: id}}
    end
  end

  defp normalize_actor(_other), do: {:error, {:actor, :invalid}}

  defp normalize_lifecycle_source(nil), do: normalize_lifecycle_source(%{})

  defp normalize_lifecycle_source(source) when is_map(source) do
    with {:ok, agent_id} <- Validation.bounded_optional(Validation.get(source, :agent_id), @identity_max, :source_agent_id),
         {:ok, session_id} <- Validation.bounded_optional(Validation.get(source, :session_id), @identity_max, :source_session_id),
         {:ok, invocation_id} <- Validation.bounded_optional(Validation.get(source, :invocation_id), @identity_max, :source_invocation_id) do
      {:ok, %{agent_id: agent_id, session_id: session_id, invocation_id: invocation_id}}
    end
  end

  defp normalize_lifecycle_source(_other), do: {:error, {:source, :invalid}}

  defp decode_actor_kind(kind) when kind in [:operator, :executor, :agent, :supervisor, :system], do: {:ok, kind}

  defp decode_actor_kind(kind) when is_binary(kind) do
    case kind do
      "operator" -> {:ok, :operator}
      "executor" -> {:ok, :executor}
      "agent" -> {:ok, :agent}
      "supervisor" -> {:ok, :supervisor}
      "system" -> {:ok, :system}
      _other -> {:error, {:actor_kind, :invalid}}
    end
  end

  defp decode_actor_kind(_other), do: {:error, {:actor_kind, :invalid}}

  defp require_system_actor(%{kind: :system}), do: :ok
  defp require_system_actor(_actor), do: {:error, {:actor_kind, :not_system}}

  defp require_executor_actor(%{kind: :executor}), do: :ok
  defp require_executor_actor(_actor), do: {:error, {:actor_kind, :not_executor}}

  defp require_supervisor_actor(%{kind: :supervisor}), do: :ok
  defp require_supervisor_actor(_actor), do: {:error, {:actor_kind, :not_supervisor}}

  @spec data_to_json_safe(term(), term()) :: map()
  def data_to_json_safe(:requested, %Decision{} = decision), do: DecisionProjection.to_json_safe(decision)

  def data_to_json_safe(:enriched, data) do
    %{
      "decision" => DecisionProjection.to_json_safe(data.decision),
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id},
      "expected_version" => data.expected_version
    }
  end

  def data_to_json_safe(:answer_recorded, %DecisionAnswer{} = answer), do: DecisionAnswer.to_json_safe(answer)

  def data_to_json_safe(:decision_dismissed, data) do
    %{"actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id}}
  end

  def data_to_json_safe(:decision_deferred, data) do
    %{"actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id}}
  end

  def data_to_json_safe(:executor_escalated, data) do
    %{
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id},
      "detail" => data.detail
    }
  end

  def data_to_json_safe(:authority_reclassified, data), do: AuthorityReclassification.to_json_safe(data)

  def data_to_json_safe(:decision_expired, data) do
    %{
      "reason_class" => data.reason_class,
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id}
    }
  end

  def data_to_json_safe(:decision_mooted, data) do
    base = %{
      "reason_class" => data.reason_class,
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id}
    }

    case data.detail do
      nil -> base
      detail -> Map.put(base, "detail", detail)
    end
  end

  def data_to_json_safe(:revision_recorded, %DecisionRevision{} = revision),
    do: DecisionRevision.to_json_safe(revision, &DecisionAnswer.to_json_safe/1)

  def data_to_json_safe(:revision_no_longer_applicable, data) do
    %{"action_id" => data.action_id, "reason_class" => data.reason_class}
  end

  def data_to_json_safe(:follow_up_required, data) do
    %{"action_id" => data.action_id, "slug" => data.slug, "question" => data.question}
  end

  def data_to_json_safe(:follow_up_handled, data) do
    %{
      "action_id" => data.action_id,
      "slug" => data.slug,
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id},
      "detail" => data.detail
    }
  end

  def data_to_json_safe(type, data) when type in @transport_types do
    %{
      "action_id" => data.action_id,
      "attempt_id" => data.attempt_id,
      "queue_item_id" => data.queue_item_id,
      "reason_class" => data.reason_class
    }
  end

  def data_to_json_safe(type, data) when type in @actor_types do
    %{
      "action_id" => data.action_id,
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id},
      "source" => %{
        "agent_id" => data.source.agent_id,
        "session_id" => data.source.session_id,
        "invocation_id" => data.source.invocation_id
      },
      "detail" => data.detail
    }
  end
end
