defmodule Aiur.Protocol.ObservationAge do
  @moduledoc "Shared age labels over status observation values."

  @spec label(map() | nil) :: String.t()
  def label(%{age_ms: age}) when is_integer(age) and age >= 0, do: "#{div(age, 1_000)}s old"
  def label(%{age_seconds: age}) when is_integer(age) and age >= 0, do: "#{age}s old"
  def label(_unknown), do: "age unavailable"

  @spec row_label(map()) :: String.t()
  def row_label(row), do: " [#{label(row)}#{retry_label(row)}]"

  defp retry_label(%{retry_scope: scope}) when is_binary(scope), do: "; #{scope}"
  defp retry_label(_row), do: ""
end
