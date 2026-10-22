defmodule Aiur.ExecutorSweep.LatestChecks do
  @moduledoc false

  @spec per_name([map()]) :: [map()]
  def per_name(checks) do
    checks
    |> Enum.with_index()
    |> Enum.reduce(%{}, &keep_latest/2)
    |> Map.values()
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 2))
  end

  defp keep_latest({check, index}, latest) do
    name = value(check, :name, "required check")
    candidate = {recency(check), index, check}

    Map.update(latest, name, candidate, &newer(candidate, &1))
  end

  defp newer(candidate, current), do: if(candidate > current, do: candidate, else: current)

  defp recency(check) do
    value(check, :started_at, nil) || value(check, :completed_at, nil) || value(check, :id, 0)
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
