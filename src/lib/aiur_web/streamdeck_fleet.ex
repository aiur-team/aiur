defmodule AiurWeb.StreamdeckFleet do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck
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
  def grid(snapshot) do
    deck = Deck.read()
    grid = project_grid(snapshot)
    metadata = Map.new(grid.agents, &{&1.identifier, &1})
    agents = Enum.map(deck.tickets.keys, &merge_ticket(Map.get(metadata, &1.id, %{}), &1))
    total = length(agents)

    grid
    |> Map.merge(%{agents: agents, total: total, windows: ceil(total / 8), max_column_offset: max(ceil(total / 2) - 4, 0)})
    |> Map.merge(deck.build_order)
    |> Map.put(:tickets_status, deck.tickets.status)
    |> Map.put(:counts, deck.counts)
    |> Map.put(:epics, deck.epics.keys)
    |> Map.put(:epics_message, deck.epics.message)
    |> Deck.Priority.decorate(deck.queue_positions)
  end

  defp merge_ticket(metadata, key) do
    bucket = if key.state != :queued and metadata[:bucket] in [:alert, :stuck, :running, :paused], do: metadata.bucket, else: key.bucket

    freshness =
      cond do
        key.progress_freshness == "unknown" or metadata[:progress_freshness] == "unknown" -> "unknown"
        key.progress_freshness == "stale" or metadata[:progress_freshness] == "stale" -> "stale"
        true -> "fresh"
      end

    pct = if freshness != "unknown", do: key.pct
    Map.merge(metadata, key) |> Map.merge(%{bucket: bucket, pct: pct, progress_percent: pct, progress_freshness: freshness})
  end

  defp project_grid({status, snapshot, freshness}) when status in [:current, :stale] and is_map(snapshot),
    do: snapshot |> StreamDeckGrid.project() |> Map.put(:snapshot_freshness, freshness)

  defp project_grid(snapshot) when is_map(snapshot), do: StreamDeckGrid.project(snapshot)
  defp project_grid(_unavailable), do: StreamDeckGrid.project(%{})

  defp agents(%{agents: agents}) when is_list(agents), do: StreamdeckProjection.fleet_agents(agents)
  defp agents({_status, snapshot, _freshness}), do: agents(snapshot)

  defp agents(%{running: running, retrying: retrying, idle: idle}) do
    Enum.map(running, &StreamdeckProjection.agent(Map.put(&1, :status, :running))) ++
      Enum.map(retrying, &StreamdeckProjection.agent(Map.put(&1, :status, :retrying))) ++
      Enum.map(idle, &StreamdeckProjection.agent(Map.put(&1, :status, :queued)))
  end

  defp agents(_unavailable), do: []
end
