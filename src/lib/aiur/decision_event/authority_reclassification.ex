defmodule Aiur.DecisionEvent.AuthorityReclassification do
  @moduledoc false

  alias Aiur.SecretRedactor

  @detail_max 2_000
  @identity_max 200

  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(raw) when is_map(raw) do
    with {:ok, actor} <- normalize_actor(get(raw, :actor)),
         authority <- get(raw, :authority),
         true <- authority in [:supervisor_allowed, "supervisor_allowed"],
         {:ok, detail} <- bounded_required(get(raw, :detail), @detail_max, :detail),
         {:ok, expected_version} <- normalize_expected_version(get(raw, :expected_version)) do
      {:ok, %{actor: actor, authority: :supervisor_allowed, detail: detail, expected_version: expected_version}}
    else
      false -> {:error, {:authority, :invalid_reclassification}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec to_json_safe(map()) :: map()
  def to_json_safe(data) do
    %{
      "actor" => %{"kind" => Atom.to_string(data.actor.kind), "id" => data.actor.id},
      "authority" => Atom.to_string(data.authority),
      "detail" => data.detail,
      "expected_version" => data.expected_version
    }
  end

  defp normalize_actor(actor) when is_map(actor) do
    kind = get(actor, :kind)

    with true <- kind in [:executor, "executor"],
         {:ok, id} <- bounded_optional(get(actor, :id), @identity_max, :actor_id) do
      {:ok, %{kind: :executor, id: id}}
    else
      false -> {:error, {:actor_kind, :not_executor}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_actor(_other), do: {:error, {:actor, :invalid}}

  defp normalize_expected_version(version) when is_integer(version) and version > 0, do: {:ok, version}
  defp normalize_expected_version(_version), do: {:error, {:expected_version, :invalid}}

  defp bounded_optional(nil, _max, _field), do: {:ok, nil}
  defp bounded_optional(value, max, field), do: bounded_required(value, max, field)
  defp bounded_required(nil, _max, field), do: {:error, {field, :missing}}

  defp bounded_required(value, max, field) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, {field, :missing}}
      String.length(trimmed) > max -> {:error, {field, :too_long}}
      unsafe_control_chars?(trimmed) -> {:error, {field, :unsafe_characters}}
      true -> {:ok, SecretRedactor.redact(trimmed)}
    end
  end

  defp bounded_required(_value, _max, field), do: {:error, {field, :invalid_type}}

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 and codepoint not in [?\n, ?\t, ?\r] end)
  end

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
