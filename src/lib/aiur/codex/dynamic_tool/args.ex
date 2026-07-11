defmodule Aiur.Codex.DynamicTool.Args do
  @moduledoc """
  Argument normalizers for dynamic tool input.
  """

  @spec string(map(), String.t(), atom()) :: {:ok, String.t()} | {:error, atom()}
  def string(arguments, key, error_reason) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error_reason}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, error_reason}
    end
  end

  @spec alert_string(map(), String.t(), atom()) :: {:ok, String.t()} | {:error, atom()}
  def alert_string(arguments, key, error_reason) do
    case emit_alert_value(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error_reason}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, error_reason}
    end
  end

  @spec emit_alert_value(map(), String.t()) :: term()
  def emit_alert_value(arguments, "name"),
    do: Map.get(arguments, "name") || Map.get(arguments, :name)

  def emit_alert_value(arguments, "message"),
    do: Map.get(arguments, "message") || Map.get(arguments, :message)

  def emit_alert_value(arguments, "reason"),
    do: Map.get(arguments, "reason") || Map.get(arguments, :reason)

  @spec has_key?(map(), String.t()) :: boolean()
  def has_key?(arguments, key) do
    Map.has_key?(arguments, key) or Map.has_key?(arguments, String.to_atom(key))
  end

  @spec boolean(map(), String.t(), atom()) :: {:ok, boolean()} | {:error, atom()}
  def boolean(arguments, key, error_reason) do
    value =
      cond do
        Map.has_key?(arguments, key) -> Map.get(arguments, key)
        Map.has_key?(arguments, String.to_atom(key)) -> Map.get(arguments, String.to_atom(key))
        true -> :missing
      end

    case value do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, error_reason}
    end
  end
end
