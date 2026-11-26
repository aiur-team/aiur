defmodule Aiur.Orchestrator.OptimisticIntegration do
  @moduledoc "Deduplicated blocker push and agent integration evidence for one attempt."

  @spec update(map(), tuple()) :: map()
  def update(row, {:integration, blocker, sha, conflict, non_ff}) when is_boolean(conflict) and is_boolean(non_ff) do
    evidence = %{"blocker" => blocker, "sha" => sha, "conflict" => conflict, "non_ff" => non_ff}
    counter = if conflict, do: "integrations_conflict", else: "integrations_clean"
    add(row, "integration_reports", evidence, [counter] ++ if(non_ff, do: ["non_ff_pushes"], else: []))
  end

  def update(row, {:push, blocker, sha}), do: add(row, "observed_pushes", %{"blocker" => blocker, "sha" => sha}, ["pushes_absorbed"])
  def update(row, _operation), do: row

  defp add(row, key, evidence, counters) do
    previous = Map.get(row, key, [])

    if valid?(row, evidence) and evidence not in previous do
      row = Map.put(row, key, previous ++ [evidence])
      Enum.reduce(counters, row, fn counter, current -> update_in(current, ["counters", counter], &(&1 + 1)) end)
    else
      row
    end
  end

  defp valid?(row, evidence) do
    is_binary(evidence["sha"]) and Regex.match?(~r/\A[0-9a-f]{40}\z/, evidence["sha"]) and
      Enum.any?(row["blockers"], &(&1["id"] == evidence["blocker"]))
  end
end
