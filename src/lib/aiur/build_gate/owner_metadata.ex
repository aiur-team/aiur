defmodule Aiur.BuildGate.OwnerMetadata do
  @moduledoc false

  @spec parse_v2_record(binary()) :: {:ok, map()} | :error
  def parse_v2_record(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> {:cont, {:ok, Map.put(acc, key, value)}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, fields} when map_size(fields) > 0 -> {:ok, fields}
      _ -> :error
    end
  end

  @spec int_field(map(), String.t()) :: integer() | nil
  def int_field(fields, key) do
    case Map.get(fields, key) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> nil
        end
    end
  end
end
