defmodule AiurWeb.Streamdeck.Render.Fleet do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.Fleet, as: FleetModel
  alias AiurWeb.Streamdeck.Deck.Nav
  alias AiurWeb.Streamdeck.Render.FleetMeters
  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2]

  @spec compose(map(), Nav.t(), map()) :: {[map() | nil], [map()]}
  def compose(grid, nav, usage \\ %{}) do
    fleet = field(grid, :fleet) || %{}
    faces = faces(FleetModel.navigation(fleet), nav) |> ticket_faces(grid, nav)
    faces = if field(fleet, :status) == "unavailable", do: [%{title: "Fleet unavailable", label: "Unavailable", face: :unknown, bucket: :paused}], else: faces
    strip = field(fleet, :strip) || %{}
    age = field(strip, :heartbeat_age_s)
    daemon = "#{field(strip, :daemon) || "unknown"} #{if is_integer(age), do: "#{age}s", else: "age unknown"}"
    capacity = "Capacity #{field(strip, :capacity_max) || "—"}#{if field(strip, :capacity_stale), do: " stale", else: ""}"
    regions = [{0, daemon}, {200, capacity}, {400, pause(field(strip, :global_pause))}, {600, "Fleet · #{Nav.page(nav) + 1}"}]
    regions = regions |> Enum.map(&region/1) |> FleetMeters.compose(usage, nav.scroll)
    {Enum.map(0..7, &Enum.at(faces, rem(&1, 4) * 2 + div(&1, 4))), regions}
  end

  defp ticket_faces(faces, _grid, %{stack: []}), do: faces

  defp ticket_faces(faces, grid, _nav) do
    agents = field(grid, :agents) || []
    Enum.map(faces, &ticket_face(&1, agents))
  end

  defp ticket_face(face, agents), do: Enum.find(agents, &(field(&1, :identifier) == field(face, :id))) || face

  defp region({x, text}), do: %{x: x, width: 200, label: text, parts: [%{kind: :text_line, text: text, y: 50, size: 12}]}
  defp faces(keys, %{stack: []}), do: keys

  defp faces(keys, %{stack: [{:fleet, id} | _rest]} = nav) do
    category = Enum.find(keys, %{}, &(field(&1, :id) == id))
    Enum.slice(field(category, :tickets) || [], Nav.page(nav) * 8, 8)
  end

  defp faces(_keys, _nav), do: []
  defp pause(true), do: "Global pause: on"
  defp pause(false), do: "Global pause: off"
  defp pause(_unknown), do: "Global pause: unknown"
end
