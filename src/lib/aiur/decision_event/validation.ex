defmodule Aiur.DecisionEvent.Validation do
  @moduledoc false

  alias Aiur.SecretRedactor

  @spec validate_attention_slug(term()) :: :ok | {:error, term()}
  def validate_attention_slug(slug) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,63}\z/, slug),
      do: :ok,
      else: {:error, {:slug, :invalid_format}}
  end

  @spec validate_version(term()) :: :ok | {:error, term()}
  def validate_version(version) when is_integer(version) and version > 0, do: :ok
  def validate_version(_other), do: {:error, {:decision_version, :invalid}}

  @spec validate_event_id(term()) :: :ok | {:error, term()}
  def validate_event_id(value) when is_integer(value) and value > 0, do: :ok
  def validate_event_id(value) when is_binary(value) and value != "", do: :ok
  def validate_event_id(_other), do: {:error, {:event_id, :invalid}}

  @spec validate_timestamp(term()) :: :ok | {:error, term()}
  def validate_timestamp(%DateTime{}), do: :ok
  def validate_timestamp(_other), do: {:error, {:occurred_at, :invalid}}

  @spec bounded_required(term(), term(), term()) :: {:ok, term()} | {:error, term()}
  def bounded_required(value, max, field) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, {field, :missing}}
      String.length(trimmed) > max -> {:error, {field, :too_long}}
      unsafe_control_chars?(trimmed) -> {:error, {field, :unsafe_characters}}
      true -> {:ok, SecretRedactor.redact(trimmed)}
    end
  end

  def bounded_required(nil, _max, field), do: {:error, {field, :missing}}
  def bounded_required(_value, _max, field), do: {:error, {field, :invalid_type}}

  @spec bounded_optional(term(), term(), term()) :: {:ok, term()} | {:error, term()}
  def bounded_optional(nil, _max, _field), do: {:ok, nil}
  def bounded_optional("", _max, _field), do: {:ok, nil}
  def bounded_optional(value, max, field), do: bounded_required(value, max, field)

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 and codepoint not in [?\n, ?\t, ?\r] end)
  end

  @spec map_required_string(term(), term(), term()) :: {:ok, term()} | {:error, term()}
  def map_required_string(raw, key, max), do: bounded_required(get(raw, key), max, key)

  @spec map_optional_pos_integer(term(), term()) :: {:ok, term()} | {:error, term()}
  def map_optional_pos_integer(raw, key) do
    case get(raw, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {key, :invalid}}
    end
  end

  @spec map_required_pos_integer(term(), term()) :: {:ok, term()} | {:error, term()}
  def map_required_pos_integer(raw, key) do
    case get(raw, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {key, :invalid}}
    end
  end

  @spec fetch_string(term(), term(), term()) :: {:ok, term()} | {:error, term()}
  def fetch_string(raw, key, field) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  @spec fetch_version(term(), term(), term()) :: {:ok, term()} | {:error, term()}
  def fetch_version(raw, key, field) do
    case Map.get(raw, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  @spec fetch_event_id(term()) :: {:ok, term()} | {:error, term()}
  def fetch_event_id(raw) do
    case Map.get(raw, "event_id") do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:event_id, :missing_or_invalid}}
    end
  end

  @spec fetch_map(term(), term(), term()) :: {:ok, term()} | {:error, term()}
  def fetch_map(raw, key, field) do
    case Map.get(raw, key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {field, :missing_or_invalid}}
    end
  end

  @spec fetch_timestamp(term(), term(), term()) :: {:ok, term()} | {:error, term()}
  def fetch_timestamp(raw, key, field) do
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

  @spec verify_hash(term(), term()) :: :ok | {:error, term()}
  def verify_hash(hash, hash), do: :ok
  def verify_hash(_actual, _persisted), do: {:error, :event_content_hash_mismatch}

  @spec get(term(), term()) :: term()
  def get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
