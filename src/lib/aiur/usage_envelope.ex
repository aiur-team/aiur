defmodule Aiur.UsageEnvelope do
  @moduledoc """
  A provider-neutral, content-free raw usage measurement.

  This is a pure contract. It preserves one provider observation and the
  trusted runtime context supplied by an adapter; it neither reads provider
  payloads nor derives cross-message deltas.
  """

  alias Aiur.{TrackerIdentity, UsageEnvelope.ExactMoney, UsageEnvelope.RelationshipRegistry}

  @version 1
  @max_opaque_bytes 256
  @providers [:codex, :claude]
  @backends [:app_server, :remote_control, :unknown]
  @transports [:app_server, :otlp, :remote_control, :unknown]
  @measurement_kinds [:delta, :absolute]
  @counter_scopes [:request, :turn, :thread, :session]
  @update_kinds [:full, :partial]
  @agent_families [:codex, :claude]
  @auth_modes [:api_key, :chatgpt, :unknown]
  @freshnesses [:current, :unknown]
  @healths [:healthy, :unknown, :unavailable]
  @account_reasons [
    :owner_unavailable,
    :never_observed,
    :continuity_lost,
    :logout,
    :credential_replaced,
    :account_replaced,
    :backend_replaced,
    :no_authenticated_account,
    :unsupported_auth_mode,
    :untrusted_lifecycle
  ]
  @coverage_reasons [
    :missing_trusted_occurrence_time,
    :unknown_relationship,
    :contradictory_relationship,
    :missing_historic_relationship_revision,
    :partial_update,
    :untrusted_account_generation,
    :unknown_account_generation
  ]
  @token_fields [:input, :cached_input, :cache_creation_input, :output, :reasoning_output, :provider_reported_total]
  @attribution_fields [:run_id, :tracker_identity, :attempt_id, :session_id, :thread_id, :turn_id, :request_id]
  @account_generation_fields [
    :schema_version,
    :provider,
    :backend,
    :generation,
    :freshness,
    :health,
    :reason
  ]
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
    :effort,
    :requested_model,
    :resolved_model,
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
    :effort,
    :requested_model,
    :resolved_model,
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
  def token_dimensions, do: Enum.drop(@token_fields, -1)

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
         {:ok, effort} <- optional_opaque_result(value_of(attributes, :effort), :invalid_effort),
         {:ok, requested_model} <-
           optional_opaque_result(value_of(attributes, :requested_model), :invalid_requested_model),
         {:ok, resolved_model} <-
           optional_opaque_result(value_of(attributes, :resolved_model), :invalid_resolved_model),
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
         effort: effort,
         requested_model: requested_model,
         resolved_model: resolved_model,
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
      "effort" => envelope.effort,
      "requested_model" => envelope.requested_model,
      "resolved_model" => envelope.resolved_model,
      "account_generation" => account_generation_to_map(envelope.account_generation),
      "tokens" => tokens_to_map(envelope.tokens),
      "relationship_revision" => envelope.relationship_revision,
      "cost" => if(envelope.cost, do: ExactMoney.to_map(envelope.cost)),
      "coverage_reasons" => Enum.map(envelope.coverage_reasons, &Atom.to_string/1)
    }
  end

  @spec pricing_effective_date(DateTime.t() | nil) :: Date.t() | nil
  def pricing_effective_date(%DateTime{} = occurred_at), do: DateTime.to_date(occurred_at)
  def pricing_effective_date(nil), do: nil

  defp pricing_date_input_matches(nil, _occurred_at), do: :ok

  defp pricing_date_input_matches(%Date{} = value, occurred_at) do
    if value == pricing_effective_date(occurred_at),
      do: :ok,
      else: {:error, :invalid_pricing_effective_date}
  end

  defp pricing_date_input_matches(value, occurred_at) when is_binary(value) do
    if value == date(pricing_effective_date(occurred_at)),
      do: :ok,
      else: {:error, :invalid_pricing_effective_date}
  end

  defp pricing_date_input_matches(_value, _occurred_at),
    do: {:error, :invalid_pricing_effective_date}

  defp required_schema_version(@version), do: :ok
  defp required_schema_version(_value), do: {:error, :unsupported_schema_version}

  defp occurred_at(nil), do: {:ok, nil}
  defp occurred_at(value), do: utc_datetime(value, :invalid_occurred_at)

  defp utc_datetime(%DateTime{utc_offset: 0, std_offset: 0} = value, _error), do: {:ok, value}
  defp utc_datetime(_value, error), do: {:error, error}

  defp sequence(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp sequence(nil), do: {:error, :missing_source_sequence}
  defp sequence(_value), do: {:error, :invalid_source_sequence}

  defp opaque(value, error) when is_binary(value) and byte_size(value) in 1..@max_opaque_bytes do
    if String.valid?(value) and value == String.trim(value),
      do: {:ok, value},
      else: {:error, error}
  end

  defp opaque(_value, error), do: {:error, error}

  defp enum(value, allowed, error) do
    case normalize_atom(value, allowed) do
      nil -> {:error, error}
      atom -> {:ok, atom}
    end
  end

  defp normalize_atom(value, allowed) when is_atom(value), do: if(value in allowed, do: value)
  defp normalize_atom(value, allowed) when is_binary(value), do: Enum.find(allowed, &(Atom.to_string(&1) == value))
  defp normalize_atom(_value, _allowed), do: nil

  defp attribution(value) when is_map(value) do
    with :ok <- only_keys?(value, @attribution_fields, :invalid_attribution),
         {:ok, tracker_identity} <- tracker_identity(value_of(value, :tracker_identity)),
         {:ok, opaque_values} <- attribution_opaques(value) do
      {:ok, Map.put(opaque_values, :tracker_identity, tracker_identity)}
    end
  end

  defp attribution(_value), do: {:error, :invalid_attribution}

  defp attribution_opaques(value) do
    Enum.reduce_while(@attribution_fields -- [:tracker_identity], {:ok, %{}}, fn key, {:ok, acc} ->
      case optional_opaque_result(value_of(value, key), :invalid_attribution) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp optional_opaque_result(nil, _error), do: {:ok, nil}
  defp optional_opaque_result(value, error), do: opaque(value, error)

  defp tracker_identity(nil), do: {:ok, nil}

  defp tracker_identity(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity) and
         (is_nil(identity.database_id) or (is_integer(identity.database_id) and identity.database_id > 0)),
       do: {:ok, identity},
       else: {:error, :unjoinable_tracker_identity}
  end

  defp tracker_identity(_identity), do: {:error, :invalid_attribution}

  defp account_generation(value, provider, backend) when is_map(value) do
    with :ok <- only_keys?(value, @account_generation_fields, :invalid_account_generation_context),
         :ok <- account_schema_version(value_of(value, :schema_version, 1)),
         {:ok, account_provider} <- enum(value_of(value, :provider), @providers, :invalid_account_generation_context),
         {:ok, account_backend} <- enum(value_of(value, :backend), @backends, :invalid_account_generation_context),
         true <- account_provider == provider and account_backend == backend,
         {:ok, generation} <- optional_opaque_result(value_of(value, :generation), :invalid_account_generation_context),
         {:ok, freshness} <- enum(value_of(value, :freshness), @freshnesses, :invalid_account_generation_context),
         {:ok, health} <- enum(value_of(value, :health), @healths, :invalid_account_generation_context),
         {:ok, reason} <- account_reason(value_of(value, :reason)),
         :ok <- valid_account_state(generation, freshness, health, reason) do
      {:ok,
       %{
         schema_version: 1,
         provider: account_provider,
         backend: account_backend,
         generation: generation,
         freshness: freshness,
         health: health,
         reason: reason
       }}
    else
      false -> {:error, :invalid_account_generation_context}
      {:error, _reason} = error -> error
    end
  end

  defp account_generation(_value, _provider, _backend), do: {:error, :invalid_account_generation_context}

  defp account_schema_version(1), do: :ok
  defp account_schema_version(_value), do: {:error, :invalid_account_generation_context}
  defp account_reason(nil), do: {:ok, nil}
  defp account_reason(value), do: enum(value, @account_reasons, :invalid_account_generation_context)
  defp valid_account_state(generation, :current, :healthy, nil) when is_binary(generation), do: :ok

  defp valid_account_state(nil, :unknown, health, reason)
       when health in [:unknown, :unavailable] and not is_nil(reason),
       do: :ok

  defp valid_account_state(_generation, _freshness, _health, _reason),
    do: {:error, :invalid_account_generation_context}

  defp distinct_epoch(%{generation: generation}, generation) when is_binary(generation),
    do: {:error, :account_generation_used_as_counter_epoch}

  defp distinct_epoch(_account_generation, _counter_epoch), do: :ok

  defp tokens(value) when is_map(value) do
    with :ok <- only_keys?(value, @token_fields, :invalid_tokens) do
      normalize_tokens(value)
    end
  end

  defp tokens(_value), do: {:error, :invalid_tokens}

  defp normalize_tokens(value) do
    Enum.reduce_while(@token_fields, {:ok, %{}}, fn key, {:ok, acc} ->
      normalize_token(value, key, acc)
    end)
  end

  defp normalize_token(value, key, acc) do
    case token_value(value_of(value, key)) do
      {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp token_value(nil), do: {:ok, nil}
  defp token_value(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp token_value(_value), do: {:error, :invalid_token_dimension}

  defp measurement_present(tokens, cost) do
    if Enum.any?(tokens, fn {_dimension, value} -> is_integer(value) end) or not is_nil(cost),
      do: :ok,
      else: {:error, :missing_usage_measurement}
  end

  defp coverage_reasons(value, occurred_at, account_generation) when is_list(value) do
    with {:ok, explicit} <- enum_list(value, @coverage_reasons, :invalid_coverage_reason) do
      implicit =
        []
        |> maybe_reason(is_nil(occurred_at), :missing_trusted_occurrence_time)
        |> maybe_reason(is_nil(account_generation.generation), :unknown_account_generation)

      {:ok, Enum.uniq(explicit ++ implicit)}
    end
  end

  defp coverage_reasons(_value, _occurred_at, _account_generation), do: {:error, :invalid_coverage_reason}

  defp enum_list(values, allowed, error),
    do:
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case enum(value, allowed, error) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> reverse_ok()

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error
  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp money_value(nil, _field), do: nil
  defp money_value(%ExactMoney{} = money, field), do: Map.fetch!(money, field)

  defp only_keys?(map, allowed, error) do
    allowed_strings = Enum.map(allowed, &Atom.to_string/1)

    if Enum.all?(Map.keys(map), fn key -> key in allowed or key in allowed_strings end),
      do: :ok,
      else: {:error, error}
  end

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
  defp iso8601(nil), do: nil
  defp iso8601(value), do: DateTime.to_iso8601(value)
  defp date(nil), do: nil
  defp date(value), do: Date.to_iso8601(value)
  defp value_of(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
