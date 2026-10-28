defmodule AiurWeb.Streamdeck.Render.Fleet do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.Nav
  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2]

  @spec compose(map(), Nav.t()) :: {[map() | nil], [map()]}
  def compose(grid, nav) do
    fleet = field(grid, :fleet) || %{}
    faces = faces(field(fleet, :keys) || [], nav)

    faces =
      if unavailable?(fleet, nav), do: [%{title: "Fleet unavailable", label: "Unavailable", face: :unknown, bucket: :paused}], else: faces

    strip = field(fleet, :strip) || %{}
    age = field(strip, :heartbeat_age_s)
    daemon = "#{field(strip, :daemon) || "unknown"} #{if is_integer(age), do: "#{age}s", else: "age unknown"}"
    capacity = "Capacity #{field(strip, :capacity_max) || "—"}#{if field(strip, :capacity_stale), do: " stale", else: ""}"
    regions = [{0, daemon}, {200, capacity}, {400, pause(field(strip, :global_pause))}, {600, "Fleet · #{Nav.page(nav) + 1}"}]
    {Enum.map(0..7, &Enum.at(faces, &1)), Enum.map(regions, &region/1)}
  end

  defp unavailable?(fleet, %{stack: []} = nav), do: field(fleet, :status) == "unavailable" and Nav.page(nav) == 0
  defp unavailable?(fleet, _nav), do: field(fleet, :status) == "unavailable"

  defp region({x, text}), do: %{x: x, width: 200, label: text, parts: [%{kind: :text_line, text: text, y: 50, size: 12}]}
  defp faces(keys, %{stack: []} = nav), do: Enum.slice(keys, Nav.page(nav) * 8, 8)

  defp faces(keys, %{stack: [{:state, states} | _rest]} = nav) do
    category = Enum.find(keys, %{}, &(field(&1, :states) == states))
    Enum.slice(field(category, :tickets) || [], Nav.page(nav) * 8, 8)
  end

  defp faces(_keys, _nav), do: []
  defp pause(true), do: "Global pause: on"
  defp pause(false), do: "Global pause: off"
  defp pause(_unknown), do: "Global pause: unknown"
end
