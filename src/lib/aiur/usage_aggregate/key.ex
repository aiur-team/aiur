defmodule Aiur.UsageAggregate.Key do
  @moduledoc false

  # Derives the exact multidimensional aggregate cells for one DASH-009 replay
  # record and provides the canonical checkpoint codec for a cell. A cell is a
  # `{dims, measure}` pair; the projection accumulates one exact scalar per
  # cell. Every downstream grouping/pricing dimension survives unchanged and no
  # two token-relationship revisions ever share a cell.

  alias Aiur.{CodingAgent, TrackerIdentity, UsageEnvelope}
  alias Aiur.UsageEnvelope.ExactMoney

  # DASH-024 only observes the raw provider-reported cost carried by the ledger
  # delta; occurrence-time API-equivalent pricing is DASH-011's separate basis.
  @money_basis :provider_reported_estimate

  @providers CodingAgent.provider_families()
  @backends Enum.uniq(CodingAgent.usage_backends() ++ [:remote_control, :unknown])
  @agent_families CodingAgent.provider_families()
  @auth_modes [:api_key, :chatgpt, :unknown]
  @context_tiers [:short_context, :long_context, :not_applicable]
  @cache_write_durations [:five_minutes, :one_hour, :not_applicable]
  @token_dimensions UsageEnvelope.token_dimensions() ++ [:provider_reported_total]
  @max_opaque_bytes 512
  @max_integer 18_446_744_073_709_551_615

  @type ticket :: {:github, String.t(), String.t(), String.t()} | :unknown
  @type dims :: %{
          provider: atom(),
          run_id: String.t() | nil,
          ticket: ticket(),
          attempt_id: String.t() | nil,
          account_generation: String.t() | nil,
          backend: atom(),
          agent_family: atom(),
          resolved_model: String.t() | nil,
          auth_mode: atom(),
          context_tier: :short_context | :long_context | :not_applicable | nil,
          cache_write_duration: :five_minutes | :one_hour | :not_applicable | nil,
          pricing_date: Date.t() | nil,
          relationship_revision: String.t()
        }
  @type measure :: {:token, atom()} | {:money, atom(), String.t()}
  @type value :: non_neg_integer() | Decimal.t()
  @type cell :: {dims(), measure()}

  @doc """
  Returns the `{cell, value}` contributions of one ordered accepted delta.

  Zero and absent contributions are dropped so a partition only materializes
  once it carries usage; folding them would be a no-op against exact sums.
  """
  @spec cells(map()) :: [{cell(), value()}]
  def cells(%{envelope: %UsageEnvelope{} = envelope, delta: delta}) do
    dims = dims(envelope)
    token_cells(dims, delta) ++ money_cells(dims, delta)
  end

  @doc "Builds the canonical identity dimensions preserved for a record."
  @spec dims(UsageEnvelope.t()) :: dims()
  def dims(%UsageEnvelope{} = envelope) do
    %{
      provider: envelope.provider,
      run_id: envelope.attribution.run_id,
      ticket: ticket(envelope.attribution.tracker_identity),
      attempt_id: envelope.attribution.attempt_id,
      account_generation: envelope.account_generation.generation,
      backend: envelope.backend,
      agent_family: envelope.agent_family,
      resolved_model: envelope.resolved_model,
      auth_mode: envelope.auth_mode,
      context_tier: envelope.context_tier,
      cache_write_duration: envelope.cache_write_duration,
      pricing_date: envelope.pricing_effective_date,
      relationship_revision: envelope.relationship_revision
    }
  end

  @doc "Returns the grouping value of a dimension for the bounded query."
  @spec group_value(dims(), atom()) :: term()
  def group_value(dims, dimension), do: Map.fetch!(dims, dimension)

  @spec token_dimensions() :: [atom()]
  def token_dimensions, do: @token_dimensions

  @spec money_basis() :: atom()
  def money_basis, do: @money_basis

  defp token_cells(dims, delta) do
    Enum.flat_map(@token_dimensions, fn dimension ->
      case Map.get(delta.tokens, dimension) do
        amount when is_integer(amount) and amount > 0 -> [{{dims, {:token, dimension}}, amount}]
        _zero_or_nil -> []
      end
    end)
  end

  defp money_cells(_dims, %{cost: nil}), do: []

  defp money_cells(dims, %{cost: %ExactMoney{} = cost}) do
    if Decimal.equal?(cost.amount, 0),
      do: [],
      else: [{{dims, {:money, @money_basis, cost.currency}}, cost.amount}]
  end

  defp ticket(nil), do: :unknown
  defp ticket(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity) || :unknown

  @doc "Encodes one `{cell, value}` as a checksum-stable checkpoint map."
  @spec encode_cell({cell(), value()}) :: map()
  def encode_cell({{dims, measure}, value}) do
    %{"dims" => encode_dims(dims), "measure" => encode_measure(measure), "value" => encode_value(value)}
  end

  @doc "Decodes and revalidates one checkpoint cell, rejecting any tampering."
  @spec decode_cell(term()) :: {:ok, {cell(), value()}} | :error
  def decode_cell(%{"dims" => raw_dims, "measure" => raw_measure, "value" => raw_value}) do
    with {:ok, dims} <- decode_dims(raw_dims),
         {:ok, measure} <- decode_measure(raw_measure),
         {:ok, value} <- decode_value(measure, raw_value) do
      {:ok, {{dims, measure}, value}}
    end
  end

  def decode_cell(_other), do: :error

  defp encode_dims(dims) do
    %{
      "provider" => Atom.to_string(dims.provider),
      "run_id" => dims.run_id,
      "ticket" => encode_ticket(dims.ticket),
      "attempt_id" => dims.attempt_id,
      "account_generation" => dims.account_generation,
      "backend" => Atom.to_string(dims.backend),
      "agent_family" => Atom.to_string(dims.agent_family),
      "resolved_model" => dims.resolved_model,
      "auth_mode" => Atom.to_string(dims.auth_mode),
      "context_tier" => if(dims.context_tier, do: Atom.to_string(dims.context_tier)),
      "cache_write_duration" => if(dims.cache_write_duration, do: Atom.to_string(dims.cache_write_duration)),
      "pricing_date" => if(dims.pricing_date, do: Date.to_iso8601(dims.pricing_date)),
      "relationship_revision" => dims.relationship_revision
    }
  end

  defp encode_ticket(:unknown), do: "unknown"
  defp encode_ticket({:github, owner, repository, provider_id}), do: ["github", owner, repository, provider_id]

  defp encode_measure({:token, dimension}), do: ["token", Atom.to_string(dimension)]
  defp encode_measure({:money, basis, currency}), do: ["money", Atom.to_string(basis), currency]

  defp encode_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp encode_value(value) when is_integer(value), do: value

  defp decode_dims(raw) when is_map(raw) do
    with {:ok, provider} <- enum(raw["provider"], @providers),
         {:ok, ticket} <- decode_ticket(raw["ticket"]),
         {:ok, backend} <- enum(raw["backend"], @backends),
         {:ok, agent_family} <- enum(raw["agent_family"], @agent_families),
         {:ok, auth_mode} <- enum(raw["auth_mode"], @auth_modes),
         {:ok, run_id} <- opaque_or_nil(raw["run_id"]),
         {:ok, attempt_id} <- opaque_or_nil(raw["attempt_id"]),
         {:ok, account_generation} <- opaque_or_nil(raw["account_generation"]),
         {:ok, resolved_model} <- opaque_or_nil(raw["resolved_model"]),
         {:ok, context_tier} <- partition(raw["context_tier"], @context_tiers),
         {:ok, cache_write_duration} <- partition(raw["cache_write_duration"], @cache_write_durations),
         {:ok, pricing_date} <- decode_date(raw["pricing_date"]),
         {:ok, revision} <- opaque(raw["relationship_revision"]) do
      {:ok,
       %{
         provider: provider,
         run_id: run_id,
         ticket: ticket,
         attempt_id: attempt_id,
         account_generation: account_generation,
         backend: backend,
         agent_family: agent_family,
         resolved_model: resolved_model,
         auth_mode: auth_mode,
         context_tier: context_tier,
         cache_write_duration: cache_write_duration,
         pricing_date: pricing_date,
         relationship_revision: revision
       }}
    end
  end

  defp decode_dims(_raw), do: :error

  defp decode_ticket("unknown"), do: {:ok, :unknown}

  defp decode_ticket(["github", owner, repository, provider_id]) do
    with {:ok, owner} <- opaque(owner),
         {:ok, repository} <- opaque(repository),
         {:ok, provider_id} <- opaque(provider_id) do
      {:ok, {:github, owner, repository, provider_id}}
    end
  end

  defp decode_ticket(_other), do: :error

  defp decode_measure(["token", dimension]) do
    case enum(dimension, @token_dimensions) do
      {:ok, atom} -> {:ok, {:token, atom}}
      :error -> :error
    end
  end

  defp decode_measure(["money", basis, currency]) do
    with {:ok, basis} <- enum(basis, [@money_basis]),
         {:ok, currency} <- currency(currency) do
      {:ok, {:money, basis, currency}}
    end
  end

  defp decode_measure(_other), do: :error

  defp decode_value({:token, _dimension}, value) when is_integer(value) and value >= 0 and value <= @max_integer do
    {:ok, value}
  end

  defp decode_value({:money, _basis, _currency}, value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> if Decimal.negative?(decimal), do: :error, else: {:ok, decimal}
      _ -> :error
    end
  end

  defp decode_value(_measure, _value), do: :error

  # An absent occurrence-price partition (`nil`) is a valid cell: the adapter did
  # not retain it, so downstream pricing reports it as unknown rather than
  # guessing. A present value must be one of the exact allowed partitions.
  defp partition(nil, _allowed), do: {:ok, nil}
  defp partition(value, allowed), do: enum(value, allowed)

  defp enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp enum(_value, _allowed), do: :error

  defp opaque(value) when is_binary(value) do
    if String.valid?(value) and value != "" and byte_size(value) <= @max_opaque_bytes, do: {:ok, value}, else: :error
  end

  defp opaque(_value), do: :error

  defp opaque_or_nil(nil), do: {:ok, nil}
  defp opaque_or_nil(value), do: opaque(value)

  defp currency(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Z]{3}$/), do: {:ok, value}, else: :error
  end

  defp currency(_value), do: :error

  defp decode_date(nil), do: {:ok, nil}

  defp decode_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp decode_date(_value), do: :error
end
