defmodule Aiur.Experiments.SampleStatus do
  @moduledoc false
  alias Aiur.Experiments.Arms

  @spec read(map()) :: {:ok, [map()]} | {:error, term()}
  def read(spec) do
    with {:ok, evidence} <- Arms.read(spec["id"]) do
      metrics = Enum.filter(spec["metrics"], & &1["primary"])
      {:ok, Enum.map(metrics, &status(&1, spec, evidence["arms"]))}
    end
  end

  defp status(metric, spec, arms) do
    counts = Map.new(arms, fn {group, arm} -> {group, completed(arm["metrics"][metric["ref"]])} end)
    needed = metric["min_samples"] || spec["min_samples"]
    met? = map_size(counts) == 2 and Enum.all?(Map.values(counts), &(is_integer(&1) and &1 >= needed))
    %{metric: metric["ref"], guard_met?: met?, counts: counts, needed_n: needed}
  end

  defp completed(%{"coverage" => %{"state" => state}, "observations" => rows}) when state in ["captured", "partial"] do
    Enum.count(rows, &(not &1["censored"]))
  end

  defp completed(_unavailable), do: :unavailable
end
