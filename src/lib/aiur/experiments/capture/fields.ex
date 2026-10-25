defmodule Aiur.Experiments.Capture.Fields do
  @moduledoc false

  @spec get(map(), String.t()) :: term()
  def get(map, key) when is_map(map) do
    Enum.find_value(map, fn {candidate, value} -> if to_string(candidate) == key, do: {:found, value} end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  @spec unit(map(), String.t(), String.t() | nil) :: String.t() | nil
  def unit(_payload, topic, "topic:" <> index), do: topic |> String.split(".") |> Enum.at(String.to_integer(index))

  def unit(payload, _topic, pointer) do
    case extract(payload, pointer) do
      value when is_binary(value) or is_number(value) -> to_string(value)
      _missing -> nil
    end
  end

  @spec extract(map(), String.t() | nil) :: term()
  def extract(payload, "/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.reduce(payload, fn key, value -> descend(value, String.replace(key, "~1", "/") |> String.replace("~0", "~")) end)
    |> scalar()
  end

  def extract(_payload, _pointer), do: nil
  defp descend(value, key) when is_map(value), do: get(value, key)

  defp descend(value, key) when is_list(value) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 -> Enum.at(value, index)
      _invalid -> nil
    end
  end

  defp descend(_value, _key), do: nil
  defp scalar(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp scalar(_value), do: nil
end
