defmodule Aiur.UsageEnvelope do
  @moduledoc """
  A provider-neutral, content-free raw usage measurement.

  This is a pure contract. It preserves one provider observation and the
  trusted runtime context supplied by an adapter; it neither reads provider
  payloads nor derives cross-message deltas.
  """

  alias Aiur.{CodingAgent, TrackerIdentity, UsageEnvelope.ExactMoney, UsageEnvelope.Fields, UsageEnvelope.RelationshipRegistry}

  import Aiur.UsageEnvelope.Fields, except: [pricing_effective_date: 1, ledger_safe_identifier: 1]

  @version 1
  # Registry-derived at compile time: the provider families that meter, so a new
  # backend's envelopes validate without editing this list.
  @providers Aiur.CodingAgent.provider_families()
  @backends Enum.uniq(CodingAgent.usage_backends() ++ [:remote_control, :unknown])
  @transports Enum.uniq(CodingAgent.usage_transports() ++ [:otlp, :remote_control, :unknown])
  @measurement_kinds [:delta, :absolute]
  @counter_scopes [:request, :turn, :thread, :session]
  @update_kinds [:full, :partial]
  @agent_families @providers
  @auth_modes [:api_key, :chatgpt, :unknown]
  @fields [
    :schema_version,
    :idempotency_key,
    :provider,
    :source,
    :source_version,
    :source_event_id,
    :source_sequence,
    :occurred_at,
    :pricing_effective_date,
    :ingested_at,
    :measurement_kind,
    :counter_scope,
    :counter_epoch,
    :update_kind,
    :attribution,
    :agent_family,
    :backend,
    :transport,
    :auth_mode,
    :query_source,
    :upstream_provider,
    :effort,
    :requested_model,
    :resolved_model,
    :context_tier,
    :cache_write_duration,
    :account_generation,
    :tokens,
    :relationship_revision,
    :cost,
    :coverage_reasons
  ]

  @enforce_keys [
    :idempotency_key,
    :provider,
    :source,
    :source_version,
    :source_event_id,
    :source_sequence,
    :ingested_at,
    :measurement_kind,
    :counter_scope,
    :counter_epoch,
    :update_kind,
    :attribution,
    :agent_family,
    :backend,
    :transport,
    :auth_mode,
    :account_generation,
    :tokens,
    :relationship_revision
  ]
  defstruct [
    :idempotency_key,
    :provider,
    :source,
    :source_version,
    :source_event_id,
    :source_sequence,
    :occurred_at,
    :pricing_effective_date,
    :ingested_at,
    :measurement_kind,
    :counter_scope,
    :counter_epoch,
    :update_kind,
    :attribution,
    :agent_family,
    :backend,
    :transport,
    :auth_mode,
    :query_source,
    :upstream_provider,
    :effort,
    :requested_model,
    :resolved_model,
    :context_tier,
    :cache_write_duration,
    :account_generation,
    :tokens,
    :relationship_revision,
    :cost,
    schema_version: @version,
    coverage_reasons: []
  ]

  @type token_dimension :: :input | :cached_input | :cache_creation_input | :output | :reasoning_output
  @type token_values :: %{
          required(token_dimension()) => non_neg_integer() | nil,
          provider_reported_total: non_neg_integer() | nil
        }
  @type t :: %__MODULE__{}

  @spec schema_version() :: pos_integer()
  def schema_version, do: @version

  @spec token_dimensions() :: [token_dimension()]
  def token_dimensions, do: Enum.drop(Fields.token_fields(), -1)

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attributes) when is_map(attributes) do
    with :ok <- only_keys?(attributes, @fields, :invalid_envelope_field),
         :ok <- required_schema_version(value_of(attributes, :schema_version, @version)),
         {:ok, idempotency_key} <-
           opaque(value_of(attributes, :idempotency_key), :invalid_idempotency_key),
         {:ok, provider} <- enum(value_of(attributes, :provider), @providers, :invalid_provider),
         {:ok, source} <- opaque(value_of(attributes, :source), :invalid_source),
         {:ok, source_version} <- opaque(value_of(attributes, :source_version), :invalid_source_version),
         {:ok, source_event_id} <- opaque(value_of(attributes, :source_event_id), :invalid_source_event_id),
         {:ok, source_sequence} <- sequence(value_of(attributes, :source_sequence)),
         {:ok, occurred_at} <- occurred_at(value_of(attributes, :occurred_at)),
         :ok <- pricing_date_input_matches(value_of(attributes, :pricing_effective_date), occurred_at),
         {:ok, ingested_at} <- utc_datetime(value_of(attributes, :ingested_at), :invalid_ingested_at),
         {:ok, measurement_kind} <-
           enum(
             value_of(attributes, :measurement_kind),
             @measurement_kinds,
             :invalid_measurement_kind
           ),
         {:ok, counter_scope} <-
           enum(value_of(attributes, :counter_scope), @counter_scopes, :invalid_counter_scope),
         {:ok, counter_epoch} <- opaque(value_of(attributes, :counter_epoch), :missing_counter_epoch),
         {:ok, update_kind} <- enum(value_of(attributes, :update_kind), @update_kinds, :invalid_update_kind),
         {:ok, attribution} <- attribution(value_of(attributes, :attribution)),
         {:ok, agent_family} <-
           enum(value_of(attributes, :agent_family), @agent_families, :invalid_agent_family),
         {:ok, backend} <- enum(value_of(attributes, :backend), @backends, :invalid_backend),
         {:ok, transport} <- enum(value_of(attributes, :transport), @transports, :invalid_transport),
         {:ok, auth_mode} <- enum(value_of(attributes, :auth_mode), @auth_modes, :invalid_auth_mode),
         {:ok, query_source} <-
           optional_opaque_result(value_of(attributes, :query_source), :invalid_query_source),
         {:ok, upstream_provider} <-
           optional_ledger_identifier(value_of(attributes, :upstream_provider)),
         {:ok, effort} <- optional_opaque_result(value_of(attributes, :effort), :invalid_effort),
         {:ok, requested_model} <-
           optional_opaque_result(value_of(attributes, :requested_model), :invalid_requested_model),
         {:ok, resolved_model} <-
           optional_opaque_result(value_of(attributes, :resolved_model), :invalid_resolved_model),
         {:ok, context_tier} <- context_tier(value_of(attributes, :context_tier), provider),
         {:ok, cache_write_duration} <-
           cache_write_duration(value_of(attributes, :cache_write_duration), provider),
         {:ok, account_generation} <-
           account_generation(value_of(attributes, :account_generation), provider, backend),
         :ok <- distinct_epoch(account_generation, counter_epoch),
         {:ok, tokens} <- tokens(value_of(attributes, :tokens, %{})),
         {:ok, relationship_revision} <-
           opaque(
             value_of(attributes, :relationship_revision),
             :invalid_relationship_revision
           ),
         {:ok, cost} <- ExactMoney.decode(value_of(attributes, :cost)),
         :ok <- measurement_present(tokens, cost),
         {:ok, coverage_reasons} <-
           coverage_reasons(
             value_of(attributes, :coverage_reasons, []),
             occurred_at,
             account_generation
           ) do
      {:ok,
       %__MODULE__{
         schema_version: @version,
         idempotency_key: idempotency_key,
         provider: provider,
         source: source,
         source_version: source_version,
         source_event_id: source_event_id,
         source_sequence: source_sequence,
         occurred_at: occurred_at,
         pricing_effective_date: pricing_effective_date(occurred_at),
         ingested_at: ingested_at,
         measurement_kind: measurement_kind,
         counter_scope: counter_scope,
         counter_epoch: counter_epoch,
         update_kind: update_kind,
         attribution: attribution,
         agent_family: agent_family,
         backend: backend,
         transport: transport,
         auth_mode: auth_mode,
         query_source: query_source,
         upstream_provider: upstream_provider,
         effort: effort,
         requested_model: requested_model,
         resolved_model: resolved_model,
         context_tier: context_tier,
         cache_write_duration: cache_write_duration,
         account_generation: account_generation,
         tokens: tokens,
         relationship_revision: relationship_revision,
         cost: cost,
         coverage_reasons: coverage_reasons
       }}
    end
  end

  def new(_attributes), do: {:error, :invalid_envelope}

  @doc "Reconciles the raw dimensions against this envelope's exact pinned relationship revision."
  @spec reconcile(t(), RelationshipRegistry.catalog()) ::
          {:ok, RelationshipRegistry.reconciliation()} | {:error, atom()}
  def reconcile(%__MODULE__{} = envelope, catalog) do
    RelationshipRegistry.reconcile(catalog, envelope)
  end

  @doc "Returns a pure compatibility view without deriving cross-message deltas."
  @spec compatibility_projection(t(), RelationshipRegistry.catalog()) ::
          {:ok, map()} | {:error, atom()}
  def compatibility_projection(%__MODULE__{} = envelope, catalog) do
    with {:ok, reconciliation} <- reconcile(envelope, catalog) do
      {:ok,
       %{
         input_tokens: reconciliation.input_total,
         output_tokens: reconciliation.output_total,
         total_tokens: reconciliation.canonical_total,
         coverage: reconciliation.coverage,
         coverage_reasons: Enum.uniq(envelope.coverage_reasons ++ reconciliation.coverage_reasons),
         relationship_revision: envelope.relationship_revision,
         provider_account_generation: envelope.account_generation.generation,
         source_identity: raw_identity(envelope)
       }}
    end
  end

  @doc "Returns the trusted raw identity facts a durable ledger needs to distinguish streams."
  @spec raw_identity(t()) :: map()
  def raw_identity(%__MODULE__{} = envelope) do
    %{
      idempotency_key: envelope.idempotency_key,
      provider: envelope.provider,
      backend: envelope.backend,
      transport: envelope.transport,
      auth_mode: envelope.auth_mode,
      source: envelope.source,
      source_version: envelope.source_version,
      source_event_id: envelope.source_event_id,
      source_sequence: envelope.source_sequence,
      provider_account_generation: envelope.account_generation.generation,
      counter_epoch: envelope.counter_epoch,
      measurement_kind: envelope.measurement_kind,
      counter_scope: envelope.counter_scope,
      run_id: envelope.attribution.run_id,
      tracker_identity: envelope.attribution.tracker_identity,
      attempt_id: envelope.attribution.attempt_id,
      session_id: envelope.attribution.session_id,
      thread_id: envelope.attribution.thread_id,
      turn_id: envelope.attribution.turn_id,
      request_id: envelope.attribution.request_id,
      requested_model: envelope.requested_model,
      resolved_model: envelope.resolved_model,
      cost_currency: money_value(envelope.cost, :currency),
      cost_measurement_kind: money_value(envelope.cost, :measurement_kind),
      cost_counter_scope: money_value(envelope.cost, :counter_scope),
      cost_source: money_value(envelope.cost, :source),
      cost_source_version: money_value(envelope.cost, :source_version)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = envelope) do
    %{
      "schema_version" => envelope.schema_version,
      "idempotency_key" => envelope.idempotency_key,
      "provider" => Atom.to_string(envelope.provider),
      "source" => envelope.source,
      "source_version" => envelope.source_version,
      "source_event_id" => envelope.source_event_id,
      "source_sequence" => envelope.source_sequence,
      "occurred_at" => iso8601(envelope.occurred_at),
      "pricing_effective_date" => date(envelope.pricing_effective_date),
      "ingested_at" => iso8601(envelope.ingested_at),
      "measurement_kind" => Atom.to_string(envelope.measurement_kind),
      "counter_scope" => Atom.to_string(envelope.counter_scope),
      "counter_epoch" => envelope.counter_epoch,
      "update_kind" => Atom.to_string(envelope.update_kind),
      "attribution" => attribution_to_map(envelope.attribution),
      "agent_family" => Atom.to_string(envelope.agent_family),
      "backend" => Atom.to_string(envelope.backend),
      "transport" => Atom.to_string(envelope.transport),
      "auth_mode" => Atom.to_string(envelope.auth_mode),
      "query_source" => envelope.query_source,
      "upstream_provider" => envelope.upstream_provider,
      "effort" => envelope.effort,
      "requested_model" => envelope.requested_model,
      "resolved_model" => envelope.resolved_model,
      "context_tier" => optional_atom(envelope.context_tier),
      "cache_write_duration" => optional_atom(envelope.cache_write_duration),
      "account_generation" => account_generation_to_map(envelope.account_generation),
      "tokens" => tokens_to_map(envelope.tokens),
      "relationship_revision" => envelope.relationship_revision,
      "cost" => if(envelope.cost, do: ExactMoney.to_map(envelope.cost)),
      "coverage_reasons" => Enum.map(envelope.coverage_reasons, &Atom.to_string/1)
    }
  end

  @spec pricing_effective_date(DateTime.t() | nil) :: Date.t() | nil
  defdelegate pricing_effective_date(occurred_at), to: Fields

  @doc false
  @spec ledger_safe_identifier(term()) :: String.t() | nil
  defdelegate ledger_safe_identifier(value), to: Fields

  defp required_schema_version(@version), do: :ok
  defp required_schema_version(_value), do: {:error, :unsupported_schema_version}
  defp money_value(nil, _field), do: nil
  defp money_value(%ExactMoney{} = money, field), do: Map.fetch!(money, field)

  defp attribution_to_map(attribution) do
    attribution
    |> Map.new(fn {key, value} -> {Atom.to_string(key), if(key == :tracker_identity, do: tracker_identity_to_map(value), else: value)} end)
  end

  defp tracker_identity_to_map(nil), do: nil

  defp tracker_identity_to_map(%TrackerIdentity{} = identity) do
    %{
      "version" => identity.version,
      "status" => Atom.to_string(identity.status),
      "kind" => Atom.to_string(identity.kind),
      "owner" => identity.owner,
      "repository" => identity.repository,
      "provider_id" => identity.provider_id,
      "database_id" => identity.database_id,
      "identifier" => identity.identifier,
      "reason" => nil
    }
  end

  defp account_generation_to_map(context) do
    %{
      "schema_version" => context.schema_version,
      "provider" => Atom.to_string(context.provider),
      "backend" => Atom.to_string(context.backend),
      "generation" => context.generation,
      "freshness" => Atom.to_string(context.freshness),
      "health" => Atom.to_string(context.health),
      "reason" => if(context.reason, do: Atom.to_string(context.reason))
    }
  end

  defp tokens_to_map(tokens), do: Map.new(tokens, fn {key, value} -> {Atom.to_string(key), value} end)
  defp optional_atom(nil), do: nil
  defp optional_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp iso8601(nil), do: nil
  defp iso8601(value), do: DateTime.to_iso8601(value)
  defp date(nil), do: nil
  defp date(value), do: Date.to_iso8601(value)
end
