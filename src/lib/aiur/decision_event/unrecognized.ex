defmodule Aiur.DecisionEvent.Unrecognized do
  @moduledoc """
  One well-formed audit record whose `event_type` this binary does not know.

  A newer binary writing a newer event type is a version skew, not damage, and
  the two must not be confused: treating skew as corruption wedges the
  DecisionStore into read-only permanently, which takes away the operator's
  ability to answer any Command at all — a far worse failure than the missing
  feature. So an unrecognized type is retained opaquely here, skipped for
  projection, and the store stays writable.

  Retention is what makes this safe to roll back through. The record keeps the
  exact decoded line in `raw`, and the NDJSON stream is append-only, so an
  older binary reading a newer log neither drops nor rewrites the line: roll
  forward again and the newer binary projects it in full.

  What is deliberately *not* validated: `data` beyond being a map, and
  `content_hash` beyond being present and non-empty. This binary cannot
  recompute a hash over a payload shape it has never seen, so an unrecognized
  record carries no tamper evidence — it is retained and ignored, never
  trusted. Everything this binary *can* check, it still checks: the envelope
  must be complete and well-typed, or the record is corruption and stays
  fail-closed.
  """

  @enforce_keys [:event_type, :event_id, :decision_id, :decision_version, :occurred_at, :raw]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_type: String.t(),
          event_id: pos_integer() | String.t(),
          decision_id: String.t(),
          decision_version: pos_integer(),
          occurred_at: DateTime.t(),
          raw: map()
        }

  @doc """
  Decodes the shared envelope of a record whose type is unknown here.

  `schema_version` is only required to be a positive integer rather than one of
  this binary's known versions: a record we already admit we cannot interpret
  is exactly the case where a future schema version must not be fatal. A known
  event type with an unsupported schema version keeps failing closed, in
  `Aiur.DecisionEvent`.
  """
  @spec decode(map(), String.t()) :: {:ok, t()} | {:error, term()}
  def decode(raw, event_type) when is_map(raw) and is_binary(event_type) do
    with :ok <- positive_integer(Map.get(raw, "schema_version"), :schema_version),
         {:ok, event_id} <- event_id(Map.get(raw, "event_id")),
         {:ok, decision_id} <- non_empty_string(Map.get(raw, "decision_id"), :decision_id),
         {:ok, decision_version} <- version(Map.get(raw, "decision_version")),
         {:ok, _run_id} <- non_empty_string(Map.get(raw, "run_id"), :run_id),
         {:ok, occurred_at} <- timestamp(Map.get(raw, "occurred_at")),
         :ok <- map_field(Map.get(raw, "data")),
         {:ok, _hash} <- non_empty_string(Map.get(raw, "content_hash"), :content_hash) do
      {:ok,
       %__MODULE__{
         event_type: event_type,
         event_id: event_id,
         decision_id: decision_id,
         decision_version: decision_version,
         occurred_at: occurred_at,
         raw: raw
       }}
    end
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: {:error, {field, :invalid}}

  defp event_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp event_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp event_id(_other), do: {:error, {:event_id, :missing_or_invalid}}

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp non_empty_string(_value, field), do: {:error, {field, :missing_or_invalid}}

  defp version(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp version(_other), do: {:error, {:decision_version, :invalid}}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:occurred_at, :invalid}}
    end
  end

  defp timestamp(_other), do: {:error, {:occurred_at, :invalid}}

  defp map_field(value) when is_map(value), do: :ok
  defp map_field(_other), do: {:error, {:data, :invalid}}
end
