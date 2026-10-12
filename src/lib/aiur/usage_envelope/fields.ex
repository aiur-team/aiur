defmodule Aiur.UsageEnvelope.Fields do
  @moduledoc "Field validators and normalizers for `Aiur.UsageEnvelope.new/1`."

  alias Aiur.{CodingAgent, TrackerIdentity}

  @max_opaque_bytes 256
  @ledger_identifier ~r/\A[A-Za-z0-9._:-]+\z/
  @sensitive_identifier ~r/(?:sk[-_][A-Za-z0-9]|ghp_|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|secret|password|credential|bearer|authorization|api[-_]?key|prompt)/i
  # Registry-derived at compile time: the provider families that meter, so a new
  # backend's envelopes validate without editing this list.
  @providers Aiur.CodingAgent.provider_families()
  @backends Enum.uniq(CodingAgent.usage_backends() ++ [:remote_control, :unknown])
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

  @spec pricing_effective_date(DateTime.t() | nil) :: Date.t() | nil
  def pricing_effective_date(%DateTime{} = occurred_at), do: DateTime.to_date(occurred_at)
  def pricing_effective_date(nil), do: nil

  @doc false
  @spec pricing_date_input_matches(term(), DateTime.t() | nil) :: :ok | {:error, atom()}
  def pricing_date_input_matches(nil, _occurred_at), do: :ok

  def pricing_date_input_matches(%Date{} = value, occurred_at) do
    if value == pricing_effective_date(occurred_at),
      do: :ok,
      else: {:error, :invalid_pricing_effective_date}
  end

  def pricing_date_input_matches(value, occurred_at) when is_binary(value) do
    if value == date(pricing_effective_date(occurred_at)),
      do: :ok,
      else: {:error, :invalid_pricing_effective_date}
  end

  def pricing_date_input_matches(_value, _occurred_at),
    do: {:error, :invalid_pricing_effective_date}

  @doc false
  @spec occurred_at(term()) :: {:ok, DateTime.t() | nil} | {:error, atom()}
  def occurred_at(nil), do: {:ok, nil}
  def occurred_at(value), do: utc_datetime(value, :invalid_occurred_at)

  @doc false
  @spec utc_datetime(term(), atom()) :: {:ok, DateTime.t()} | {:error, atom()}
  def utc_datetime(%DateTime{utc_offset: 0, std_offset: 0} = value, _error), do: {:ok, value}
  def utc_datetime(_value, error), do: {:error, error}

  @doc false
  @spec sequence(term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def sequence(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def sequence(nil), do: {:error, :missing_source_sequence}
  def sequence(_value), do: {:error, :invalid_source_sequence}

  @doc false
  @spec opaque(term(), atom()) :: {:ok, String.t()} | {:error, atom()}
  def opaque(value, error) when is_binary(value) and byte_size(value) in 1..@max_opaque_bytes do
    if String.valid?(value) and value == String.trim(value),
      do: {:ok, value},
      else: {:error, error}
  end

  def opaque(_value, error), do: {:error, error}

  @doc false
  @spec enum(term(), [atom()], atom()) :: {:ok, atom()} | {:error, atom()}
  def enum(value, allowed, error) do
    case normalize_atom(value, allowed) do
      nil -> {:error, error}
      atom -> {:ok, atom}
    end
  end

  defp normalize_atom(value, allowed) when is_atom(value), do: if(value in allowed, do: value)
  defp normalize_atom(value, allowed) when is_binary(value), do: Enum.find(allowed, &(Atom.to_string(&1) == value))
  defp normalize_atom(_value, _allowed), do: nil

  @doc false
  @spec attribution(term()) :: {:ok, map()} | {:error, atom()}
  def attribution(value) when is_map(value) do
    with :ok <- only_keys?(value, @attribution_fields, :invalid_attribution),
         {:ok, tracker_identity} <- tracker_identity(value_of(value, :tracker_identity)),
         {:ok, opaque_values} <- attribution_opaques(value) do
      {:ok, Map.put(opaque_values, :tracker_identity, tracker_identity)}
    end
  end

  def attribution(_value), do: {:error, :invalid_attribution}

  defp attribution_opaques(value) do
    Enum.reduce_while(@attribution_fields -- [:tracker_identity], {:ok, %{}}, fn key, {:ok, acc} ->
      case optional_opaque_result(value_of(value, key), :invalid_attribution) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  @spec optional_opaque_result(term(), atom()) :: {:ok, String.t() | nil} | {:error, atom()}
  def optional_opaque_result(nil, _error), do: {:ok, nil}
  def optional_opaque_result(value, error), do: opaque(value, error)

  @doc false
  @spec optional_ledger_identifier(term()) :: {:ok, String.t() | nil} | {:error, atom()}
  def optional_ledger_identifier(nil), do: {:ok, nil}

  def optional_ledger_identifier(value) do
    case ledger_safe_identifier(value) do
      nil -> {:error, :invalid_upstream_provider}
      identifier -> {:ok, identifier}
    end
  end

  @doc false
  @spec ledger_safe_identifier(term()) :: String.t() | nil
  def ledger_safe_identifier(value)
      when is_binary(value) and byte_size(value) in 1..@max_opaque_bytes do
    if String.valid?(value) and String.match?(value, @ledger_identifier) and
         not String.match?(value, @sensitive_identifier),
       do: value
  end

  def ledger_safe_identifier(_value), do: nil

  @doc false
  @spec context_tier(term(), atom()) :: {:ok, atom() | nil} | {:error, atom()}
  # Occurrence-time price-partition context is optional when an adapter cannot
  # determine it. When present it is checked against the owning provider's
  # registry descriptor, so a new provider does not need a validator clause.
  def context_tier(nil, _provider), do: {:ok, nil}
  def context_tier(value, provider), do: provider_dimension(value, provider, :context_tier, :invalid_context_tier)

  @doc false
  @spec cache_write_duration(term(), atom()) :: {:ok, atom() | nil} | {:error, atom()}
  def cache_write_duration(nil, _provider), do: {:ok, nil}
  def cache_write_duration(value, provider), do: provider_dimension(value, provider, :cache_write_duration, :invalid_cache_write_duration)

  defp provider_dimension(value, provider, dimension, error) do
    with %{dimensions: dimensions} <- CodingAgent.provider_pricing(provider),
         %{allowed: allowed} <- Map.get(dimensions, dimension),
         normalized when not is_nil(normalized) <- normalize_atom(value, allowed) do
      {:ok, normalized}
    else
      _ -> {:error, error}
    end
  end

  defp tracker_identity(nil), do: {:ok, nil}

  defp tracker_identity(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity) and
         (is_nil(identity.database_id) or (is_integer(identity.database_id) and identity.database_id > 0)),
       do: {:ok, identity},
       else: {:error, :unjoinable_tracker_identity}
  end

  defp tracker_identity(_identity), do: {:error, :invalid_attribution}

  @doc false
  @spec account_generation(term(), atom(), atom()) :: {:ok, map()} | {:error, atom()}
  def account_generation(value, provider, backend) when is_map(value) do
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

  def account_generation(_value, _provider, _backend), do: {:error, :invalid_account_generation_context}

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

  @doc false
  @spec distinct_epoch(map(), String.t()) :: :ok | {:error, atom()}
  def distinct_epoch(%{generation: generation}, generation) when is_binary(generation),
    do: {:error, :account_generation_used_as_counter_epoch}

  def distinct_epoch(_account_generation, _counter_epoch), do: :ok

  @doc false
  @spec tokens(term()) :: {:ok, map()} | {:error, atom()}
  def tokens(value) when is_map(value) do
    with :ok <- only_keys?(value, @token_fields, :invalid_tokens) do
      normalize_tokens(value)
    end
  end

  def tokens(_value), do: {:error, :invalid_tokens}

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

  @doc false
  @spec measurement_present(map(), term()) :: :ok | {:error, atom()}
  def measurement_present(tokens, cost) do
    if Enum.any?(tokens, fn {_dimension, value} -> is_integer(value) end) or not is_nil(cost),
      do: :ok,
      else: {:error, :missing_usage_measurement}
  end

  @doc false
  @spec coverage_reasons(term(), DateTime.t() | nil, map()) :: {:ok, [atom()]} | {:error, atom()}
  def coverage_reasons(value, occurred_at, account_generation) when is_list(value) do
    with {:ok, explicit} <- enum_list(value, @coverage_reasons, :invalid_coverage_reason) do
      implicit =
        []
        |> maybe_reason(is_nil(occurred_at), :missing_trusted_occurrence_time)
        |> maybe_reason(is_nil(account_generation.generation), :unknown_account_generation)

      {:ok, Enum.uniq(explicit ++ implicit)}
    end
  end

  def coverage_reasons(_value, _occurred_at, _account_generation), do: {:error, :invalid_coverage_reason}

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

  @doc false
  @spec only_keys?(map(), [atom()], atom()) :: :ok | {:error, atom()}
  def only_keys?(map, allowed, error) do
    allowed_strings = Enum.map(allowed, &Atom.to_string/1)

    if Enum.all?(Map.keys(map), fn key -> key in allowed or key in allowed_strings end),
      do: :ok,
      else: {:error, error}
  end

  @doc false
  @spec value_of(map(), atom(), term()) :: term()
  def value_of(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @doc false
  @spec token_fields() :: [atom()]
  def token_fields, do: @token_fields

  defp date(nil), do: nil
  defp date(value), do: Date.to_iso8601(value)
end
