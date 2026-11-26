defmodule Aiur.Protocol.ObservationAge do
  @moduledoc "Shared age labels over status observation values."

  @spec short_label(term()) :: String.t()
  def short_label(age_seconds) when is_integer(age_seconds) and age_seconds >= 0 do
    cond do
      age_seconds < 60 -> "#{age_seconds}s"
      age_seconds < 3_600 -> "#{div(age_seconds, 60)}m #{rem(age_seconds, 60)}s"
      true -> "#{div(age_seconds, 3_600)}h #{div(rem(age_seconds, 3_600), 60)}m"
    end
  end

  def short_label(_age_seconds), do: "unknown age"

  @spec label(map() | nil) :: String.t()
  def label(%{age_ms: age}) when is_integer(age) and age >= 0, do: "#{div(age, 1_000)}s old"
  def label(%{age_seconds: age}) when is_integer(age) and age >= 0, do: "#{age}s old"
  def label(_unknown), do: "age unavailable"

  @spec row_label(map()) :: String.t()
  def row_label(row), do: " [#{label(row)}#{retry_label(row)}]"

  defp retry_label(%{retry_scope: scope}) when is_binary(scope), do: "; #{scope}"
  defp retry_label(_row), do: ""
end
