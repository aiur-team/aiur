defmodule AiurWeb.Streamdeck.Render.FeatureGrid do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.Nav
  import AiurWeb.Streamdeck.Render.Svg, only: [field: 2, field: 3]

  @spec compose(map(), Nav.t()) :: {[map() | nil], [map()]}
  def compose(model, nav) do
    grid = field(model, :grid, model)
    features = field(grid, :features, [])
    nav = Nav.clamp(nav, %{feature: length(features), drill: drill_size(features, nav)})
    feature = selected(features, nav)
    items = if nav.stack == [], do: features, else: field(feature, :tickets, [])
    faces = Enum.map(0..7, &Enum.at(items, Nav.page(nav) * 8 + &1))
    faces = if nav.stack == [], do: Enum.map(faces, fn face -> if face, do: Map.put(face, :kind, :feature) end), else: faces
    details = if feature, do: field(feature, :strip), else: "Features · #{length(features)}"
    details = if field(grid, :features_status) == "unavailable", do: "Features unavailable", else: details
    details = field(model, :toast) || details
    pager = "Features · page #{Nav.page(nav) + 1} · #{length(items)} #{if nav.stack == [], do: "features", else: "tickets"}"

    {faces,
     [
       %{x: 0, width: 600, label: details, parts: [%{kind: :text_line, text: details, y: 42, size: 12}]},
       %{x: 600, width: 200, label: pager, parts: [%{kind: :text_line, text: pager, y: 42, size: 9}]}
     ]}
  end

  defp selected(features, %{stack: [{:feature, id} | _]}), do: Enum.find(features, &(field(&1, :id) == id))
  defp selected(features, nav), do: Enum.at(features, Nav.page(nav) * 8)
  defp drill_size(features, nav), do: features |> selected(nav) |> field(:tickets, []) |> length()
end
