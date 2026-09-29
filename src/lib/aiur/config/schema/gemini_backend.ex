defmodule Aiur.Config.Schema.GeminiBackend do
  @moduledoc "Validation for the native Gemini CLI backend."

  @allowed ~w(command enabled)

  def validate(config) when is_map(config) do
    case Enum.find(Map.keys(config), &(to_string(&1) not in @allowed)) do
      nil -> validate_values(config)
      key -> {:error, "unknown key #{inspect(key)}"}
    end
  end

  def validate(_), do: {:error, "must be a map"}

  defp validate_values(config) do
    cond do
      Map.has_key?(config, "command") and
          (not is_binary(config["command"]) or String.trim(config["command"]) == "") ->
        {:error, "command must be a non-empty string"}

      Map.has_key?(config, "enabled") and not is_boolean(config["enabled"]) ->
        {:error, "enabled must be a boolean"}

      true ->
        :ok
    end
  end
end
