defmodule Aiur.Experiments.Observation do
  @moduledoc "One numeric sample, its unit, timestamp and declared attributes."
  @derive Jason.Encoder
  defstruct [:unit_id, :value, :at, attrs: %{}]
  @type t :: %__MODULE__{}

  @spec new(term()) :: {:ok, t()} | {:error, atom()}
  def new(map) when is_map(map) do
    unit = get(map, :unit_id)
    value = get(map, :value)
    attrs = get(map, :attrs) || %{}

    with true <- is_binary(unit) and unit != "",
         true <- is_number(value),
         true <- is_map(attrs),
         {:ok, at} <- timestamp(get(map, :at)) do
      {:ok, %__MODULE__{unit_id: unit, value: value, at: at, attrs: attrs}}
    else
      _ -> {:error, :invalid_observation}
    end
  end

  def new(_), do: {:error, :invalid_observation}
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp timestamp(%DateTime{} = at), do: {:ok, at}

  defp timestamp(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _} -> {:ok, parsed}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp timestamp(_), do: {:error, :invalid_timestamp}
end
