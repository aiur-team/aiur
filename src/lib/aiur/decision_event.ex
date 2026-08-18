defmodule Aiur.DecisionEvent do
  @moduledoc """
  Validated discriminated envelope for append-only Decision lifecycle facts.

  OCC-1 request records predate this envelope and remain supported by
  `Aiur.DecisionProjection`. Every newly-written record uses this type,
  carries the daemon run and reserved event identities, and hashes the
  complete semantic envelope so replay fails closed on tampering.

  Newly written request and enrichment snapshots retain the schema-1 wire
  format so a rollback reader can replay them. Their reserved durable event
  ID is wrapped in a parsed provenance marker, which makes the binding
  requirement part of the existing schema-1 hash without changing the event
  bus cursor contract.
  """

  alias Aiur.{
    Decision,
    DecisionAnswer,
    DecisionProjection,
    DecisionProvenance,
    DecisionRevision,
    DecisionValidation,
    SecretRedactor
  }

  alias Aiur.DecisionEvent.Unrecognized

  @schema_version 1
  @versioned_snapshot_schema_version 2
  @provenance_event_id_prefix "decision-provenance-v1:"
  @identity_max 256
  @reason_max 200
  @detail_max 2_000
  @types [
    :requested,
    :enriched,
    :decision_expired,
    :decision_dismissed,
    :decision_deferred,
    :decision_mooted,
    :executor_escalated,
    :answer_recorded,
    :revision_recorded,
    :dispatch_queued,
    :revision_dispatched,
    :revision_no_longer_applicable,
    :follow_up_required,
    :follow_up_handled,
    :delivered,
    :restored,
    :consumed,
    :failed,
    :acknowledged,
    :resolved
  ]
  @transport_types [:dispatch_queued, :revision_dispatched, :delivered, :restored, :consumed, :failed]
  @actor_types [:acknowledged, :resolved]
  @snapshot_types [:requested, :enriched]

  @type type ::
          :requested
          | :enriched
          | :decision_expired
          | :decision_dismissed
          | :decision_deferred
          | :decision_mooted
          | :executor_escalated
          | :answer_recorded
          | :revision_recorded
          | :dispatch_queued
          | :revision_dispatched
          | :revision_no_longer_applicable
          | :follow_up_required
          | :follow_up_handled
          | :delivered
          | :restored
          | :consumed
          | :failed
          | :acknowledged
          | :resolved

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          type: type(),
          event_id: pos_integer() | String.t(),
          run_id: String.t(),
          decision_id: String.t(),
          decision_version: pos_integer(),
          occurred_at: DateTime.t(),
          data: Decision.t() | DecisionAnswer.t() | DecisionRevision.t() | map(),
          content_hash: String.t()
        }

  @enforce_keys [
    :type,
    :event_id,
    :run_id,
    :decision_id,
    :decision_version,
    :occurred_at,
    :data,
    :content_hash
  ]
  defstruct @enforce_keys ++ [schema_version: @schema_version]

  @doc "All lifecycle discriminators understood by this schema."
  @spec types() :: [type()]
  def types, do: @types

  @doc "Build and validate one trusted lifecycle event before append."
  @spec new(type(), String.t(), pos_integer(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(type, decision_id, decision_version, data, opts) when is_list(opts) do
    with {:ok, event_id} <- durable_snapshot_event_id(type, Keyword.fetch!(opts, :event_id)) do
      build(@schema_version, type, decision_id, decision_version, data, Keyword.put(opts, :event_id, event_id), nil)
    end
  end

  defp durable_snapshot_event_id(type, event_id) when type in @snapshot_types do
    if is_integer(event_id) and event_id > 0,
      do: {:ok, provenance_event_id(event_id)},
      else: {:error, {:event_id, :snapshot_marker_required}}
  end

  defp durable_snapshot_event_id(_type, event_id), do: {:ok, event_id}

  defp build(schema_version, type, decision_id, decision_version, data, opts, trusted_provenance) do
    event_id = Keyword.fetch!(opts, :event_id)
    run_id = Keyword.fetch!(opts, :run_id)
    occurred_at = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_type(type),
         {:ok, decision_id} <- bounded_required(decision_id, @identity_max, :decision_id),
         :ok <- validate_version(decision_version),
         :ok <- validate_event_id(event_id),
         {:ok, run_id} <- bounded_required(run_id, @identity_max, :run_id),
         :ok <- validate_timestamp(occurred_at),
         {:ok, data} <- normalize_data(type, data, decision_id, decision_version, trusted_provenance) do
      material =
        event_material(schema_version, type, event_id, run_id, decision_id, decision_version, occurred_at, data)

      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         type: type,
         event_id: event_id,
         run_id: run_id,
         decision_id: decision_id,
         decision_version: decision_version,
         occurred_at: occurred_at,
         data: data,
         content_hash: DecisionValidation.content_hash(material)
       }}
    end
  end

  @doc """
  Decode and fully validate one typed durable event.

  An `event_type` this binary does not know is version skew, not damage: it
  decodes to an opaque `Aiur.DecisionEvent.Unrecognized` that the projection
  retains and skips, so an older binary replaying a newer log stays writable
  instead of latching read-only. Every other decode failure — malformed JSON,
  a missing or ill-typed envelope field, an unsupported schema version for a
  type we *do* know, a content-hash mismatch — stays fail-closed.
  """
  @spec from_json_safe(map()) :: {:ok, t() | Unrecognized.t()} | {:error, term()}
  def from_json_safe(raw) when is_map(raw) do
    raw_type = Map.get(raw, "event_type")

    case decode_type(raw_type) do
      {:ok, type} ->
        decode_known_event(raw, type)

      # Only a genuinely named type is forward compatible. An empty name is not
      # a future event, it is a broken record, so it keeps failing closed.
      {:error, {:event_type, :unknown}} when is_binary(raw_type) and raw_type != "" ->
        Unrecognized.decode(raw, raw_type)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def from_json_safe(_other), do: {:error, :not_a_map}

  defp decode_known_event(raw, type) do
    with {:ok, schema_version} <- decode_schema_version(Map.get(raw, "schema_version")),
         :ok <- validate_schema_for_type(schema_version, type),
         {:ok, decision_id} <- fetch_string(raw, "decision_id", :decision_id),
         {:ok, decision_version} <- fetch_version(raw, "decision_version", :decision_version),
         {:ok, event_id} <- fetch_event_id(raw),
         {:ok, run_id} <- fetch_string(raw, "run_id", :run_id),
         {:ok, occurred_at} <- fetch_timestamp(raw, "occurred_at", :occurred_at),
         {:ok, data} <- fetch_map(raw, "data", :data),
         {:ok, persisted_hash} <- fetch_string(raw, "content_hash", :content_hash),
         {:ok, event} <-
           decode_typed_event(schema_version, type, decision_id, decision_version, data, event_id, run_id, occurred_at),
         :ok <- verify_hash(event.content_hash, persisted_hash) do
      {:ok, event}
    end
  end

  @doc "JSON-safe durable representation."
  @spec to_json_safe(t()) :: map()
  def to_json_safe(%__MODULE__{} = event) do
    %{
      "schema_version" => event.schema_version,
      "event_type" => Atom.to_string(event.type),
      "event_id" => event.event_id,
      "run_id" => event.run_id,
      "decision_id" => event.decision_id,
      "decision_version" => event.decision_version,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "data" => event_data_to_json_safe(event),
      "content_hash" => event.content_hash
    }
  end

  defp decode_typed_event(schema_version, type, decision_id, decision_version, data, event_id, run_id, occurred_at) do
    with {:ok, trusted_provenance} <-
           decode_typed_provenance(
             schema_version,
             type,
             data,
             event_id,
             run_id,
             decision_id,
             decision_version,
             occurred_at
           ) do
      build(
        schema_version,
        type,
        decision_id,
        decision_version,
        data,
        [event_id: event_id, run_id: run_id, now: occurred_at],
        trusted_provenance
      )
    end
  end

  defp normalize_data(:requested, %Decision{} = decision, decision_id, version, _trusted_provenance) do
    if decision.decision_id == decision_id and decision.version == version do
      {:ok, decision}
    else
      {:error, {:event_data, :request_identity_mismatch}}
    end
  end

  defp normalize_data(:requested, raw, decision_id, version, trusted_provenance) when is_map(raw) do
    with {:ok, decision} <- DecisionProjection.decode_request_record(raw, trusted_provenance),
         true <- decision.decision_id == decision_id and decision.version == version do
      {:ok, decision}
    else
      false -> {:error, {:event_data, :request_identity_mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_data(:enriched, raw, decision_id, version, trusted_provenance) when is_map(raw) do
    with {:ok, decision} <-
           normalize_enrichment_decision(get(raw, :decision), decision_id, version, trusted_provenance),
         {:ok, actor} <- normalize_actor(get(raw, :actor)),
         :ok <- require_supervisor_actor(actor),
         {:ok, expected_version} <- map_required_pos_integer(raw, :expected_version),
         true <- expected_version + 1 == version do
      {:ok, %{decision: decision, actor: actor, expected_version: expected_version}}
    else
      false -> {:error, {:event_data, :enrichment_version_mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_data(:answer_recorded, %DecisionAnswer{} = answer, decision_id, version, _trusted_provenance) do
    if answer.decision_id == decision_id and answer.decision_version == version do
      {:ok, answer}
    else
      {:error, {:event_data, :answer_identity_mismatch}}
    end
  end

  defp normalize_data(:decision_dismissed, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, actor} <- normalize_actor(get(raw, :actor)) do
      {:ok, %{actor: actor}}
    end
  end

  defp normalize_data(:decision_deferred, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, actor} <- normalize_actor(get(raw, :actor)) do
      {:ok, %{actor: actor}}
    end
  end

  # The Executor deferring a Command to the operator is a decision about that
  # Command exactly as an Executor answer is, so it earns the same durability
  # and attribution instead of living only in an alert marker file. `detail`
  # carries the Executor's stated reason for escalating.
  defp normalize_data(:executor_escalated, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, actor} <- normalize_actor(get(raw, :actor)),
         :ok <- require_executor_actor(actor),
         {:ok, detail} <- bounded_required(get(raw, :detail), @detail_max, :detail) do
      {:ok, %{actor: actor, detail: detail}}
    end
  end

  defp normalize_data(:decision_expired, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, reason_class} <- bounded_required(get(raw, :reason_class), @reason_max, :reason_class),
         {:ok, actor} <- normalize_actor(get(raw, :actor)),
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
  defp normalize_data(:decision_mooted, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, reason_class} <- bounded_required(get(raw, :reason_class), @reason_max, :reason_class),
         {:ok, detail} <- bounded_optional(get(raw, :detail), @detail_max, :detail),
         {:ok, actor} <- normalize_actor(get(raw, :actor)) do
      {:ok, %{reason_class: reason_class, detail: detail, actor: actor}}
    end
  end

  defp normalize_data(:answer_recorded, raw, decision_id, version, _trusted_provenance) when is_map(raw) do
    with {:ok, answer} <- DecisionAnswer.from_json_safe(raw),
         true <- answer.decision_id == decision_id and answer.decision_version == version do
      {:ok, answer}
    else
      false -> {:error, {:event_data, :answer_identity_mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_data(:revision_recorded, %DecisionRevision{} = revision, decision_id, version, _trusted_provenance) do
    if revision.decision_id == decision_id and revision.decision_version == version do
      {:ok, revision}
    else
      {:error, {:event_data, :revision_identity_mismatch}}
    end
  end

  defp normalize_data(:revision_recorded, raw, decision_id, version, _trusted_provenance) when is_map(raw) do
    with {:ok, revision} <- DecisionRevision.from_json_safe(raw, &DecisionAnswer.from_json_safe/1),
         true <- revision.decision_id == decision_id and revision.decision_version == version do
      {:ok, revision}
    else
      false -> {:error, {:event_data, :revision_identity_mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_data(:revision_no_longer_applicable, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, action_id} <- map_required_string(raw, :action_id, @identity_max),
         {:ok, reason_class} <- bounded_required(get(raw, :reason_class), @reason_max, :reason_class) do
      {:ok, %{action_id: action_id, reason_class: reason_class}}
    end
  end

  defp normalize_data(:follow_up_required, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, action_id} <- map_required_string(raw, :action_id, @identity_max),
         {:ok, slug} <- map_required_string(raw, :slug, 64),
         :ok <- validate_attention_slug(slug),
         {:ok, question} <- bounded_required(get(raw, :question), @detail_max, :question) do
      {:ok, %{action_id: action_id, slug: slug, question: question}}
    end
  end

  defp normalize_data(:follow_up_handled, raw, _decision_id, _version, _trusted_provenance) when is_map(raw) do
    with {:ok, action_id} <- map_required_string(raw, :action_id, @identity_max),
         {:ok, slug} <- map_required_string(raw, :slug, 64),
         :ok <- validate_attention_slug(slug),
         {:ok, actor} <- normalize_actor(get(raw, :actor)),
         {:ok, detail} <- bounded_optional(get(raw, :detail), @detail_max, :detail) do
      {:ok, %{action_id: action_id, slug: slug, actor: actor, detail: detail}}
    end
  end

  defp normalize_data(type, raw, _decision_id, _version, _trusted_provenance) when type in @transport_types and is_map(raw) do
    with {:ok, action_id} <- map_required_string(raw, :action_id, @identity_max),
         {:ok, attempt_id} <- map_required_string(raw, :attempt_id, @identity_max),
         {:ok, queue_item_id} <- map_optional_pos_integer(raw, :queue_item_id),
         {:ok, reason_class} <- normalize_reason(type, get(raw, :reason_class)) do
      {:ok,
       %{
         action_id: action_id,
         attempt_id: attempt_id,
         queue_item_id: queue_item_id,
         reason_class: reason_class
       }}
    end
  end

  defp normalize_data(type, raw, _decision_id, _version, _trusted_provenance) when type in @actor_types and is_map(raw) do
    with {:ok, action_id} <- map_required_string(raw, :action_id, @identity_max),
         {:ok, actor} <- normalize_actor(get(raw, :actor)),
         {:ok, source} <- normalize_lifecycle_source(get(raw, :source)),
         {:ok, detail} <- bounded_optional(get(raw, :detail), @detail_max, :detail) do
      {:ok, %{action_id: action_id, actor: actor, source: source, detail: detail}}
    end
  end

  defp normalize_data(_type, _data, _decision_id, _version, _trusted_provenance), do: {:error, {:event_data, :invalid}}

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

  defp normalize_reason(:failed, reason), do: bounded_required(reason, @reason_max, :reason_class)
  defp normalize_reason(_type, nil), do: {:ok, nil}
  defp normalize_reason(_type, _reason), do: {:error, {:reason_class, :unexpected}}

  defp normalize_actor(actor) when is_map(actor) do
    kind = get(actor, :kind)

    with {:ok, kind} <- decode_actor_kind(kind),
         {:ok, id} <- bounded_optional(get(actor, :id), @identity_max, :actor_id) do
      {:ok, %{kind: kind, id: id}}
    end
  end

  defp normalize_actor(_other), do: {:error, {:actor, :invalid}}

  defp normalize_lifecycle_source(nil), do: normalize_lifecycle_source(%{})

  defp normalize_lifecycle_source(source) when is_map(source) do
    with {:ok, agent_id} <- bounded_optional(get(source, :agent_id), @identity_max, :source_agent_id),
         {:ok, session_id} <- bounded_optional(get(source, :session_id), @identity_max, :source_session_id),
         {:ok, invocation_id} <- bounded_optional(get(source, :invocation_id), @identity_max, :source_invocation_id) do
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

  defp event_material(schema_version, type, event_id, run_id, decision_id, decision_version, occurred_at, data) do
    %{
      schema_version: schema_version,
      event_type: type,
      event_id: event_id,
      run_id: run_id,
      decision_id: decision_id,
      decision_version: decision_version,
      occurred_at: DateTime.to_iso8601(occurred_at),
      data: event_hash_data(schema_version, type, data)
    }
  end

  # Schema-1 event hashes deliberately retain the current-main material. The
  # separately bound provenance state does not alter what a rollback reader
  # reconstructs from the Decision snapshot.
  defp legacy_data_to_json_safe(:requested, %Decision{} = decision) do
    data_to_json_safe(:requested, decision)
    |> Map.delete("provenance")
  end

  defp legacy_data_to_json_safe(:enriched, data) do
    encoded = data_to_json_safe(:enriched, data)

    encoded
    |> Map.delete("provenance_hash")
    |> Map.put("decision", Map.delete(encoded["decision"], "provenance"))
  end

  defp legacy_data_to_json_safe(type, data), do: data_to_json_safe(type, data)

  defp event_hash_data(@schema_version, type, data), do: legacy_data_to_json_safe(type, data)

  defp event_hash_data(@versioned_snapshot_schema_version, type, data),
    do: data_to_json_safe(type, data) |> maybe_put_provenance_state(type, data)

  defp event_data_to_json_safe(%__MODULE__{schema_version: @schema_version} = event) do
    data_to_json_safe(event.type, event.data)
    |> maybe_put_provenance_binding(event.type, event.data, event)
  end

  defp event_data_to_json_safe(%__MODULE__{schema_version: @versioned_snapshot_schema_version} = event),
    do: data_to_json_safe(event.type, event.data) |> maybe_put_provenance_state(event.type, event.data)

  defp data_to_json_safe(:requested, %Decision{} = decision), do: DecisionProjection.to_json_safe(decision)

  defp data_to_json_safe(:enriched, data) do
    %{
      "decision" => DecisionProjection.to_json_safe(data.decision),
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id},
      "expected_version" => data.expected_version
    }
  end

  defp data_to_json_safe(:answer_recorded, %DecisionAnswer{} = answer), do: DecisionAnswer.to_json_safe(answer)

  defp data_to_json_safe(:decision_dismissed, data) do
    %{"actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id}}
  end

  defp data_to_json_safe(:decision_deferred, data) do
    %{"actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id}}
  end

  defp data_to_json_safe(:executor_escalated, data) do
    %{
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id},
      "detail" => data.detail
    }
  end

  defp data_to_json_safe(:decision_expired, data) do
    %{
      "reason_class" => data.reason_class,
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id}
    }
  end

  defp data_to_json_safe(:decision_mooted, data) do
    base = %{
      "reason_class" => data.reason_class,
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id}
    }

    case data.detail do
      nil -> base
      detail -> Map.put(base, "detail", detail)
    end
  end

  defp data_to_json_safe(:revision_recorded, %DecisionRevision{} = revision),
    do: DecisionRevision.to_json_safe(revision, &DecisionAnswer.to_json_safe/1)

  defp data_to_json_safe(:revision_no_longer_applicable, data) do
    %{"action_id" => data.action_id, "reason_class" => data.reason_class}
  end

  defp data_to_json_safe(:follow_up_required, data) do
    %{"action_id" => data.action_id, "slug" => data.slug, "question" => data.question}
  end

  defp data_to_json_safe(:follow_up_handled, data) do
    %{
      "action_id" => data.action_id,
      "slug" => data.slug,
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id},
      "detail" => data.detail
    }
  end

  defp data_to_json_safe(type, data) when type in @transport_types do
    %{
      "action_id" => data.action_id,
      "attempt_id" => data.attempt_id,
      "queue_item_id" => data.queue_item_id,
      "reason_class" => data.reason_class
    }
  end

  defp data_to_json_safe(type, data) when type in @actor_types do
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

  defp maybe_put_provenance_binding(data, type, event_data, %__MODULE__{} = event)
       when type in [:requested, :enriched] do
    state = if provenance_for(type, event_data), do: "captured", else: "unknown"

    data
    |> Map.put("provenance_state", state)
    |> Map.put(
      "provenance_hash",
      DecisionValidation.content_hash(provenance_material(type, event, provenance_for(type, event_data), state))
    )
  end

  defp maybe_put_provenance_binding(data, _type, _event_data, _event), do: data

  defp provenance_for(:requested, %Decision{} = decision), do: decision.provenance
  defp provenance_for(:enriched, %{decision: %Decision{} = decision}), do: decision.provenance
  defp provenance_for(_type, _data), do: nil

  defp maybe_put_provenance_state(data, type, event_data) when type in [:requested, :enriched] do
    state = if provenance_for(type, event_data), do: "captured", else: "unknown"
    Map.put(data, "provenance_state", state)
  end

  defp maybe_put_provenance_state(data, _type, _event_data), do: data

  defp maybe_put_provenance_state(data, nil), do: data
  defp maybe_put_provenance_state(data, state), do: Map.put(data, :provenance_state, state)

  defp provenance_material(type, event, provenance, state) do
    %{
      schema_version: @schema_version,
      event_type: type,
      event_id: event.event_id,
      run_id: event.run_id,
      decision_id: event.decision_id,
      decision_version: event.decision_version,
      occurred_at: DateTime.to_iso8601(event.occurred_at),
      provenance: provenance && DecisionProvenance.to_json_safe(provenance)
    }
    |> maybe_put_provenance_state(state)
  end

  defp decode_typed_provenance(
         @schema_version,
         :requested,
         data,
         event_id,
         run_id,
         decision_id,
         decision_version,
         occurred_at
       ) do
    decode_snapshot_provenance(data, :requested, event_id, run_id, decision_id, decision_version, occurred_at)
  end

  defp decode_typed_provenance(
         @schema_version,
         :enriched,
         data,
         event_id,
         run_id,
         decision_id,
         decision_version,
         occurred_at
       ) do
    with {:ok, decision} <- fetch_map(data, "decision", :decision) do
      decision
      |> Map.put("provenance_state", get(data, :provenance_state))
      |> Map.put("provenance_hash", get(data, :provenance_hash))
      |> decode_snapshot_provenance(:enriched, event_id, run_id, decision_id, decision_version, occurred_at)
    end
  end

  defp decode_typed_provenance(
         @versioned_snapshot_schema_version,
         :requested,
         data,
         _event_id,
         _run_id,
         _decision_id,
         _decision_version,
         _occurred_at
       ) do
    decode_versioned_snapshot_provenance(data)
  end

  defp decode_typed_provenance(
         @versioned_snapshot_schema_version,
         :enriched,
         data,
         _event_id,
         _run_id,
         _decision_id,
         _decision_version,
         _occurred_at
       ) do
    with {:ok, decision} <- fetch_map(data, "decision", :decision) do
      decode_versioned_snapshot_provenance(
        decision
        |> Map.put("provenance_state", get(data, :provenance_state))
        |> Map.put("provenance_hash", get(data, :provenance_hash))
      )
    end
  end

  defp decode_typed_provenance(
         _schema_version,
         _type,
         data,
         _event_id,
         _run_id,
         _decision_id,
         _decision_version,
         _occurred_at
       ) do
    if is_nil(get(data, :provenance)) and is_nil(get(data, :provenance_hash)),
      do: {:ok, nil},
      else: {:error, :unexpected_provenance}
  end

  defp decode_versioned_snapshot_provenance(raw) do
    case {get(raw, :provenance_state), get(raw, :provenance), get(raw, :provenance_hash)} do
      {nil, _provenance, _hash} ->
        {:error, :provenance_state_missing}

      {"unknown", nil, nil} ->
        {:ok, nil}

      {"captured", nil, nil} ->
        {:error, :provenance_missing}

      {"captured", provenance, nil} when is_map(provenance) ->
        DecisionProvenance.from_json_safe(provenance)

      {state, _provenance, _hash} when state in ["captured", "unknown"] ->
        {:error, :invalid_provenance_state}

      _other ->
        {:error, :invalid_provenance_state}
    end
  end

  defp decode_snapshot_provenance(raw, type, event_id, run_id, decision_id, decision_version, occurred_at) do
    context = %{
      type: type,
      event_id: event_id,
      run_id: run_id,
      decision_id: decision_id,
      decision_version: decision_version,
      occurred_at: occurred_at
    }

    case snapshot_event_id_status(context.event_id) do
      :marked ->
        decode_marked_snapshot_provenance(raw, context)

      :malformed_marker ->
        {:error, :invalid_provenance_event_id}

      :legacy ->
        decode_legacy_or_bound_snapshot_provenance(raw, context)
    end
  end

  defp decode_marked_snapshot_provenance(raw, context) do
    case {get(raw, :provenance_state), get(raw, :provenance), get(raw, :provenance_hash)} do
      {"captured", provenance, hash} ->
        decode_bound_snapshot_provenance(provenance, hash, "captured", context)

      {"unknown", nil, hash} ->
        decode_bound_snapshot_provenance(nil, hash, "unknown", context)

      {nil, nil, nil} ->
        {:error, :provenance_binding_missing}

      {nil, nil, _hash} ->
        {:error, :provenance_state_missing}

      {_state, _provenance, _hash} ->
        {:error, :invalid_provenance_binding}
    end
  end

  defp decode_legacy_or_bound_snapshot_provenance(raw, context) do
    case {get(raw, :provenance_state), get(raw, :provenance), get(raw, :provenance_hash)} do
      {nil, nil, nil} ->
        {:ok, nil}

      {nil, nil, _hash} ->
        {:error, :provenance_state_missing}

      {nil, provenance, hash} ->
        decode_legacy_snapshot_provenance(provenance, hash, context)

      {"captured", provenance, hash} ->
        decode_bound_snapshot_provenance(provenance, hash, "captured", context)

      {"unknown", nil, hash} ->
        decode_bound_snapshot_provenance(nil, hash, "unknown", context)

      {_state, _provenance, _hash} ->
        {:error, :invalid_provenance_binding}
    end
  end

  defp decode_legacy_snapshot_provenance(nil, _hash, _context),
    do: {:error, :provenance_hash_without_provenance}

  defp decode_legacy_snapshot_provenance(_provenance, nil, _context),
    do: {:error, :provenance_hash_missing}

  defp decode_legacy_snapshot_provenance(provenance, hash, context)
       when is_map(provenance) and is_binary(hash) and hash != "" do
    with {:ok, provenance} <- DecisionProvenance.from_json_safe(provenance),
         :ok <- verify_provenance_hash(context, provenance, nil, hash) do
      {:ok, provenance}
    end
  end

  defp decode_legacy_snapshot_provenance(_provenance, _hash, _context),
    do: {:error, :invalid_provenance_binding}

  defp decode_bound_snapshot_provenance(nil, _hash, "captured", _context),
    do: {:error, :provenance_missing}

  defp decode_bound_snapshot_provenance(provenance, hash, state, context)
       when state == "captured" and is_map(provenance) and is_binary(hash) and hash != "" do
    with {:ok, provenance} <- DecisionProvenance.from_json_safe(provenance),
         :ok <- verify_provenance_hash(context, provenance, state, hash) do
      {:ok, provenance}
    end
  end

  defp decode_bound_snapshot_provenance(nil, hash, "unknown", context)
       when is_binary(hash) and hash != "" do
    with :ok <- verify_provenance_hash(context, nil, "unknown", hash) do
      {:ok, nil}
    end
  end

  defp decode_bound_snapshot_provenance(_provenance, _hash, _state, _context),
    do: {:error, :invalid_provenance_binding}

  defp verify_provenance_hash(context, provenance, state, persisted_hash) do
    actual_hash =
      DecisionValidation.content_hash(
        %{
          schema_version: @schema_version,
          event_type: context.type,
          event_id: context.event_id,
          run_id: context.run_id,
          decision_id: context.decision_id,
          decision_version: context.decision_version,
          occurred_at: DateTime.to_iso8601(context.occurred_at),
          provenance: provenance && DecisionProvenance.to_json_safe(provenance)
        }
        |> maybe_put_provenance_state(state)
      )

    if actual_hash == persisted_hash, do: :ok, else: {:error, :provenance_hash_mismatch}
  end

  defp provenance_event_id(reserved_id), do: @provenance_event_id_prefix <> Integer.to_string(reserved_id)

  defp snapshot_event_id_status(event_id) when is_binary(event_id) do
    cond do
      match?({:ok, _reserved_id}, parse_provenance_event_id(event_id)) -> :marked
      String.starts_with?(event_id, @provenance_event_id_prefix) -> :malformed_marker
      true -> :legacy
    end
  end

  defp snapshot_event_id_status(_event_id), do: :legacy

  defp parse_provenance_event_id(@provenance_event_id_prefix <> reserved_id) do
    case Integer.parse(reserved_id) do
      {value, ""} when value > 0 ->
        if reserved_id == Integer.to_string(value), do: {:ok, value}, else: :error

      _other ->
        :error
    end
  end

  defp parse_provenance_event_id(_event_id), do: :error

  defp validate_type(type) when type in @types, do: :ok
  defp validate_type(_other), do: {:error, {:event_type, :unknown}}

  defp validate_attention_slug(slug) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,63}\z/, slug),
      do: :ok,
      else: {:error, {:slug, :invalid_format}}
  end

  defp decode_schema_version(version) when version in [@schema_version, @versioned_snapshot_schema_version], do: {:ok, version}
  defp decode_schema_version(_other), do: {:error, {:schema_version, :unsupported}}

  defp validate_schema_for_type(@versioned_snapshot_schema_version, type) when type not in [:requested, :enriched],
    do: {:error, {:schema_version, :unsupported}}

  defp validate_schema_for_type(_schema_version, _type), do: :ok

  defp decode_type(type) when is_binary(type) do
    case Enum.find(@types, &(Atom.to_string(&1) == type)) do
      nil -> {:error, {:event_type, :unknown}}
      known -> {:ok, known}
    end
  end

  defp decode_type(_other), do: {:error, {:event_type, :missing_or_invalid}}

  defp validate_version(version) when is_integer(version) and version > 0, do: :ok
  defp validate_version(_other), do: {:error, {:decision_version, :invalid}}

  defp validate_event_id(value) when is_integer(value) and value > 0, do: :ok
  defp validate_event_id(value) when is_binary(value) and value != "", do: :ok
  defp validate_event_id(_other), do: {:error, {:event_id, :invalid}}

  defp validate_timestamp(%DateTime{}), do: :ok
  defp validate_timestamp(_other), do: {:error, {:occurred_at, :invalid}}

  defp bounded_required(value, max, field) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, {field, :missing}}
      String.length(trimmed) > max -> {:error, {field, :too_long}}
      unsafe_control_chars?(trimmed) -> {:error, {field, :unsafe_characters}}
      true -> {:ok, SecretRedactor.redact(trimmed)}
    end
  end

  defp bounded_required(nil, _max, field), do: {:error, {field, :missing}}
  defp bounded_required(_value, _max, field), do: {:error, {field, :invalid_type}}

  defp bounded_optional(nil, _max, _field), do: {:ok, nil}
  defp bounded_optional("", _max, _field), do: {:ok, nil}
  defp bounded_optional(value, max, field), do: bounded_required(value, max, field)

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 and codepoint not in [?\n, ?\t, ?\r] end)
  end

  defp map_required_string(raw, key, max), do: bounded_required(get(raw, key), max, key)

  defp map_optional_pos_integer(raw, key) do
    case get(raw, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {key, :invalid}}
    end
  end

  defp map_required_pos_integer(raw, key) do
    case get(raw, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {key, :invalid}}
    end
  end

  defp fetch_string(raw, key, field) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  defp fetch_version(raw, key, field) do
    case Map.get(raw, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  defp fetch_event_id(raw) do
    case Map.get(raw, "event_id") do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:event_id, :missing_or_invalid}}
    end
  end

  defp fetch_map(raw, key, field) do
    case Map.get(raw, key) do
      value when is_map(value) -> {:ok, value}
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

  defp verify_hash(hash, hash), do: :ok
  defp verify_hash(_actual, _persisted), do: {:error, :event_content_hash_mismatch}

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
