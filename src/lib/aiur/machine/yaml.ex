defmodule Aiur.Machine.Yaml do
  @moduledoc false

  # Flow-style YAML preserves arbitrary future-section map keys; JSON quotes scalars safely.
  @spec emit(map()) :: iodata()
  def emit(map), do: [emit_value(map), "\n"]

  defp emit_value(map) when is_map(map) do
    entries = map |> Enum.sort() |> Enum.map(fn {key, value} -> [emit_value(key), ": ", emit_value(value)] end)
    ["{", Enum.intersperse(entries, ", "), "}"]
  end

  defp emit_value(list) when is_list(list), do: ["[", Enum.intersperse(Enum.map(list, &emit_value/1), ", "), "]"]
  defp emit_value(value), do: Jason.encode!(value)
end
