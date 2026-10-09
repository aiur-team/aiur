defmodule Aiur.RunTelemetry.Cohort do
  @moduledoc "Bounded cohort values preserved by capture and reduction."
  @spec event_fields(map()) :: map()
  def event_fields(attributes) do
    Map.new([:backend, :model, :effort, :feature, :epic, :tags, :blockers, :start_mode], &{&1, attributes[Atom.to_string(&1)]})
  end

  @spec bounded_strings(list()) :: [String.t()]
  def bounded_strings(values) do
    values |> Enum.filter(&(is_binary(&1) or is_integer(&1))) |> Enum.take(20) |> Enum.map(&String.slice(to_string(&1), 0, 64))
  end

  @spec normalize_metadata_value(atom(), term()) :: term()
  def normalize_metadata_value(key, value) when key in [:tags, :blockers] and is_list(value), do: bounded_strings(value)
  def normalize_metadata_value(_key, nil), do: nil
  def normalize_metadata_value(_key, value), do: normalize_metadata_value(value)

  defp normalize_metadata_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_metadata_value(value) when is_boolean(value), do: value
  defp normalize_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_metadata_value(value) when is_binary(value) or is_number(value), do: value
  defp normalize_metadata_value(_value), do: "unknown"
end
