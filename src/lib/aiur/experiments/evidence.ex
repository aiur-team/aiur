defmodule Aiur.Experiments.Evidence do
  @moduledoc false

  @spec encode(term()) :: String.t()
  def encode(value), do: value |> Aiur.JSONSafe.normalize() |> canonical() |> IO.iodata_to_binary()

  @spec hash(term()) :: String.t()
  def hash(value), do: :crypto.hash(:sha256, encode(value)) |> Base.encode16(case: :lower)

  defp canonical(value) when is_map(value) do
    fields = value |> Enum.sort() |> Enum.map(fn {key, item} -> [Jason.encode!(key), ":", canonical(item)] end)
    ["{", Enum.intersperse(fields, ","), "}"]
  end

  defp canonical(value) when is_list(value), do: ["[", value |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]
  defp canonical(value), do: Jason.encode!(value)
end
