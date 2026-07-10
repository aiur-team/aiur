defmodule Aiur.Config.EnvRef do
  @moduledoc """
  Single home for the `$VAR` env-reference resolution grammar used by
  config secrets (`tracker.linear.api_key` / `tracker.linear.assignee`)
  and paths (`workspace.root`).

  Grammar: a config value of exactly `$NAME` (where NAME matches
  `^[A-Za-z_][A-Za-z0-9_]*$`) resolves to the env var NAME; a missing var
  falls back to the caller-supplied fallback; a var set to the empty
  string resolves to nil (empty-var-is-missing). Any other value is a
  literal — legacy `env:NAME` values are NOT references and pass through
  unchanged.
  """

  @env_name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Resolves a secret config value against the `$VAR` grammar.

  A nil `value` resolves to the normalized `fallback`; a `$NAME`
  reference resolves to the env var (missing var → normalized `fallback`,
  empty var → nil); any other binary is a literal. Binary results are
  normalized so `""` becomes nil.
  """
  @spec resolve(String.t() | nil, String.t() | nil) :: String.t() | nil
  def resolve(nil, fallback), do: empty_to_nil(fallback)

  def resolve(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> empty_to_nil(resolved)
      resolved -> resolved
    end
  end

  @doc """
  Returns `{:ok, name}` when `value` is a `$NAME` env reference, `:error`
  otherwise (including legacy `env:NAME` values, which stay literal).
  """
  @spec reference_name(term()) :: {:ok, String.t()} | :error
  def reference_name("$" <> env_name) do
    if String.match?(env_name, @env_name_pattern) do
      {:ok, env_name}
    else
      :error
    end
  end

  def reference_name(_value), do: :error

  @doc """
  Trims a binary secret; blank (or non-binary) values become nil.
  """
  @spec normalize_secret(term()) :: String.t() | nil
  def normalize_secret(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_secret(_value), do: nil

  defp resolve_env_value(value, fallback) do
    case reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp empty_to_nil(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp empty_to_nil(_value), do: nil
end
