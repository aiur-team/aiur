defmodule AiurWeb.Streamdeck.Render do
  @moduledoc """
  Pure SVG renderer for the Stream Deck's eight 120×120 keys and 800×100 strip.

  `frame/1` consumes the SD-101 projection (`grid` plus `usage`) and optional
  `column_offset` / `provider_offset` integers. It also accepts the grid itself.
  Both atom and wire string keys are supported. No reads or clock access occur.

  `strip/1` accepts region maps with `x`, `width`, `label`, and `parts`. Parts
  have a `kind`: `title_bar`, `meter_row`, `count_row`, `text_line`, or `pager`.
  Coordinates inside a region are local. The same parts compose every group.
  """

  alias AiurWeb.Streamdeck.Render.{Card, Grid, Key, MeterDetail, Parts, Svg, Views}
  import Svg, only: [field: 2, field: 3]

  @type image :: %{svg: String.t(), hash: String.t(), label: String.t()}
  @type region_image :: %{
          x: non_neg_integer(),
          width: pos_integer(),
          svg: String.t(),
          hash: String.t(),
          label: String.t()
        }

  @spec key(map()) :: image()
  def key(face),
    do: render_key(face)

  defp render_key(%{kind: :account, account: account, now_ms: now}), do: MeterDetail.key(account, now)
  defp render_key(face), do: if(field(face, :kind) in [:card, "card"], do: Card.render(face), else: Key.render(face))

  @spec strip([map()]) :: [region_image()]
  def strip(regions) do
    Enum.map(regions, fn region ->
      x = field(region, :x)
      width = field(region, :width)

      unless is_integer(x) and is_integer(width) and x >= 0 and width > 0 and x + width <= 800 do
        raise ArgumentError, "strip region must fit the 800×100 canvas"
      end

      content = [
        Svg.element("rect", width: width, height: 100, fill: "#101318"),
        Enum.map(field(region, :parts, []), &Parts.draw(&1, width))
      ]

      content
      |> Svg.image(width, 100, field(region, :label, ""))
      |> Map.merge(%{x: x, width: width})
    end)
  end

  @spec frame(map()) :: %{keys: [image() | nil], strip: [region_image()]}
  def frame(model) do
    {faces, regions} = compose(model)
    %{keys: Enum.map(faces, fn face -> if face, do: key(face) end), strip: strip(regions)}
  end

  @spec compose(map()) :: {[map() | nil], [map()]}
  def compose(model) do
    case {to_string(field(model, :surface, :grid)), field(field(model, :nav), :view)} do
      {"grid", view} when view in [:fleet, "fleet"] -> Views.compose(model)
      {"grid", _view} -> Grid.compose(model)
      _focused -> Views.compose(model)
    end
  end
end
