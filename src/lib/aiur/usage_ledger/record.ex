defmodule Aiur.UsageLedger.Record do
  @moduledoc false

  alias Aiur.UsageEnvelope
  alias Aiur.UsageEnvelope.{Codec, ExactMoney}

  @version 1
  # Raw counters, source sequences, ledger positions, and provider database IDs
  # share one explicit unsigned-64-bit storage bound. Comparing against it is
  # cheap even for a hostile bignum and happens before any JSON encoding.
  @max_integer 18_446_744_073_709_551_615
  @token_fields UsageEnvelope.token_dimensions() ++ [:provider_reported_total]
  @record_fields ["schema_version", "position", "envelope", "delta"]
  @delta_fields ["tokens", "cost", "source_version", "relationship_revision", "coverage_reasons"]

  defstruct [:position, :envelope, :delta]

  @type t :: %__MODULE__{position: pos_integer(), envelope: UsageEnvelope.t(), delta: map()}

  @spec new(pos_integer(), UsageEnvelope.t(), map()) :: {:ok, t()} | {:error, atom()}
  def new(position, %UsageEnvelope{} = envelope, delta) when is_map(delta) do
    with :ok <- admit(envelope),
         true <- bounded_integer?(position) and position > 0,
         {:ok, decoded_delta} <- decode_delta(encode_delta(delta), envelope) do
      {:ok, %__MODULE__{position: position, envelope: envelope, delta: decoded_delta}}
    else
      false -> {:error, :invalid_ledger_record}
      {:error, _reason} = error -> error
    end
  end

  def new(_position, _envelope, _delta), do: {:error, :invalid_ledger_record}

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = record) do
    %{
      "schema_version" => @version,
      "position" => record.position,
      "envelope" => Codec.encode(record.envelope),
      "delta" => encode_delta(record.delta)
    }
  end

  @spec matches_delta?(t(), map()) :: boolean()
  def matches_delta?(%__MODULE__{} = record, delta) when is_map(delta) do
    encode_delta(record.delta) == encode_delta(delta)
  end

  @spec decode(map()) :: {:ok, t()} | {:error, atom()}
  def decode(value) when is_map(value) do
    with :ok <- only_keys(value, @record_fields, :invalid_ledger_record),
         @version <- value_of(value, :schema_version),
         position when is_integer(position) and position > 0 <- value_of(value, :position),
         true <- bounded_integer?(position),
         {:ok, envelope} <- Codec.decode(value_of(value, :envelope)),
         :ok <- admit(envelope),
         {:ok, delta} <- decode_delta(value_of(value, :delta), envelope) do
      {:ok, %__MODULE__{position: position, envelope: envelope, delta: delta}}
    else
      {:error, :invalid_ledger_delta} -> {:error, :invalid_ledger_delta}
      value when is_integer(value) -> {:error, :unsupported_ledger_record_version}
      _ -> {:error, :invalid_ledger_record}
    end
  end

  def decode(_value), do: {:error, :invalid_ledger_record}

  @spec admit(UsageEnvelope.t()) :: :ok | {:error, :content_rejected | :numeric_value_out_of_bounds}
  def admit(%UsageEnvelope{} = envelope) do
    encoded = Codec.encode(envelope)

    cond do
      not bounded_numbers?(encoded) -> {:error, :numeric_value_out_of_bounds}
      safe_value?(encoded) -> :ok
      true -> {:error, :content_rejected}
    end
  end

  @doc false
  @spec bounded_integer?(term()) :: boolean()
  def bounded_integer?(value), do: is_integer(value) and value >= 0 and value <= @max_integer

  defp encode_delta(delta) do
    %{
      "tokens" => Map.new(@token_fields, fn field -> {Atom.to_string(field), Map.get(delta.tokens, field)} end),
      "cost" => if(delta.cost, do: ExactMoney.to_map(delta.cost)),
      "source_version" => delta.source_version,
      "relationship_revision" => delta.relationship_revision,
      "coverage_reasons" => Enum.map(delta.coverage_reasons, &Atom.to_string/1)
    }
  end

  defp decode_delta(value, envelope) when is_map(value) do
    with :ok <- only_keys(value, @delta_fields, :invalid_ledger_delta),
         {:ok, tokens} <- decode_tokens(value_of(value, :tokens)),
         {:ok, cost} <- ExactMoney.decode(value_of(value, :cost)),
         true <- value_of(value, :source_version) == envelope.source_version,
         true <- value_of(value, :relationship_revision) == envelope.relationship_revision,
         {:ok, coverage_reasons} <- coverage_reasons(value_of(value, :coverage_reasons), envelope) do
      {:ok,
       %{
         tokens: tokens,
         cost: cost,
         source_version: envelope.source_version,
         relationship_revision: envelope.relationship_revision,
         coverage_reasons: coverage_reasons
       }}
    else
      _ -> {:error, :invalid_ledger_delta}
    end
  end

  defp decode_delta(_value, _envelope), do: {:error, :invalid_ledger_delta}

  defp decode_tokens(value) when is_map(value) do
    expected = Enum.map(@token_fields, &Atom.to_string/1)

    with :ok <- only_keys(value, expected, :invalid_ledger_delta),
         true <- Map.keys(stringify_keys(value)) |> Enum.sort() == Enum.sort(expected) do
      tokens = Map.new(@token_fields, fn field -> {field, value_of(value, field)} end)
      validate_tokens(tokens)
    else
      _ -> {:error, :invalid_ledger_delta}
    end
  end

  defp decode_tokens(_value), do: {:error, :invalid_ledger_delta}

  defp validate_tokens(tokens) do
    if Enum.all?(tokens, fn {_field, amount} -> is_nil(amount) or bounded_integer?(amount) end),
      do: {:ok, tokens},
      else: {:error, :invalid_ledger_delta}
  end

  defp bounded_numbers?(value) when is_integer(value), do: bounded_integer?(value)
  defp bounded_numbers?(value) when is_float(value), do: false
  defp bounded_numbers?(value) when is_binary(value) or is_nil(value) or is_boolean(value), do: true
  defp bounded_numbers?(value) when is_list(value), do: Enum.all?(value, &bounded_numbers?/1)

  defp bounded_numbers?(value) when is_map(value),
    do: Enum.all?(value, fn {key, nested} -> bounded_numbers?(key) and bounded_numbers?(nested) end)

  defp bounded_numbers?(_value), do: false

  defp coverage_reasons(values, envelope) when is_list(values) do
    expected = Enum.map(envelope.coverage_reasons, &Atom.to_string/1)

    if values == expected, do: {:ok, envelope.coverage_reasons}, else: {:error, :invalid_ledger_delta}
  end

  defp coverage_reasons(_values, _envelope), do: {:error, :invalid_ledger_delta}

  defp safe_value?(value) when is_binary(value) do
    String.valid?(value) and String.match?(value, ~r/\A[A-Za-z0-9._:-]+\z/) and
      not String.match?(value, ~r/(?:sk[-_][A-Za-z0-9]|ghp_|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|secret|password|credential|bearer|authorization|api[-_]?key|prompt)/i)
  end

  defp safe_value?(value) when is_integer(value) or is_nil(value) or is_boolean(value), do: true
  defp safe_value?(value) when is_list(value), do: Enum.all?(value, &safe_value?/1)
  defp safe_value?(value) when is_map(value), do: Enum.all?(value, fn {key, nested} -> safe_value?(key) and safe_value?(nested) end)
  defp safe_value?(_value), do: false

  defp only_keys(value, expected, error) do
    if Map.keys(value) |> Enum.map(&to_string/1) |> Enum.all?(&(&1 in expected)), do: :ok, else: {:error, error}
  end

  defp stringify_keys(value), do: Map.new(value, fn {key, nested} -> {to_string(key), nested} end)
  defp value_of(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
