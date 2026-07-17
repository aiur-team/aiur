defmodule Aiur.Claude.Telemetry.UsageAdapter do
  @moduledoc """
  Converts one authenticated Claude request event into a content-free usage envelope.

  The adapter is deliberately pinned to one reviewed Claude Code event contract and
  one token-relationship revision. Unknown contracts produce bounded coverage facts;
  they are never interpreted by similarity to a supported revision.
  """

  alias Aiur.Claude.Telemetry.Contract
  alias Aiur.Claude.Telemetry.UsageAdapter.Relationship
  alias Aiur.Claude.Telemetry.UsageAdapter.Validation
  alias Aiur.UsageEnvelope
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @source Contract.source()
  @source_version Contract.source_version()
  @relationship_revision Relationship.revision()
  @optional_fields [
    {:request_id, "request_id"},
    {:cache_read_tokens, "cache_read_tokens"},
    {:cache_creation_tokens, "cache_creation_tokens"},
    {:query_source, "query_source"},
    {:effort, "effort"},
    {:cost_usd, "cost_usd"},
    {:occurred_at, :occurred_at}
  ]

  @type coverage_class ::
          :unsupported_source_revision
          | :unsupported_relationship_revision
          | :missing_required_identity
          | :ambiguous_measurement_semantics
          | :optional_field_absent

  @type coverage :: %{
          schema_version: 1,
          source: String.t(),
          adapter_version: String.t(),
          class: coverage_class(),
          field: atom()
        }

  @spec relationship_definition() :: map()
  def relationship_definition, do: Relationship.definition()

  @spec relationship_catalog() :: RelationshipRegistry.catalog()
  def relationship_catalog, do: Relationship.catalog()

  @doc false
  @spec coverage(coverage_class(), atom()) :: coverage()
  def coverage(class, field) do
    %{
      schema_version: 1,
      source: @source,
      adapter_version: @source_version,
      class: class,
      field: field
    }
  end

  @spec normalize(map(), DateTime.t(), RelationshipRegistry.catalog()) ::
          {:ok, UsageEnvelope.t(), [coverage()]} | {:coverage, coverage()}
  def normalize(event, ingested_at, catalog \\ relationship_catalog()) do
    with {:ok, normalized} <- Validation.validate(event, ingested_at),
         {:ok, envelope} <- UsageEnvelope.new(envelope_attributes(normalized, ingested_at)),
         :ok <- Relationship.supported?(catalog, envelope) do
      {:ok, envelope, optional_coverage(normalized)}
    else
      {:error, class, field} -> terminal(class, field)
      {:error, :missing_historic_relationship_revision} -> terminal(:unsupported_relationship_revision, :relationship_revision)
      {:error, :invalid_relationship_catalog} -> terminal(:unsupported_relationship_revision, :relationship_revision)
      {:error, _reason} -> terminal(:ambiguous_measurement_semantics, :envelope)
    end
  end

  defp envelope_attributes(normalized, ingested_at) do
    attributes = normalized.attributes
    correlation = normalized.correlation
    partial? = is_nil(attributes["cache_read_tokens"]) or is_nil(attributes["cache_creation_tokens"])

    %{
      idempotency_key: idempotency_key(correlation, normalized.source_event_id),
      provider: :claude,
      source: @source,
      source_version: @source_version,
      source_event_id: normalized.source_event_id,
      source_sequence: normalized.source_sequence,
      occurred_at: normalized.occurred_at,
      ingested_at: ingested_at,
      measurement_kind: :delta,
      counter_scope: :request,
      counter_epoch: counter_epoch(correlation),
      update_kind: if(partial?, do: :partial, else: :full),
      attribution: %{
        run_id: correlation.run_id,
        tracker_identity: correlation.ticket,
        attempt_id: correlation.attempt_id,
        session_id: correlation.session_id,
        thread_id: nil,
        turn_id: nil,
        request_id: normalized.request_id
      },
      agent_family: :claude,
      backend: :remote_control,
      transport: :otlp,
      auth_mode: :unknown,
      query_source: attributes["query_source"],
      effort: attributes["effort"],
      requested_model: nil,
      resolved_model: attributes["model"],
      account_generation: %{
        provider: :claude,
        backend: :remote_control,
        generation: nil,
        freshness: :unknown,
        health: :unknown,
        reason: :untrusted_lifecycle
      },
      tokens: %{
        input: attributes["input_tokens"],
        cached_input: attributes["cache_read_tokens"],
        cache_creation_input: attributes["cache_creation_tokens"],
        output: attributes["output_tokens"],
        reasoning_output: nil,
        provider_reported_total: nil
      },
      relationship_revision: @relationship_revision,
      cost: cost(attributes["cost_usd"]),
      coverage_reasons: if(partial?, do: [:partial_update], else: [])
    }
  end

  defp cost(nil), do: nil

  defp cost(amount) do
    %{
      amount: amount,
      currency: "USD",
      unit: :major,
      source_representation: :major,
      measurement_kind: :delta,
      counter_scope: :request,
      source: @source <> ".cost_usd",
      source_version: @source_version,
      coverage: :full
    }
  end

  defp optional_coverage(normalized) do
    Enum.flat_map(@optional_fields, fn {field, source_key} ->
      if optional_present?(normalized, source_key), do: [], else: [coverage(:optional_field_absent, field)]
    end)
  end

  defp optional_present?(normalized, :occurred_at), do: not is_nil(normalized.occurred_at)
  defp optional_present?(normalized, source_key), do: not is_nil(normalized.attributes[source_key])

  defp idempotency_key(correlation, source_event_id) do
    "claude-request:" <>
      fingerprint([
        @source_version,
        correlation.run_id,
        correlation.session_id,
        correlation.worker_generation,
        correlation.producer_generation,
        source_event_id
      ])
  end

  defp counter_epoch(correlation) do
    "claude-counter:" <>
      fingerprint([
        @source_version,
        correlation.run_id,
        correlation.session_id,
        correlation.worker_generation,
        correlation.producer_generation
      ])
  end

  defp fingerprint(parts) do
    serialized =
      Enum.map_join(parts, "|", fn part ->
        scalar = to_string(part)
        "#{byte_size(scalar)}:#{scalar}"
      end)

    :crypto.hash(:sha256, serialized) |> Base.encode16(case: :lower)
  end

  defp terminal(class, field), do: {:coverage, coverage(class, field)}
end
