defmodule Aiur.DecisionValidation.Context do
  @moduledoc false

  alias Aiur.SecretRedactor

  @max_summary 500
  @max_long_context 20_000
  @human_required_authority_bases ~w(product spend external_publication security)

  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(payload) do
    case get(payload, :context) do
      nil -> {:ok, %{short_summary: nil, long_context_markdown: nil}}
      context when is_map(context) -> normalize_context(context)
      _other -> {:error, {:context, :invalid_type}}
    end
  end

  @spec validate_authority_basis(term(), term(), term()) :: :ok | {:error, term()}
  def validate_authority_basis(:human_required, "legacy_attention", _context), do: :ok

  def validate_authority_basis(:human_required, _kind, %{authority_basis: basis})
      when basis in @human_required_authority_bases,
      do: :ok

  def validate_authority_basis(:human_required, _kind, _context),
    do: {:error, {:authority, :human_required_basis_required}}

  def validate_authority_basis(_authority, _kind, _context), do: :ok

  defp normalize_context(context) do
    with {:ok, short_summary} <- fetch_string(context, :short_summary, @max_summary, :context_short_summary),
         {:ok, long_context_markdown} <- fetch_string(context, :long_context_markdown, @max_long_context, :context_long_context_markdown),
         {:ok, authority_basis} <- fetch_authority_basis(context) do
      result = %{short_summary: short_summary, long_context_markdown: long_context_markdown}
      {:ok, if(authority_basis, do: Map.put(result, :authority_basis, authority_basis), else: result)}
    end
  end

  defp fetch_authority_basis(context) do
    case get(context, :authority_basis) do
      nil -> {:ok, nil}
      basis when basis in @human_required_authority_bases -> {:ok, basis}
      _invalid -> {:error, {:context_authority_basis, :invalid_enum}}
    end
  end

  defp fetch_string(map, key, max, error_key) do
    case get(map, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> bound_string(value, max, error_key)
      _other -> {:error, {error_key, :invalid_type}}
    end
  end

  defp bound_string(value, max, field) do
    trimmed = String.trim(value)

    cond do
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

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
