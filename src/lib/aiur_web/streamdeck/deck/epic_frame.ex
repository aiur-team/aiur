defmodule AiurWeb.Streamdeck.Deck.EpicFrame do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.{Input, Nav}

  @spec compose(map(), Nav.t()) :: {[map() | nil], [map()]}
  def compose(grid, nav) do
    nav = Nav.clamp(nav, Input.sizes(nav, %{epic: grid[:epics] || []}))
    items = items(grid, nav)
    page = Nav.page(nav)
    message = grid[:epics_message]
    faces = Enum.map(0..7, &Enum.at(items, page * 8 + rem(&1, 4) * 2 + div(&1, 4)))
    label = if items == [] and message, do: message, else: "Epics · #{page + 1}/#{max(ceil(length(items) / 8), 1)}"
    region = %{x: 0, width: 800, label: label, parts: [%{kind: :text_line, text: label, y: 50, size: 12}]}
    {faces, [region]}
  end

  defp items(grid, %{stack: []}), do: grid[:epics] || []
  defp items(grid, %{stack: [{:epic, id} | _]}), do: grid |> Map.get(:epics, []) |> Enum.find(%{}, &(&1.id == id)) |> Map.get(:tickets, [])
end
