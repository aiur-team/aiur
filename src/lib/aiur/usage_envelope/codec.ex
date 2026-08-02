defmodule Aiur.UsageEnvelope.Codec do
  @moduledoc """
  JSON-safe serialization for `Aiur.UsageEnvelope`.

  The codec is deliberately narrow: it accepts only the durable contract
  fields and rebuilds typed dates and tracker identity before validation.
  """

  alias Aiur.{TrackerIdentity, UsageEnvelope}

  @tracker_identity_fields [
    :version,
    :status,
    :kind,
    :owner,
    :repository,
    :provider_id,
    :database_id,
    :identifier,
    :reason
  ]

  @spec encode(UsageEnvelope.t()) :: map()
  def encode(%UsageEnvelope{} = envelope), do: UsageEnvelope.to_map(envelope)

  @spec decode(map()) :: {:ok, UsageEnvelope.t()} | {:error, atom()}
  def decode(record) when is_map(record) do
    with {:ok, occurred_at} <- optional_datetime(value_of(record, :occurred_at), :invalid_occurred_at),
         {:ok, ingested_at} <- datetime(value_of(record, :ingested_at), :invalid_ingested_at),
         {:ok, attribution} <- attribution(value_of(record, :attribution)),
         {:ok, envelope} <-
           record
           |> Map.put(:occurred_at, occurred_at)
           |> Map.put(:ingested_at, ingested_at)
           |> Map.put(:attribution, attribution)
           |> UsageEnvelope.new(),
         :ok <- pricing_date_matches?(value_of(record, :pricing_effective_date), envelope.pricing_effective_date) do
      {:ok, envelope}
    end
  end

  def decode(_record), do: {:error, :invalid_envelope_record}

  defp attribution(value) when is_map(value) do
    with {:ok, identity} <- tracker_identity(value_of(value, :tracker_identity)) do
      {:ok, Map.put(value, :tracker_identity, identity)}
    end
  end

  defp attribution(_value), do: {:error, :invalid_attribution}

  defp tracker_identity(nil), do: {:ok, nil}

  defp tracker_identity(value) when is_map(value) do
    with :ok <- only_keys(value, @tracker_identity_fields) do
      identity = %TrackerIdentity{
        version: value_of(value, :version),
        status: existing_atom(value_of(value, :status), [:joinable, :unjoinable]),
        kind: existing_atom(value_of(value, :kind), [:github]),
        owner: value_of(value, :owner),
        repository: value_of(value, :repository),
        provider_id: value_of(value, :provider_id),
        database_id: value_of(value, :database_id),
        identifier: value_of(value, :identifier),
        reason: value_of(value, :reason)
      }

      if TrackerIdentity.joinable?(identity),
        do: {:ok, identity},
        else: {:error, :invalid_attribution}
    end
  end

  defp tracker_identity(_value), do: {:error, :invalid_attribution}

  defp optional_datetime(nil, _error), do: {:ok, nil}
  defp optional_datetime(value, error), do: datetime(value, error)

  defp datetime(value, error) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, error}
    end
  end

  defp datetime(_value, error), do: {:error, error}

  defp pricing_date_matches?(nil, nil), do: :ok
  defp pricing_date_matches?(value, %Date{} = date) when is_binary(value), do: if(value == Date.to_iso8601(date), do: :ok, else: {:error, :invalid_pricing_effective_date})
  defp pricing_date_matches?(_value, _date), do: {:error, :invalid_pricing_effective_date}

  defp existing_atom(value, allowed) when is_atom(value), do: if(value in allowed, do: value)
  defp existing_atom(value, allowed) when is_binary(value), do: Enum.find(allowed, &(Atom.to_string(&1) == value))
  defp existing_atom(_value, _allowed), do: nil

  defp only_keys(value, allowed) do
    allowed_strings = Enum.map(allowed, &Atom.to_string/1)

    if Enum.all?(Map.keys(value), &(&1 in allowed or &1 in allowed_strings)),
      do: :ok,
      else: {:error, :invalid_attribution}
  end

  defp value_of(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
