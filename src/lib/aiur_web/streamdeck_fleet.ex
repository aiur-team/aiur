defmodule AiurWeb.StreamdeckFleet do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.StreamdeckProjection

  @spec fleet(term()) :: map()
  def fleet(snapshot), do: %{"agents" => agents(snapshot)}

  @spec with_grid(term(), [map()] | nil) :: map()
  @spec with_grid(term(), [map()] | nil, map()) :: map()
  def with_grid(snapshot, summaries, grid \\ grid(nil)) do
    fleet =
      case snapshot do
        {:current, _, _} -> fleet(snapshot)
        snapshot when is_map(snapshot) -> fleet(snapshot)
        _ when is_list(summaries) -> %{"agents" => StreamdeckProjection.fleet_agents(summaries)}
        _ -> fleet(snapshot)
      end

    Map.put(fleet, "grid", grid)
  end

  @spec grid(term()) :: map()
  def grid(_snapshot) do
    deck = Deck.read()
    agents = deck.tickets.keys
    total = length(agents)

    %{agents: agents, total: total, windows: ceil(total / 8), max_column_offset: max(ceil(total / 2) - 4, 0), rows_per_column: 2, columns_per_page: 4, agents_per_page: 8}
    |> Map.merge(deck.build_order)
    |> Map.put(:tickets_status, deck.tickets.status)
    |> Map.put(:counts, deck.counts)
    |> Map.put(:fleet, deck.fleet)
    |> Map.put(:epics, deck.epics.keys)
    |> Map.put(:epics_message, deck.epics.message)
    |> Map.put(:features, deck.features.keys)
    |> Map.put(:features_status, deck.features.status)
    |> Deck.Priority.decorate(deck.queue_positions)
  end

  defp agents(%{agents: agents}) when is_list(agents), do: StreamdeckProjection.fleet_agents(agents)
  defp agents({_status, snapshot, _freshness}), do: agents(snapshot)

  defp agents(%{running: running, retrying: retrying, idle: idle}) do
    Enum.map(running, &StreamdeckProjection.agent(Map.put(&1, :status, :running))) ++
      Enum.map(retrying, &StreamdeckProjection.agent(Map.put(&1, :status, :retrying))) ++
      Enum.map(idle, &StreamdeckProjection.agent(Map.put(&1, :status, :queued)))
  end

  defp agents(_unavailable), do: []
end
