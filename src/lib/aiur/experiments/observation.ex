defmodule Aiur.Experiments.Observation do
  @moduledoc "One numeric sample, its unit, timestamp and declared attributes."
  @derive Jason.Encoder
  defstruct [:unit_id, :value, :at, :started_at, :finished_at, censored: false, attrs: %{}]
  @type t :: %__MODULE__{}

  @spec new(term()) :: {:ok, t()} | {:error, atom()}
  def new(map) when is_map(map) do
    unit = get(map, :unit_id)
    value = get(map, :value)
    attrs = get(map, :attrs) || %{}

    with true <- is_binary(unit) and unit != "",
         true <- is_number(value),
         true <- is_map(attrs),
         {:ok, at} <- timestamp(get(map, :at)),
         {:ok, started} <- optional_timestamp(get(map, :started_at)),
         {:ok, finished} <- optional_timestamp(get(map, :finished_at)),
         censored = get(map, :censored) || false,
         true <- is_boolean(censored) do
      {:ok, %__MODULE__{unit_id: unit, value: value, at: at, started_at: started, finished_at: finished, censored: censored, attrs: attrs}}
    else
      _ -> {:error, :invalid_observation}
    end
  end

  def new(_), do: {:error, :invalid_observation}
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp optional_timestamp(nil), do: {:ok, nil}
  defp optional_timestamp(at), do: timestamp(at)
  defp timestamp(%DateTime{} = at), do: {:ok, at}

  defp timestamp(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _} -> {:ok, parsed}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp timestamp(_), do: {:error, :invalid_timestamp}
end
