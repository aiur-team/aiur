defmodule Aiur.CommandsCLI.Observation do
  @moduledoc false

  @spec row(map() | nil, map(), DateTime.t()) :: map() | nil
  def row(nil, _source, _now), do: nil

  def row(row, source, now) do
    Map.merge(row, %{
      observed_at: now,
      age_ms: elapsed(row.created_at, now),
      needs_you_ms: if(Aiur.Commands.needs_you?(row), do: elapsed(Map.get(row, :human_visible_at), now)),
      freshness: freshness(source)
    })
  end

  defp freshness(%{health: %{status: :unavailable}}), do: :unavailable
  defp freshness(%{health: %{status: :partial}}), do: :partial
  defp freshness(%{health: %{stale: true}}), do: :partial
  defp freshness(%{partial_results?: true}), do: :partial
  defp freshness(%{health: %{status: :available, partial?: false}}), do: :fresh
  defp freshness(_source), do: :unavailable

  defp elapsed(%DateTime{} = at, now), do: max(DateTime.diff(now, at, :millisecond), 0)

  defp elapsed(at, now) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> elapsed(datetime, now)
      _invalid -> nil
    end
  end

  defp elapsed(_at, _now), do: nil
end
