defmodule Aiur.DecisionAnswer do
  @moduledoc """
  Immutable, validated operator answer to one version of a Decision.

  The caller supplies an idempotency key, but the canonical `action_id`
  is derived under the Decision's scope. This prevents the same token on
  two Decisions from colliding while making retries of one submission
  deterministic. Acceptance time is provenance and is deliberately not
  part of `content_hash`, so an identical retry compares equal.
  """

  alias Aiur.{DecisionValidation, SecretRedactor}

  @identity_max 200
  @response_max 4_000
  @rationale_max 4_000
  @actor_kinds [:operator, :agent, :supervisor, :system]

  @type actor :: %{kind: :operator | :agent | :supervisor | :system, id: String.t() | nil}

  @type t :: %__MODULE__{
          action_id: String.t(),
          decision_id: String.t(),
          decision_version: pos_integer(),
          idempotency_key: String.t(),
          selected_option_id: String.t() | nil,
          custom_response: String.t() | nil,
          rationale: String.t() | nil,
          actor: actor(),
          accepted_at: DateTime.t(),
          content_hash: String.t()
        }

  @enforce_keys [
    :action_id,
    :decision_id,
    :decision_version,
    :idempotency_key,
    :actor,
    :accepted_at,
    :content_hash
  ]
  defstruct @enforce_keys ++ [selected_option_id: nil, custom_response: nil, rationale: nil]

  @doc "Normalize an untrusted answer payload using trusted Decision and actor context."
  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, {:answer_invalid, term()}}
  def normalize(payload, opts) when is_map(payload) and is_list(opts) do
    decision_id = Keyword.fetch!(opts, :decision_id)
    decision_version = Keyword.fetch!(opts, :decision_version)
    options = Keyword.get(opts, :options, [])
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, idempotency_key} <- required_string(payload, :idempotency_key, @identity_max),
         {:ok, expected_version} <- required_version(payload, :expected_version),
         :ok <- compare_version(expected_version, decision_version),
         {:ok, selected_option_id} <- optional_string(payload, :option_id, @identity_max),
         {:ok, custom_response} <- optional_string(payload, :custom_response, @response_max),
         :ok <- validate_response(selected_option_id, custom_response),
         :ok <- validate_option(selected_option_id, options, Keyword.get(opts, :allow_unchecked_option, false)),
         {:ok, rationale} <- optional_string(payload, :rationale, @rationale_max),
         {:ok, actor} <- normalize_actor(Keyword.fetch!(opts, :actor)),
         :ok <- validate_datetime(now, :accepted_at) do
      action_id = action_id(decision_id, idempotency_key)

      content = %{
        action_id: action_id,
        decision_id: decision_id,
        decision_version: decision_version,
        idempotency_key: idempotency_key,
        selected_option_id: selected_option_id,
        custom_response: custom_response,
        rationale: rationale,
        actor: actor
      }

      {:ok,
       struct!(__MODULE__,
         Map.merge(content, %{
           accepted_at: now,
           content_hash: DecisionValidation.content_hash(content)
         })
       )}
    else
      {:error, reason} -> {:error, {:answer_invalid, reason}}
    end
  end

  @doc "Decode and fully validate one persisted answer shape."
  @spec from_json_safe(map()) :: {:ok, t()} | {:error, term()}
  def from_json_safe(raw) when is_map(raw) do
    with {:ok, decision_id} <- persisted_string(raw, "decision_id"),
         {:ok, decision_version} <- persisted_version(raw, "decision_version"),
         {:ok, actor} <- persisted_map(raw, "actor"),
         {:ok, accepted_at} <- persisted_timestamp(raw, "accepted_at"),
         {:ok, persisted_action_id} <- persisted_string(raw, "action_id"),
         {:ok, persisted_hash} <- persisted_string(raw, "content_hash"),
         {:ok, answer} <-
           normalize(
             %{
               "idempotency_key" => Map.get(raw, "idempotency_key"),
               "expected_version" => decision_version,
               "option_id" => Map.get(raw, "selected_option_id"),
               "custom_response" => Map.get(raw, "custom_response"),
               "rationale" => Map.get(raw, "rationale")
             },
             decision_id: decision_id,
             decision_version: decision_version,
             actor: actor,
             now: accepted_at,
             allow_unchecked_option: true
           ),
         :ok <- compare_persisted(answer.action_id, persisted_action_id, :action_id_mismatch),
         :ok <- compare_persisted(answer.content_hash, persisted_hash, :answer_content_hash_mismatch) do
      {:ok, answer}
    end
  end

  def from_json_safe(_other), do: {:error, :answer_not_a_map}

  @doc "JSON-safe durable representation."
  @spec to_json_safe(t()) :: map()
  def to_json_safe(%__MODULE__{} = answer) do
    %{
      "action_id" => answer.action_id,
      "decision_id" => answer.decision_id,
      "decision_version" => answer.decision_version,
      "idempotency_key" => answer.idempotency_key,
      "selected_option_id" => answer.selected_option_id,
      "custom_response" => answer.custom_response,
      "rationale" => answer.rationale,
      "actor" => %{"kind" => Atom.to_string(answer.actor.kind), "id" => answer.actor.id},
      "accepted_at" => DateTime.to_iso8601(answer.accepted_at),
      "content_hash" => answer.content_hash
    }
  end

  @doc "Canonical Decision-scoped identity for one logical answer action."
  @spec action_id(String.t(), String.t()) :: String.t()
  def action_id(decision_id, idempotency_key) when is_binary(decision_id) and is_binary(idempotency_key) do
    digest =
      "#{decision_id}::#{idempotency_key}"
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 20)

    "act_" <> digest
  end

  defp compare_version(version, version), do: :ok
  defp compare_version(expected, current), do: {:error, {:stale_version, expected, current}}

  defp validate_response(nil, nil), do: {:error, {:response, :missing}}
  defp validate_response(option_id, custom) when is_binary(option_id) and is_binary(custom), do: {:error, {:response, :ambiguous}}
  defp validate_response(_option_id, _custom), do: :ok

  defp validate_option(nil, _options, _allow_unchecked?), do: :ok
  defp validate_option(_option_id, _options, true), do: :ok

  defp validate_option(option_id, options, false) do
    if Enum.any?(options, &(option_id(&1) == option_id)) do
      :ok
    else
      {:error, {:option_id, :unknown}}
    end
  end

  defp option_id(option) when is_map(option), do: Map.get(option, :id, Map.get(option, "id"))

  defp normalize_actor(actor) when is_map(actor) do
    kind = Map.get(actor, :kind, Map.get(actor, "kind"))
    id = Map.get(actor, :id, Map.get(actor, "id"))

    with {:ok, kind} <- actor_kind(kind),
         {:ok, id} <- bounded_optional(id, @identity_max, :actor_id) do
      {:ok, %{kind: kind, id: id}}
    end
  end

  defp normalize_actor(_other), do: {:error, {:actor, :invalid_type}}

  defp actor_kind(kind) when kind in @actor_kinds, do: {:ok, kind}

  defp actor_kind(kind) when is_binary(kind) do
    case Enum.find(@actor_kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, {:actor_kind, :invalid}}
      atom -> {:ok, atom}
    end
  end

  defp actor_kind(_other), do: {:error, {:actor_kind, :invalid}}

  defp required_string(payload, key, max) do
    case get(payload, key) do
      value when is_binary(value) -> bounded_required(value, max, key)
      nil -> {:error, {key, :missing}}
      _other -> {:error, {key, :invalid_type}}
    end
  end

  defp optional_string(payload, key, max), do: bounded_optional(get(payload, key), max, key)

  defp bounded_required(value, max, field) do
    case normalize_string(value, max, field) do
      {:ok, nil} -> {:error, {field, :too_short}}
      other -> other
    end
  end

  defp bounded_optional(nil, _max, _field), do: {:ok, nil}
  defp bounded_optional("", _max, _field), do: {:ok, nil}

  defp bounded_optional(value, max, field) when is_binary(value), do: normalize_string(value, max, field)
  defp bounded_optional(_value, _max, field), do: {:error, {field, :invalid_type}}

  defp normalize_string(value, max, field) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > max -> {:error, {field, :too_long}}
      unsafe_control_chars?(trimmed) -> {:error, {field, :unsafe_characters}}
      true -> {:ok, SecretRedactor.redact(trimmed)}
    end
  end

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 and codepoint not in [?\n, ?\t, ?\r] end)
  end

  defp required_version(payload, key) do
    case get(payload, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      nil -> {:error, {key, :missing}}
      _other -> {:error, {key, :invalid_type}}
    end
  end

  defp validate_datetime(%DateTime{}, _field), do: :ok
  defp validate_datetime(_other, field), do: {:error, {field, :invalid_type}}

  defp compare_persisted(value, value, _reason), do: :ok
  defp compare_persisted(_actual, _persisted, reason), do: {:error, reason}

  defp persisted_string(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {String.to_atom(key), :missing_or_invalid}}
    end
  end

  defp persisted_version(raw, key) do
    case Map.get(raw, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {String.to_atom(key), :missing_or_invalid}}
    end
  end

  defp persisted_map(raw, key) do
    case Map.get(raw, key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {String.to_atom(key), :missing_or_invalid}}
    end
  end

  defp persisted_timestamp(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          {:error, _reason} -> {:error, {String.to_atom(key), :invalid_timestamp}}
        end

      _other ->
        {:error, {String.to_atom(key), :missing_or_invalid}}
    end
  end

  defp get(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
