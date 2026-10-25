defmodule Aiur.BuildOrder.Features.Journal do
  @moduledoc "Strict versioned feature journal encoding and replay."

  alias Aiur.BuildOrder.Features.{JournalValidation, Projection}

  @spec empty() :: map()
  def empty, do: %{features: %{}, owners: %{}, also: %{}, seq: 0, events: []}

  @spec encode(map()) :: map()
  def encode(record), do: encode_value(record)

  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(%{"v" => version}) when is_integer(version) and version > 1, do: {:error, :version_unsupported}
  def validate(record), do: JournalValidation.record(record)

  @spec fold(map(), map()) :: {:ok, map()} | {:error, term()}
  def fold(projection, record), do: Projection.fold(projection, record)

  defp encode_value(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp encode_value(%MapSet{} = set), do: set |> Enum.sort() |> Enum.map(&encode_value/1)
  defp encode_value(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), encode_value(value)} end)
  defp encode_value(list) when is_list(list), do: Enum.map(list, &encode_value/1)
  defp encode_value(value) when is_boolean(value), do: value
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value), do: value
end
