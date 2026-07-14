defmodule Aiur.DecisionEvent do
  @moduledoc """
  Validated discriminated envelope for append-only Decision lifecycle facts.

  OCC-1 request records predate this envelope and remain supported by
  `Aiur.DecisionProjection`. Every newly-written record uses this type,
  carries the daemon run and reserved event identities, and hashes the
  complete semantic envelope so replay fails closed on tampering.
  """

  alias Aiur.{Decision, DecisionAnswer, DecisionProjection, DecisionProvenance, DecisionRevision, DecisionValidation, SecretRedactor}

  @schema_version 1
  @identity_max 256
  @reason_max 200
  @detail_max 2_000
  @types [
    :requested,
    :enriched,
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

  @type type ::
          :requested
          | :enriched
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
    build(type, decision_id, decision_version, data, opts, nil)
  end

  defp build(type, decision_id, decision_version, data, opts, trusted_provenance) do
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
      material = event_material(type, event_id, run_id, decision_id, decision_version, occurred_at, data)

      {:ok,
       %__MODULE__{
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

  @doc "Decode and fully validate one typed durable event."
  @spec from_json_safe(map()) :: {:ok, t()} | {:error, term()}
  def from_json_safe(raw) when is_map(raw) do
    with :ok <- validate_schema_version(Map.get(raw, "schema_version")),
         {:ok, type} <- decode_type(Map.get(raw, "event_type")),
         {:ok, decision_id} <- fetch_string(raw, "decision_id", :decision_id),
         {:ok, decision_version} <- fetch_version(raw, "decision_version", :decision_version),
         {:ok, event_id} <- fetch_event_id(raw),
         {:ok, run_id} <- fetch_string(raw, "run_id", :run_id),
         {:ok, occurred_at} <- fetch_timestamp(raw, "occurred_at", :occurred_at),
         {:ok, data} <- fetch_map(raw, "data", :data),
         {:ok, persisted_hash} <- fetch_string(raw, "content_hash", :content_hash),
         {:ok, event} <-
           decode_typed_event(type, decision_id, decision_version, data, event_id, run_id, occurred_at),
         :ok <- verify_hash(event.content_hash, persisted_hash) do
      {:ok, event}
    end
  end

  def from_json_safe(_other), do: {:error, :not_a_map}

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
      "data" => data_to_json_safe(event.type, event.data, event),
      "content_hash" => event.content_hash
    }
  end

  defp decode_typed_event(type, decision_id, decision_version, data, event_id, run_id, occurred_at) do
    with {:ok, trusted_provenance} <-
           decode_typed_provenance(type, data, event_id, run_id, decision_id, decision_version, occurred_at) do
      build(
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
    with {:ok, decision} <- normalize_enrichment_decision(get(raw, :decision), decision_id, version, trusted_provenance),
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

  defp decode_actor_kind(kind) when kind in [:operator, :agent, :supervisor, :system], do: {:ok, kind}

  defp decode_actor_kind(kind) when is_binary(kind) do
    case kind do
      "operator" -> {:ok, :operator}
      "agent" -> {:ok, :agent}
      "supervisor" -> {:ok, :supervisor}
      "system" -> {:ok, :system}
      _other -> {:error, {:actor_kind, :invalid}}
    end
  end

  defp decode_actor_kind(_other), do: {:error, {:actor_kind, :invalid}}

  defp require_supervisor_actor(%{kind: :supervisor}), do: :ok
  defp require_supervisor_actor(_actor), do: {:error, {:actor_kind, :not_supervisor}}

  defp event_material(type, event_id, run_id, decision_id, decision_version, occurred_at, data) do
    %{
      schema_version: @schema_version,
      event_type: type,
      event_id: event_id,
      run_id: run_id,
      decision_id: decision_id,
      decision_version: decision_version,
      occurred_at: DateTime.to_iso8601(occurred_at),
      data: legacy_data_to_json_safe(type, data)
    }
  end

  # Schema-1 event hashes deliberately retain the old reader's material. The
  # optional provenance is bound separately so a previous binary can still
  # replay the event after dropping fields it does not understand.
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

  defp data_to_json_safe(type, data, event) do
    data_to_json_safe(type, data)
    |> maybe_put_provenance_hash(type, data, event)
  end

  defp data_to_json_safe(:requested, %Decision{} = decision), do: DecisionProjection.to_json_safe(decision)

  defp data_to_json_safe(:enriched, data) do
    %{
      "decision" => DecisionProjection.to_json_safe(data.decision),
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id},
      "expected_version" => data.expected_version
    }
  end

  defp data_to_json_safe(:answer_recorded, %DecisionAnswer{} = answer), do: DecisionAnswer.to_json_safe(answer)

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

  defp maybe_put_provenance_hash(data, _type, _event_data, %__MODULE__{data: %Decision{provenance: nil}}), do: data

  defp maybe_put_provenance_hash(data, type, event_data, %__MODULE__{} = event) do
    case provenance_for(type, event_data) do
      nil ->
        data

      %DecisionProvenance{} = provenance ->
        Map.put(
          data,
          "provenance_hash",
          DecisionValidation.content_hash(provenance_material(type, event, provenance))
        )
    end
  end

  defp provenance_for(:requested, %Decision{} = decision), do: decision.provenance
  defp provenance_for(:enriched, %{decision: %Decision{} = decision}), do: decision.provenance
  defp provenance_for(_type, _data), do: nil

  defp provenance_material(type, event, provenance) do
    %{
      schema_version: @schema_version,
      event_type: type,
      event_id: event.event_id,
      run_id: event.run_id,
      decision_id: event.decision_id,
      decision_version: event.decision_version,
      occurred_at: DateTime.to_iso8601(event.occurred_at),
      provenance: DecisionProvenance.to_json_safe(provenance)
    }
  end

  defp decode_typed_provenance(:requested, data, event_id, run_id, decision_id, decision_version, occurred_at) do
    decode_snapshot_provenance(data, :requested, event_id, run_id, decision_id, decision_version, occurred_at)
  end

  defp decode_typed_provenance(:enriched, data, event_id, run_id, decision_id, decision_version, occurred_at) do
    with {:ok, decision} <- fetch_map(data, "decision", :decision) do
      decision
      |> Map.put("provenance_hash", get(data, :provenance_hash))
      |> decode_snapshot_provenance(:enriched, event_id, run_id, decision_id, decision_version, occurred_at)
    end
  end

  defp decode_typed_provenance(_type, data, _event_id, _run_id, _decision_id, _decision_version, _occurred_at) do
    if is_nil(get(data, :provenance)) and is_nil(get(data, :provenance_hash)),
      do: {:ok, nil},
      else: {:error, :unexpected_provenance}
  end

  defp decode_snapshot_provenance(raw, type, event_id, run_id, decision_id, decision_version, occurred_at) do
    case {get(raw, :provenance), get(raw, :provenance_hash)} do
      {nil, nil} ->
        {:ok, nil}

      {nil, _hash} ->
        {:error, :provenance_hash_without_provenance}

      {_provenance, nil} ->
        {:error, :provenance_hash_missing}

      {provenance, hash} when is_map(provenance) and is_binary(hash) and hash != "" ->
        with {:ok, provenance} <- DecisionProvenance.from_json_safe(provenance),
             :ok <-
               verify_provenance_hash(
                 type,
                 event_id,
                 run_id,
                 decision_id,
                 decision_version,
                 occurred_at,
                 provenance,
                 hash
               ) do
          {:ok, provenance}
        end

      _other ->
        {:error, :invalid_provenance_binding}
    end
  end

  defp verify_provenance_hash(type, event_id, run_id, decision_id, decision_version, occurred_at, provenance, persisted_hash) do
    actual_hash =
      DecisionValidation.content_hash(%{
        schema_version: @schema_version,
        event_type: type,
        event_id: event_id,
        run_id: run_id,
        decision_id: decision_id,
        decision_version: decision_version,
        occurred_at: DateTime.to_iso8601(occurred_at),
        provenance: DecisionProvenance.to_json_safe(provenance)
      })

    if actual_hash == persisted_hash, do: :ok, else: {:error, :provenance_hash_mismatch}
  end

  defp validate_type(type) when type in @types, do: :ok
  defp validate_type(_other), do: {:error, {:event_type, :unknown}}

  defp validate_attention_slug(slug) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,63}\z/, slug),
      do: :ok,
      else: {:error, {:slug, :invalid_format}}
  end

  defp validate_schema_version(@schema_version), do: :ok
  defp validate_schema_version(_other), do: {:error, {:schema_version, :unsupported}}

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
