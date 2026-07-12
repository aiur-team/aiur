defmodule Aiur.DecisionProjection do
  @moduledoc """
  Pure reducer over the canonical Decision audit stream. Each accepted
  line in `decisions.ndjson` is one complete `Aiur.Decision` snapshot at
  its version; the reducer groups by `decision_id`, keeps every version
  as append-only history, and treats the highest version per
  `decision_id` as current.

  `decode_record/1` is `Aiur.DecisionLog.replay/2`'s per-line validator.
  It re-runs the persisted content through `Aiur.DecisionValidation`'s
  own ingress pipeline — the same bounds, enum, and artifact-safety
  checks used when the request was first accepted — rather than a
  second, drift-prone reimplementation. It then recomputes
  `content_hash` from that freshly-normalized content and compares it to
  the persisted `content_hash`: a mismatch means the record decodes as
  valid JSON but its content has changed since it was written — bit-rot
  or tampering within the local single-writer trust boundary — and is
  rejected exactly like a record that fails to parse.
  """

  alias Aiur.{Decision, DecisionValidation}

  @doc """
  Decodes and fully re-validates one persisted record. Returns the
  reconstructed `Aiur.Decision` or an error — never trusts JSON-decode
  success alone.
  """
  @spec decode_record(map()) :: {:ok, Decision.t()} | {:error, term()}
  def decode_record(raw) when is_map(raw) do
    with {:ok, ticket} <- fetch_map(raw, "ticket", :ticket),
         {:ok, source} <- fetch_map(raw, "source", :source),
         {:ok, version} <- fetch_pos_integer(raw, "version", :version),
         {:ok, persisted_decision_id} <- fetch_string(raw, "decision_id", :decision_id),
         {:ok, persisted_content_hash} <- fetch_string(raw, "content_hash", :content_hash),
         {:ok, created_at} <- fetch_timestamp(raw, "created_at", :created_at) do
      replay_payload = Map.put(raw, "created_at", Map.get(raw, "source_created_at"))

      case DecisionValidation.normalize(replay_payload,
             ticket: ticket,
             source: source,
             now: created_at,
             legacy_attention: Map.get(raw, "legacy_attention")
           ) do
        {:ok, decision} -> verify_content_hash(decision, persisted_decision_id, version, persisted_content_hash)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def decode_record(_other), do: {:error, :not_a_map}

  defp verify_content_hash(decision, persisted_decision_id, version, persisted_content_hash) do
    if decision.content_hash == persisted_content_hash do
      {:ok, %{decision | decision_id: persisted_decision_id, version: version}}
    else
      {:error, :content_hash_mismatch}
    end
  end

  @doc """
  Folds an ordered list of validated `Aiur.Decision` records into
  current state (highest version per `decision_id`) plus per-
  `decision_id` append-only history.
  """
  @spec reduce([Decision.t()]) :: %{
          current: %{String.t() => Decision.t()},
          history: %{String.t() => [Decision.t()]}
        }
  def reduce(decisions) when is_list(decisions) do
    Enum.reduce(decisions, %{current: %{}, history: %{}}, fn decision, acc ->
      %{
        current: maybe_replace_current(acc.current, decision),
        history: Map.update(acc.history, decision.decision_id, [decision], &(&1 ++ [decision]))
      }
    end)
  end

  defp maybe_replace_current(current, decision) do
    case Map.get(current, decision.decision_id) do
      nil ->
        Map.put(current, decision.decision_id, decision)

      %Decision{version: existing_version} when decision.version >= existing_version ->
        Map.put(current, decision.decision_id, decision)

      _older ->
        current
    end
  end

  @doc "JSON-safe shape for one Decision, used by both the log line and the current-state projection."
  @spec to_json_safe(Decision.t()) :: map()
  def to_json_safe(%Decision{} = decision) do
    %{
      "schema_version" => decision.schema_version,
      "decision_id" => decision.decision_id,
      "source_id" => decision.source_id,
      "version" => decision.version,
      "ticket" => stringify_keys(decision.ticket),
      "source" => stringify_keys(decision.source),
      "kind" => decision.kind,
      "authority" => Atom.to_string(decision.authority),
      "urgency" => Atom.to_string(decision.urgency),
      "blocking" => decision.blocking,
      "reversibility" => Atom.to_string(decision.reversibility),
      "question" => decision.question,
      "context" => stringify_keys(decision.context),
      "options" => Enum.map(decision.options, &stringify_keys/1),
      "recommendation" => decision.recommendation && stringify_keys(decision.recommendation),
      "consequence_of_delay" => decision.consequence_of_delay,
      "artifacts" => Enum.map(decision.artifacts, &stringify_artifact/1),
      "created_at" => DateTime.to_iso8601(decision.created_at),
      "source_created_at" => decision.source_created_at && DateTime.to_iso8601(decision.source_created_at),
      "content_hash" => decision.content_hash
    }
    |> maybe_put_legacy_attention(decision.legacy_attention)
  end

  @doc "Normalized request-shaped content for adapter-owned enrichment merges."
  @spec to_request_payload(Decision.t()) :: map()
  def to_request_payload(%Decision{} = decision) do
    persisted = to_json_safe(decision)

    persisted
    |> Map.take([
      "source_id",
      "kind",
      "authority",
      "urgency",
      "blocking",
      "reversibility",
      "question",
      "context",
      "options",
      "recommendation",
      "consequence_of_delay",
      "artifacts"
    ])
    |> maybe_put_source_created_at(decision.source_created_at)
  end

  @doc "JSON-safe shape for the `decisions.json` current-state projection."
  @spec serialize_current(%{String.t() => Decision.t()}) :: map()
  def serialize_current(current) when is_map(current) do
    %{
      "schema_version" => Decision.schema_version(),
      "decisions" => current |> Map.values() |> Enum.map(&to_json_safe/1)
    }
  end

  defp stringify_artifact(%{kind: kind, value: value}), do: %{"kind" => Atom.to_string(kind), "value" => value}

  defp maybe_put_legacy_attention(map, nil), do: map

  defp maybe_put_legacy_attention(map, legacy_attention) do
    Map.put(map, "legacy_attention", stringify_keys(legacy_attention))
  end

  defp maybe_put_source_created_at(payload, nil), do: payload

  defp maybe_put_source_created_at(payload, source_created_at) do
    Map.put(payload, "created_at", DateTime.to_iso8601(source_created_at))
  end

  defp stringify_keys(nil), do: nil
  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp fetch_map(raw, key, field) do
    case Map.get(raw, key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  defp fetch_pos_integer(raw, key, field) do
    case Map.get(raw, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  defp fetch_string(raw, key, field) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  defp fetch_timestamp(raw, key, field) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          {:error, _reason} -> {:error, {field, :invalid_timestamp}}
        end

      _other ->
        {:error, {field, :missing_or_invalid}}
    end
  end
end
