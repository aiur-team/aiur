defmodule Aiur.BuildGate.CommandSummary do
  @moduledoc false

  @spec display(map(), String.t() | nil) :: String.t() | nil
  def display(fields, command) do
    if is_binary(Map.get(fields, "command_hash")) or byte_size(command || "") > 4_096 do
      summarize(fields, command)
    else
      command
    end
  end

  @spec summarize(map(), String.t() | nil) :: String.t()
  def summarize(fields, command) do
    case Map.get(fields, "command_hash") do
      hash when is_binary(hash) ->
        command

      _ ->
        name = command |> to_string() |> String.split() |> List.first() || "unknown"
        name <> ", legacy arguments truncated, sha256=" <> short_hash(command)
    end
  end

  defp short_hash(command), do: :crypto.hash(:sha256, command || "") |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
