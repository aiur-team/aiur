defmodule AiurWeb.StreamdeckFleet do
  @moduledoc false
  alias AiurWeb.{StreamDeckGrid, StreamdeckProjection}

  @spec fleet(term()) :: map()
  def fleet(snapshot), do: %{"agents" => agents(snapshot)}

  @spec with_grid(term(), [map()] | nil) :: map()
  def with_grid(snapshot, summaries) do
    fleet =
      case snapshot do
        {:current, _, _} -> fleet(snapshot)
        snapshot when is_map(snapshot) -> fleet(snapshot)
        _ when is_list(summaries) -> %{"agents" => StreamdeckProjection.fleet_agents(summaries)}
        _ -> fleet(snapshot)
      end

    Map.put(fleet, "grid", grid(snapshot))
  end

  @spec grid(term()) :: map()
  def grid({status, snapshot, freshness}) when status in [:current, :stale] and is_map(snapshot),
    do: snapshot |> StreamDeckGrid.project() |> Map.put(:snapshot_freshness, freshness)

  def grid(snapshot) when is_map(snapshot), do: StreamDeckGrid.project(snapshot)
  def grid(_unavailable), do: StreamDeckGrid.project(%{})

  defp agents(%{agents: agents}) when is_list(agents), do: StreamdeckProjection.fleet_agents(agents)
  defp agents({_status, snapshot, _freshness}), do: agents(snapshot)

  defp agents(%{running: running, retrying: retrying, idle: idle}) do
    Enum.map(running, &StreamdeckProjection.agent(Map.put(&1, :status, :running))) ++
      Enum.map(retrying, &StreamdeckProjection.agent(Map.put(&1, :status, :retrying))) ++
      Enum.map(idle, &StreamdeckProjection.agent(Map.put(&1, :status, :queued)))
  end

  defp agents(_unavailable), do: []
end
