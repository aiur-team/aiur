defmodule Aiur.JSONSafe do
  @moduledoc """
  Normalizes runtime terms into values that Jason can encode predictably.

  JSON primitives retain their native types; atoms, tuples, dates, and unknown
  runtime terms receive deterministic string or collection representations.
  """

  @spec normalize(term()) :: term()
  def normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize(%{} = value), do: Map.new(value, fn {key, item} -> {key(key), normalize(item)} end)
  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value) when is_tuple(value), do: value |> Tuple.to_list() |> normalize()
  def normalize(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  def normalize(value) when is_atom(value), do: Atom.to_string(value)
  def normalize(value), do: inspect(value)

  defp key(value) when is_atom(value), do: Atom.to_string(value)
  defp key(value) when is_binary(value), do: value
  defp key(value), do: inspect(value)
end
