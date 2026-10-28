defmodule AiurWeb.Streamdeck.Deck do
  @moduledoc "Deck adapter over shared read models, with isolated section failures."

  alias AiurWeb.Streamdeck.Deck.BuildOrder

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    %{build_order: read_section(BuildOrder, opts)}
  end

  @doc "Navigation sections use ordered items with an id and optional child tickets."
  @spec navigation(map()) :: map()
  def navigation(grid) do
    tickets = Enum.map(Map.get(grid, :agents, []), &%{id: to_string(&1.identifier), bucket: &1.bucket})
    fleet = tickets |> Enum.group_by(& &1.bucket) |> Enum.sort_by(&elem(&1, 0))

    %{
      ticket: tickets,
      feature: Map.get(grid, :features, []),
      epic: Map.get(grid, :epics, []),
      fleet: Enum.map(fleet, fn {bucket, items} -> %{id: to_string(bucket), tickets: items} end)
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
