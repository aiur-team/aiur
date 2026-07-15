defmodule Aiur.UsageEnvelope.ExactMoney do
  @moduledoc """
  Exact provider-reported money preserved without a float conversion.

  Values are serialized in major currency units. Integer minor-unit input is
  accepted only when its scale is explicit, so a later consumer never has to
  guess whether an integer represents cents, mills, or whole units.
  """

  @max_amount_bytes 128
  @max_scalar_bytes 128
  @currency ~r/^[A-Z]{3}$/
  @kinds [:delta, :absolute]
  @scopes [:request, :turn, :thread, :session]
  @coverages [:full, :partial, :unknown]
  @representations [:major, :minor]
  @reasons [:missing, :untrusted, :imprecise, :unsupported, :unavailable]
  @fields [
    :amount,
    :currency,
    :unit,
    :source_representation,
    :minor_unit_scale,
    :measurement_kind,
    :counter_scope,
    :source,
    :source_version,
    :coverage,
    :unknown_reason
  ]

  @enforce_keys [
    :amount,
    :currency,
    :source_representation,
    :measurement_kind,
    :counter_scope,
    :source,
    :source_version,
    :coverage
  ]
  defstruct [
    :amount,
    :currency,
    :source_representation,
    :minor_unit_scale,
    :measurement_kind,
    :counter_scope,
    :source,
    :source_version,
    :coverage,
    :unknown_reason
  ]

  @type t :: %__MODULE__{
          amount: Decimal.t(),
          currency: String.t(),
          source_representation: :major | :minor,
          minor_unit_scale: non_neg_integer() | nil,
          measurement_kind: :delta | :absolute,
          counter_scope: :request | :turn | :thread | :session,
          source: String.t(),
          source_version: String.t(),
          coverage: :full | :partial | :unknown,
          unknown_reason: atom() | nil
        }

  @spec decode(nil | map()) :: {:ok, nil | t()} | {:error, atom()}
  def decode(nil), do: {:ok, nil}

  def decode(value) when is_map(value) do
    with :ok <- only_keys(value),
         {:ok, currency} <- currency(value_of(value, :currency)),
         {:ok, amount_unit} <- enum(value_of(value, :unit), @representations, :invalid_money_unit),
         {:ok, source_representation} <-
           enum(
             value_of(value, :source_representation, amount_unit),
             @representations,
             :invalid_money_source_representation
           ),
         {:ok, amount, decoded_scale} <-
           amount(value_of(value, :amount), amount_unit, value_of(value, :minor_unit_scale)),
         {:ok, scale} <-
           source_scale(source_representation, value_of(value, :minor_unit_scale), decoded_scale),
         {:ok, measurement_kind} <- enum(value_of(value, :measurement_kind), @kinds, :invalid_money_measurement_kind),
         {:ok, counter_scope} <- enum(value_of(value, :counter_scope), @scopes, :invalid_money_counter_scope),
         {:ok, source} <- opaque(value_of(value, :source)),
         {:ok, source_version} <- opaque(value_of(value, :source_version)),
         {:ok, coverage} <- enum(value_of(value, :coverage, :full), @coverages, :invalid_money_coverage),
         {:ok, unknown_reason} <- reason(value_of(value, :unknown_reason)),
         :ok <- valid_coverage(coverage, unknown_reason) do
      {:ok,
       %__MODULE__{
         amount: amount,
         currency: currency,
         source_representation: source_representation,
         minor_unit_scale: scale,
         measurement_kind: measurement_kind,
         counter_scope: counter_scope,
         source: source,
         source_version: source_version,
         coverage: coverage,
         unknown_reason: unknown_reason
       }}
    end
  end

  def decode(_value), do: {:error, :invalid_money}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = money) do
    %{
      "amount" => Decimal.to_string(money.amount, :normal),
      "currency" => money.currency,
      "unit" => "major",
      "source_representation" => Atom.to_string(money.source_representation),
      "minor_unit_scale" => money.minor_unit_scale,
      "measurement_kind" => Atom.to_string(money.measurement_kind),
      "counter_scope" => Atom.to_string(money.counter_scope),
      "source" => money.source,
      "source_version" => money.source_version,
      "coverage" => Atom.to_string(money.coverage),
      "unknown_reason" => string_or_nil(money.unknown_reason)
    }
  end

  defp amount(value, :major, _scale) do
    with {:ok, amount} <- exact_decimal(value), do: {:ok, amount, nil}
  end

  defp amount(_value, :minor, nil), do: {:error, :missing_minor_unit_scale}

  defp amount(value, :minor, scale) when is_integer(value) and value >= 0 do
    with :ok <- bounded_integer(value),
         {:ok, scale} <- minor_unit_scale(scale) do
      {:ok, minor_to_major(value, scale), scale}
    end
  end

  defp amount(value, :minor, _scale) when is_float(value), do: {:error, :float_not_allowed}
  defp amount(_value, :minor, _scale), do: {:error, :invalid_minor_unit_amount}

  defp source_scale(:major, nil, _decoded_scale), do: {:ok, nil}
  defp source_scale(:major, _scale, _decoded_scale), do: {:error, :unexpected_minor_unit_scale}
  defp source_scale(:minor, nil, _decoded_scale), do: {:error, :missing_minor_unit_scale}

  defp source_scale(:minor, scale, _decoded_scale) do
    minor_unit_scale(scale)
  end

  defp exact_decimal(value) when is_float(value), do: {:error, :float_not_allowed}

  defp exact_decimal(%Decimal{} = value) do
    cond do
      Decimal.nan?(value) or Decimal.inf?(value) or Decimal.negative?(value) ->
        {:error, :invalid_money}

      byte_size(Decimal.to_string(value, :normal)) > @max_amount_bytes ->
        {:error, :money_too_large}

      true ->
        {:ok, value}
    end
  end

  defp exact_decimal(value) when is_integer(value) and value >= 0 do
    with :ok <- bounded_integer(value), do: {:ok, Decimal.new(value)}
  end

  defp exact_decimal(value) when is_binary(value) and byte_size(value) in 1..@max_amount_bytes do
    if Regex.match?(~r/^\d+(?:\.\d+)?$/, value) do
      {:ok, Decimal.new(value)}
    else
      {:error, :invalid_money}
    end
  end

  defp exact_decimal(value) when is_binary(value) and byte_size(value) > @max_amount_bytes,
    do: {:error, :money_too_large}

  defp exact_decimal(_value), do: {:error, :invalid_money}

  defp bounded_integer(value) do
    if value |> Integer.to_string() |> byte_size() <= @max_amount_bytes,
      do: :ok,
      else: {:error, :money_too_large}
  end

  defp minor_unit_scale(value) when is_integer(value) and value in 0..9, do: {:ok, value}
  defp minor_unit_scale(_value), do: {:error, :invalid_minor_unit_scale}

  defp minor_to_major(value, 0), do: Decimal.new(value)

  defp minor_to_major(value, scale) do
    padded = value |> Integer.to_string() |> String.pad_leading(scale + 1, "0")
    split_at = byte_size(padded) - scale
    Decimal.new(String.slice(padded, 0, split_at) <> "." <> String.slice(padded, split_at, scale))
  end

  defp currency(value) when is_binary(value) do
    if Regex.match?(@currency, value), do: {:ok, value}, else: {:error, :invalid_currency}
  end

  defp currency(_value), do: {:error, :invalid_currency}

  defp opaque(value) when is_binary(value) and byte_size(value) in 1..@max_scalar_bytes do
    if value == String.trim(value), do: {:ok, value}, else: {:error, :invalid_money}
  end

  defp opaque(_value), do: {:error, :invalid_money}

  defp reason(nil), do: {:ok, nil}
  defp reason(value), do: enum(value, @reasons, :invalid_money_unknown_reason)

  defp valid_coverage(:unknown, reason) when not is_nil(reason), do: :ok
  defp valid_coverage(:unknown, nil), do: {:error, :missing_money_unknown_reason}
  defp valid_coverage(_coverage, nil), do: :ok
  defp valid_coverage(_coverage, _reason), do: {:error, :unexpected_money_unknown_reason}

  defp only_keys(value) do
    allowed = Enum.map(@fields, &Atom.to_string/1)

    if Enum.all?(Map.keys(value), &(&1 in @fields or &1 in allowed)),
      do: :ok,
      else: {:error, :invalid_money_field}
  end

  defp enum(value, allowed, error) do
    case normalize_atom(value, allowed) do
      nil -> {:error, error}
      atom -> {:ok, atom}
    end
  end

  defp normalize_atom(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp normalize_atom(value, allowed) when is_binary(value) do
    Enum.find(allowed, fn atom -> Atom.to_string(atom) == value end)
  end

  defp normalize_atom(_value, _allowed), do: nil

  defp value_of(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp string_or_nil(nil), do: nil
  defp string_or_nil(value), do: Atom.to_string(value)
end
