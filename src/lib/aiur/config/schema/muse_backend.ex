defmodule Aiur.Config.Schema.MuseBackend do
  @moduledoc "Validation for native Muse backend settings."

  @allowed ~w(command trust_workspace approval_mode model provider_id enabled)
  @approval_modes ~w(allowAll promptUnmatched onRequest denyUnmatched)

  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(config) when is_map(config) do
    with :ok <- known_keys(config),
         :ok <- nonempty_string(config, "command"),
         :ok <- optional_string(config, "model"),
         :ok <- optional_string(config, "provider_id"),
         :ok <- optional_boolean(config, "trust_workspace"),
         :ok <- optional_boolean(config, "enabled") do
      approval_mode(config)
    end
  end

  def validate(_), do: {:error, "must be a map"}

  defp known_keys(config) do
    case Enum.find(Map.keys(config), &(to_string(&1) not in @allowed)) do
      nil -> :ok
      key -> {:error, "unknown key #{inspect(key)}"}
    end
  end

  defp nonempty_string(config, key) do
    case Map.get(config, key) do
      nil -> :ok
      value when is_binary(value) -> if String.trim(value) == "", do: {:error, "#{key} must not be blank"}, else: :ok
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp optional_string(config, key) do
    case Map.get(config, key) do
      nil -> :ok
      value when is_binary(value) -> :ok
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp optional_boolean(config, key) do
    case Map.get(config, key) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _ -> {:error, "#{key} must be a boolean"}
    end
  end

  defp approval_mode(config) do
    case Map.get(config, "approval_mode") do
      nil -> :ok
      mode when mode in @approval_modes -> :ok
      _ -> {:error, "approval_mode must be one of #{Enum.join(@approval_modes, ", ")}"}
    end
  end
end
