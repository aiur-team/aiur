defmodule Aiur.Config.Schema.EnvResolver do
  @moduledoc "Post-cast value resolution: $ENV reference grammar, secret env fallbacks (\"\" → nil), path tokens with defaults."

  @spec resolve_secret_setting(nil | String.t(), String.t() | nil) :: String.t() | nil
  def resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  def resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  @spec resolve_path_value(String.t(), String.t()) :: String.t()
  def resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  @spec resolve_env_value(String.t(), term()) :: term()
  def resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
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

  @spec normalize_path_token(String.t()) :: String.t() | :missing
  def normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  @spec env_reference_name(String.t()) :: {:ok, String.t()} | :error
  def env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  def env_reference_name(_value), do: :error

  @spec resolve_env_token(String.t()) :: String.t() | :missing
  def resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  @spec normalize_secret_value(String.t() | nil) :: String.t() | nil
  def normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  def normalize_secret_value(_value), do: nil
end
