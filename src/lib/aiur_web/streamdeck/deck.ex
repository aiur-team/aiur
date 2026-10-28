defmodule AiurWeb.Streamdeck.Deck do
  @moduledoc "Deck adapter over shared read models, with isolated section failures."

  alias AiurWeb.Streamdeck.Deck.{BuildOrder, Counts, Features, Fleet, Tickets}

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :window, fn -> Counts.window(opts) end)
    {positions, build_order} = Map.pop(read_section(BuildOrder, opts), :queue_positions, %{})
    counts = Counts.read(opts)
    %{build_order: build_order, queue_positions: positions, counts: counts, tickets: Tickets.read(opts), features: Features.read(opts), fleet: Fleet.read(Keyword.put(opts, :counts, counts))}
  end

  @doc "Navigation sections use ordered items with an id and optional child tickets."
  @spec navigation(map()) :: map()
  def navigation(grid) do
    tickets = Enum.map(Map.get(grid, :agents, []), &Map.put(&1, :id, to_string(&1.identifier)))
    fleet = Map.get(grid, :fleet, Map.get(grid, "fleet", %{keys: []}))

    %{
      ticket: tickets,
      feature: Map.get(grid, :features, []),
      epic: Map.get(grid, :epics, []),
      fleet: Fleet.navigation(fleet)
    }
  end

  defp read_section(section, opts) do
    section.read(opts)
  rescue
    _error -> %{build: nil, build_status: "unavailable"}
  catch
    :exit, _reason -> %{build: nil, build_status: "unavailable"}
  end
end
