defmodule Aiur.GitHubCostCLI.Fleet do
  @moduledoc false

  alias Aiur.Instance.LeaseStore

  @spec attribution(map(), String.t(), keyword()) :: map()
  def attribution(_local_snapshot, budget, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    snapshots_fun = Keyword.get(opts, :fleet_snapshots_fun, &LeaseStore.github_quota_snapshots/0)

    case snapshots_fun.() do
      {:ok, snapshots} when is_list(snapshots) ->
        instances = Enum.map(snapshots, &instance_attribution(&1, budget, now))

        %{
          available?: true,
          instances: instances,
          observed_instances: length(instances),
          total_attributed_points: Enum.reduce(instances, 0, &(&1.attributed_points + &2))
        }

      _unavailable ->
        unavailable()
    end
  rescue
    _error -> unavailable()
  end

  @spec print(map()) :: :ok
  def print(%{"available?" => true, "instances" => instances} = fleet) do
    IO.puts("")
    IO.puts("fleet attributed spend: #{fleet["total_attributed_points"]} points across #{fleet["observed_instances"]} observed instances")

    Enum.each(instances, fn instance ->
      IO.puts("  #{instance["instance_id"]}: #{instance["attributed_points"]} points, observed #{instance["age_seconds"]}s ago")
    end)
  end

  def print(_unavailable), do: :ok

  defp instance_attribution(entry, budget, now) do
    points =
      entry.snapshot
      |> Map.get(:callers, [])
      |> Enum.filter(&(budget == "all" or &1.resource == budget))
      |> Enum.reduce(0, &(&1.points + &2))

    %{instance_id: entry.instance_id, observed_at: entry.observed_at, age_seconds: max(DateTime.diff(now, entry.observed_at, :second), 0), attributed_points: points}
  end

  defp unavailable, do: %{available?: false, instances: [], observed_instances: 0, total_attributed_points: nil}
end
