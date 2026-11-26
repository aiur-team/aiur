defmodule AiurWeb.Streamdeck.Deck.LaneFrame do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.{Input, Nav}

  @spec compose(map(), Nav.t()) :: {[map() | nil], [map()]}
  def compose(grid, nav) do
    nav = Nav.clamp(nav, Input.sizes(nav, %{lane: grid[:lanes] || []}))
    items = items(grid, nav)
    page = Nav.page(nav)
    message = grid[:lanes_message]
    faces = Enum.map(0..7, &Enum.at(items, page * 8 + rem(&1, 4) * 2 + div(&1, 4)))
    label = if items == [] and message, do: message, else: "Lanes · #{page + 1}/#{max(ceil(length(items) / 8), 1)}"
    region = %{x: 0, width: 800, label: label, parts: [%{kind: :text_line, text: label, y: 50, size: 12}]}
    {faces, [region]}
  end

  defp items(grid, %{stack: []}), do: grid[:lanes] || []
  defp items(grid, %{stack: [{:lane, id} | _]}), do: grid |> Map.get(:lanes, []) |> Enum.find(%{}, &(&1.id == id)) |> Map.get(:tickets, [])
end
