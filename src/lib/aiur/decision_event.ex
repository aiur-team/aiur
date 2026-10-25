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

  alias Aiur.{Decision, DecisionAnswer, DecisionRevision, DecisionValidation}
  alias Aiur.DecisionEvent.{Codec, Provenance, Unrecognized, Validation}
  @schema_version 1
  @versioned_snapshot_schema_version 2
  @identity_max 256
  @types [
    :requested,
    :enriched,
    :decision_expired,
    :decision_dismissed,
    :decision_deferred,
    :decision_mooted,
    :executor_escalated,
    :authority_reclassified,
    :answer_recorded,
    :pending_for_session,
    :session_started,
    :answer_comment_published,
    :revision_recorded,
    :dispatch_queued,
    :revision_dispatched,
    :revision_no_longer_applicable,
    :follow_up_required,
    :follow_up_handled,
    :handed_off,
    :delivered,
    :restored,
    :consumed,
    :failed,
    :acknowledged,
    :resolved
  ]
  @snapshot_types [:requested, :enriched]

  # A timed-out dispatch may still be queued; the store later adopts that item (#2717).
  @outcome_unknown_types [:dispatch_outcome_unknown]
  @types @types ++ @outcome_unknown_types

  @type type ::
          :requested
          | :enriched
          | :decision_expired
          | :decision_dismissed
          | :decision_deferred
          | :decision_mooted
          | :executor_escalated
          | :authority_reclassified
          | :answer_recorded
          | :pending_for_session
          | :session_started
          | :answer_comment_published
          | :revision_recorded
          | :dispatch_queued
          | :dispatch_outcome_unknown
          | :revision_dispatched
          | :revision_no_longer_applicable
          | :follow_up_required
          | :follow_up_handled
          | :handed_off
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
      do: {:ok, Provenance.provenance_event_id(event_id)},
      else: {:error, {:event_id, :snapshot_marker_required}}
  end

  defp durable_snapshot_event_id(_type, event_id), do: {:ok, event_id}

  defp build(schema_version, type, decision_id, decision_version, data, opts, trusted_provenance) do
    event_id = Keyword.fetch!(opts, :event_id)
    run_id = Keyword.fetch!(opts, :run_id)
    occurred_at = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_type(type),
         {:ok, decision_id} <- Validation.bounded_required(decision_id, @identity_max, :decision_id),
         :ok <- Validation.validate_version(decision_version),
         :ok <- Validation.validate_event_id(event_id),
         {:ok, run_id} <- Validation.bounded_required(run_id, @identity_max, :run_id),
         :ok <- Validation.validate_timestamp(occurred_at),
         {:ok, data} <- Codec.normalize_data(type, data, decision_id, decision_version, trusted_provenance) do
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
         {:ok, decision_id} <- Validation.fetch_string(raw, "decision_id", :decision_id),
         {:ok, decision_version} <- Validation.fetch_version(raw, "decision_version", :decision_version),
         {:ok, event_id} <- Validation.fetch_event_id(raw),
         {:ok, run_id} <- Validation.fetch_string(raw, "run_id", :run_id),
         {:ok, occurred_at} <- Validation.fetch_timestamp(raw, "occurred_at", :occurred_at),
         {:ok, data} <- Validation.fetch_map(raw, "data", :data),
         {:ok, persisted_hash} <- Validation.fetch_string(raw, "content_hash", :content_hash),
         {:ok, event} <-
           decode_typed_event(schema_version, type, decision_id, decision_version, data, event_id, run_id, occurred_at),
         :ok <- Validation.verify_hash(event.content_hash, persisted_hash) do
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
      "data" => Provenance.event_data_to_json_safe(event),
      "content_hash" => event.content_hash
    }
  end

  defp decode_typed_event(schema_version, type, decision_id, decision_version, data, event_id, run_id, occurred_at) do
    with {:ok, trusted_provenance} <-
           Provenance.decode_typed_provenance(
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

  # Schema-1 hashes retain main's material; provenance remains rollback-compatible.
  defp legacy_data_to_json_safe(:requested, %Decision{} = decision) do
    Codec.data_to_json_safe(:requested, decision)
    |> Map.delete("provenance")
  end

  defp legacy_data_to_json_safe(:enriched, data) do
    encoded = Codec.data_to_json_safe(:enriched, data)

    encoded
    |> Map.delete("provenance_hash")
    |> Map.put("decision", Map.delete(encoded["decision"], "provenance"))
  end

  defp legacy_data_to_json_safe(type, data), do: Codec.data_to_json_safe(type, data)

  defp event_hash_data(@schema_version, type, data), do: legacy_data_to_json_safe(type, data)

  defp event_hash_data(@versioned_snapshot_schema_version, type, data),
    do: Codec.data_to_json_safe(type, data) |> Provenance.maybe_put_provenance_state(type, data)

  defp validate_type(type) when type in @types, do: :ok
  defp validate_type(_other), do: {:error, {:event_type, :unknown}}

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

  @doc false
  @spec parse_provenance_event_id(term()) :: {:ok, pos_integer()} | :error
  defdelegate parse_provenance_event_id(event_id), to: Aiur.DecisionEvent.Provenance
end
