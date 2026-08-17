defmodule Aiur.Usage.Headless.Adapter do
  @moduledoc """
  Narrow behaviour for one pinned Codex or Claude headless usage source.

  Each adapter owns exactly one `(provider, source, source_version)` mapping and
  its single token-relationship revision. An adapter never falls forward to a
  newer protocol: an observed source revision that does not match the pinned one
  yields bounded coverage rather than current-version semantics.

  Adapters are pure. They read a raw provider payload plus a trusted
  `Aiur.Usage.Headless.Context`, and return at most one raw
  `Aiur.UsageEnvelope` identity per accepted event, or a bounded coverage
  reason. They never derive a cross-message delta, retain provider payloads,
  or emit a guessed identity, scope, or zero.
  """

  alias Aiur.CodingAgent
  alias Aiur.Usage.Headless.Context
  alias Aiur.UsageEnvelope
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @coverage_classes [
    :unsupported_source_revision,
    :unsupported_relationship_revision,
    :missing_usage_measurement,
    :ambiguous_measurement_semantics
  ]

  @type coverage_class ::
          :unsupported_source_revision
          | :unsupported_relationship_revision
          | :missing_usage_measurement
          | :ambiguous_measurement_semantics

  @type coverage :: %{
          schema_version: 1,
          provider: atom(),
          source: String.t(),
          source_version: String.t(),
          class: coverage_class(),
          field: atom()
        }

  @type result :: {:ok, UsageEnvelope.t()} | {:coverage, coverage()}

  @doc "The provider whose events this adapter maps."
  @callback provider() :: atom()

  @doc "The exact source identifier this adapter is pinned to."
  @callback source() :: String.t()

  @doc "The exact installed source revision this adapter was characterized against."
  @callback source_version() :: String.t()

  @doc "The single token-relationship revision this adapter pins on every envelope."
  @callback relationship_revision() :: String.t()

  @doc "The immutable relationship definition this adapter contributes to the registry."
  @callback relationship_definition() :: RelationshipRegistry.definition()

  @doc """
  Maps one raw payload into zero or more results.

  The empty list means the payload carries no usage for this source. `raw` is the
  untouched provider JSON string when available, so exact decimal cost can be
  recovered before any float conversion.
  """
  @callback extract(payload :: map(), raw :: String.t() | nil, Context.t(), ingested_at :: DateTime.t()) :: [result()]

  @doc "Builds the bounded coverage fact for one adapter."
  @spec coverage(module(), coverage_class(), atom()) :: coverage()
  def coverage(adapter, class, field) when class in @coverage_classes and is_atom(field) do
    %{
      schema_version: 1,
      provider: adapter.provider(),
      source: adapter.source(),
      source_version: adapter.source_version(),
      class: class,
      field: field
    }
  end

  @doc """
  Builds a validated envelope for one accepted event.

  The trusted context supplies attribution, account generation, counter epoch,
  and the ingestion-monotonic source sequence. The adapter supplies only the
  raw source facts and its pinned relationship revision.
  """
  @spec build_envelope(module(), Context.t(), keyword()) :: result()
  def build_envelope(adapter, %Context{} = context, source_facts) when is_list(source_facts) do
    attributes = envelope_attributes(adapter, context, source_facts)

    with :ok <- observed_price_dimensions(attributes),
         {:ok, envelope} <- UsageEnvelope.new(attributes) do
      {:ok, envelope}
    else
      {:error, :missing_usage_measurement} -> {:coverage, coverage(adapter, :missing_usage_measurement, :tokens)}
      {:error, field} when field in [:context_tier, :cache_write_duration] -> {:coverage, coverage(adapter, :ambiguous_measurement_semantics, field)}
      {:error, _reason} -> {:coverage, coverage(adapter, :ambiguous_measurement_semantics, :envelope)}
    end
  end

  defp observed_price_dimensions(%{provider: provider} = attributes) do
    case CodingAgent.provider_pricing(provider) do
      %{dimensions: dimensions} when is_map(dimensions) ->
        Enum.reduce_while(dimensions, :ok, &validate_price_dimension(&1, &2, attributes))

      _ ->
        {:error, :context_tier}
    end
  end

  defp validate_price_dimension({field, %{allowed: allowed, required: required}}, :ok, attributes) do
    if not required or Map.get(attributes, field) in allowed, do: {:cont, :ok}, else: {:halt, {:error, field}}
  end

  defp envelope_attributes(adapter, context, source_facts) do
    source_event_id = Keyword.fetch!(source_facts, :source_event_id)
    provider = adapter.provider()

    %{
      idempotency_key: idempotency_key(adapter, context, source_event_id),
      provider: provider,
      source: adapter.source(),
      source_version: adapter.source_version(),
      source_event_id: source_event_id,
      source_sequence: context.source_sequence,
      occurred_at: Keyword.get(source_facts, :occurred_at),
      ingested_at: Keyword.fetch!(source_facts, :ingested_at),
      measurement_kind: Keyword.fetch!(source_facts, :measurement_kind),
      counter_scope: Keyword.fetch!(source_facts, :counter_scope),
      counter_epoch: counter_epoch(adapter, context),
      update_kind: Keyword.fetch!(source_facts, :update_kind),
      attribution: attribution(context),
      agent_family: context.agent_family,
      backend: context.backend,
      transport: context.transport,
      auth_mode: context.auth_mode,
      query_source: context.query_source,
      upstream_provider: context.upstream_provider,
      effort: context.effort,
      requested_model: context.requested_model,
      resolved_model: context.resolved_model,
      context_tier: Keyword.get(source_facts, :context_tier, default_context_tier(provider)),
      cache_write_duration: Keyword.get(source_facts, :cache_write_duration, default_cache_write_duration(provider)),
      account_generation: context.account_generation,
      tokens: Keyword.fetch!(source_facts, :tokens),
      relationship_revision: adapter.relationship_revision(),
      cost: Keyword.get(source_facts, :cost),
      coverage_reasons: Keyword.get(source_facts, :coverage_reasons, [])
    }
  end

  defp default_context_tier(provider), do: pricing_default(provider, :context_tier)
  defp default_cache_write_duration(provider), do: pricing_default(provider, :cache_write_duration)

  defp pricing_default(provider, dimension) do
    with %{dimensions: dimensions} <- CodingAgent.provider_pricing(provider),
         %{default: default} <- Map.get(dimensions, dimension) do
      default
    else
      _ -> nil
    end
  end

  defp attribution(%Context{} = context) do
    %{
      run_id: context.run_id,
      tracker_identity: context.tracker_identity,
      attempt_id: context.attempt_id,
      session_id: context.session_id,
      thread_id: context.thread_id,
      turn_id: context.turn_id,
      request_id: context.request_id
    }
  end

  @doc "Stable per-event idempotency identity that rotates with attempt, worker, and account generation."
  @spec idempotency_key(module(), Context.t(), String.t()) :: String.t()
  def idempotency_key(adapter, %Context{} = context, source_event_id) do
    adapter.source() <>
      ":" <>
      fingerprint([
        adapter.source_version(),
        context.run_id,
        context.session_id,
        context.attempt_id,
        context.worker_generation,
        context.account_generation.generation,
        source_event_id
      ])
  end

  @doc "Resettable counter epoch shared by every event in one authenticated stream."
  @spec counter_epoch(module(), Context.t()) :: String.t()
  def counter_epoch(adapter, %Context{} = context) do
    adapter.source() <>
      ":epoch:" <>
      fingerprint([
        adapter.source_version(),
        context.run_id,
        context.session_id,
        context.attempt_id,
        context.worker_generation,
        context.account_generation.generation
      ])
  end

  @doc "A deterministic content-free fingerprint over length-prefixed scalar parts."
  @spec fingerprint([term()]) :: String.t()
  def fingerprint(parts) when is_list(parts) do
    parts
    |> Enum.map_join("|", fn part ->
      scalar = scalar(part)
      "#{byte_size(scalar)}:#{scalar}"
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp scalar(nil), do: ""
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(value), do: inspect(value)

  @doc """
  Reads a non-negative integer token count from a raw provider map.

  Absent or non-integer values return `nil`; they never become zero.
  """
  @spec token(term(), [term()]) :: non_neg_integer() | nil
  def token(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> integer_like(Map.get(map, key)) end)
  end

  def token(_map, _keys), do: nil

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number >= 0 -> number
      _other -> nil
    end
  end

  defp integer_like(_value), do: nil

  @doc """
  Recovers an exact-decimal cost from the raw provider JSON string.

  Provider numbers are re-decoded with `floats: :decimals` so the exact wire
  representation is preserved before any float conversion. Returns `:absent`
  when no cost is present and `:imprecise` when only a lossy float is available.
  """
  @spec exact_cost(String.t() | nil, term(), [String.t() | [String.t()]]) :: {:ok, Decimal.t()} | :absent | :imprecise
  def exact_cost(raw, decoded_value, paths) when is_binary(raw) and is_list(paths) do
    case Jason.decode(raw, floats: :decimals) do
      {:ok, decoded} -> cost_from_map(decoded, paths, decoded_value)
      {:error, _reason} -> exact_cost(nil, decoded_value, paths)
    end
  end

  def exact_cost(_raw, nil, _paths), do: :absent
  def exact_cost(_raw, value, _paths) when is_integer(value) and value >= 0, do: {:ok, Decimal.new(value)}
  def exact_cost(_raw, %Decimal{} = value, _paths), do: {:ok, value}
  def exact_cost(_raw, value, _paths) when is_float(value), do: :imprecise
  def exact_cost(_raw, _value, _paths), do: :absent

  defp cost_from_map(decoded, paths, fallback) do
    case Enum.find_value(paths, fn path -> dig(decoded, path) end) do
      %Decimal{} = amount -> non_negative(amount)
      value when is_integer(value) and value >= 0 -> {:ok, Decimal.new(value)}
      _other -> exact_cost(nil, fallback, paths)
    end
  end

  defp non_negative(%Decimal{} = amount) do
    if Decimal.negative?(amount) or Decimal.nan?(amount) or Decimal.inf?(amount), do: :absent, else: {:ok, amount}
  end

  defp dig(map, path) when is_map(map) and is_binary(path) do
    Map.get(map, path)
  end

  defp dig(map, path) when is_map(map) and is_list(path) do
    Enum.reduce_while(path, map, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key), do: {:cont, Map.get(acc, key)}, else: {:halt, nil}
    end)
  end

  defp dig(_map, _path), do: nil
end
