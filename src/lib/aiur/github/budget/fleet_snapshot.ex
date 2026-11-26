defmodule Aiur.GitHub.Budget.FleetSnapshot do
  @moduledoc false

  @key {__MODULE__, :latest}

  @spec put([map()], DateTime.t()) :: :ok
  def put(snapshots, observed_at \\ DateTime.utc_now()) when is_list(snapshots) do
    :persistent_term.put(@key, %{snapshots: snapshots, observed_at: observed_at})
    :ok
  end

  @spec read(DateTime.t()) :: map()
  def read(now \\ DateTime.utc_now()) do
    case :persistent_term.get(@key, nil) do
      %{snapshots: snapshots, observed_at: %DateTime{} = observed_at} ->
        if snapshots == [] do
          %{state: :unknown, observed_at: nil, age_seconds: nil, observed_instances: 0, resources: %{}}
        else
          %{
            state: :observed,
            observed_at: observed_at,
            age_seconds: max(DateTime.diff(now, observed_at, :second), 0),
            observed_instances: length(snapshots),
            resources: summarize(snapshots)
          }
        end

      _unavailable ->
        %{state: :unknown, observed_at: nil, age_seconds: nil, observed_instances: 0, resources: %{}}
    end
  end

  @spec summarize([map()]) :: map()
  def summarize(snapshots) do
    Enum.reduce(snapshots, %{"core" => 0, "graphql" => 0, "search" => 0}, &add_snapshot/2)
  end

  defp add_snapshot(entry, acc),
    do: Enum.reduce(Map.get(entry.snapshot, :callers, []), acc, &add_caller/2)

  defp add_caller(caller, totals) do
    resource = Map.get(caller, :resource)
    if Map.has_key?(totals, resource), do: Map.update!(totals, resource, &(&1 + Map.get(caller, :points, 0))), else: totals
  end

  @spec status_line(boolean(), map()) :: String.t()
  def status_line(configured?, fleet \\ read()) do
    if configured? do
      case fleet do
        %{state: :observed, resources: resources, observed_instances: count, age_seconds: age} ->
          "GITHUB BUDGET shared daemon spend core=#{Map.get(resources, "core", 0)} requests " <>
            "graphql=#{Map.get(resources, "graphql", 0)} points instances=#{count} observed=#{age}s; " <>
            "agent gh calls are counted per host"

        _unknown ->
          "GITHUB BUDGET shared daemon budget has no fleet sample yet; agent gh calls are counted per host"
      end
    else
      "GITHUB BUDGET daemon budget is host-local (coordination store unconfigured); agent gh calls are counted per host"
    end
  end
end
