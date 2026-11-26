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

  @spec red_required([map()]) :: [map()]
  def red_required(checks) do
    checks
    |> per_name()
    |> Enum.filter(&(value(&1, :conclusion, nil) in ["failure", "cancelled", "timed_out", "startup_failure"]))
  end

  @spec problem([map()], String.t(), boolean()) :: String.t()
  def problem(failures, cause, true) do
    run_ids = failures |> Enum.map(&value(&1, :id, value(&1, :run_id, nil))) |> Enum.reject(&is_nil/1)
    suffix = if run_ids == [], do: "", else: "; check run(s): #{Enum.map_join(run_ids, ", ", &"##{&1}")}"
    "has a red required check (#{cause})#{suffix}"
  end

  def problem(_failures, _cause, false), do: "is not queued or auto-merging"

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
