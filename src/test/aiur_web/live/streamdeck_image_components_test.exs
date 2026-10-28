defmodule AiurWeb.StreamdeckImageComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.StreamdeckLive.ImageComponents

  test "key preserves renderer bytes, accessible label and interaction attributes" do
    image =
      Render.key(%{
        identifier: "5181",
        bucket: :running,
        title: "Fix strip squeeze",
        progress_percent: 40
      })

    html =
      render_component(&ImageComponents.key/1,
        image: image,
        index: 0,
        "data-streamdeck-identifier": "5181",
        "data-control-action": "pause"
      )

    document = Floki.parse_fragment!(html)

    assert [image.svg] == Regex.run(~r/<svg\b.*<\/svg>/s, html)
    assert length(Floki.find(document, "button > svg")) == 1
    assert Floki.attribute(document, "button", "aria-label") == [image.label]
    assert Floki.attribute(document, "button", "data-streamdeck-key") == ["0"]
    assert Floki.attribute(document, "button", "data-streamdeck-identifier") == ["5181"]
    assert Floki.attribute(document, "button", "data-control-action") == ["pause"]
    assert Floki.find(document, "button[disabled]") == []
  end

  test "key displays the supplied marker image without drawing another face" do
    image = %{
      svg: ~s(<svg xmlns="http://www.w3.org/2000/svg"><text>marker</text></svg>),
      label: "Marker face"
    }

    html = render_component(&ImageComponents.key/1, image: image, index: 3)

    assert [image.svg] == Regex.run(~r/<svg\b.*<\/svg>/s, html)

    assert Floki.parse_fragment!(html) |> Floki.attribute("button", "aria-label") == [
             "Marker face"
           ]
  end

  test "empty slot is a disabled hidden button without an SVG" do
    html = render_component(&ImageComponents.key/1, index: 7)
    document = Floki.parse_fragment!(html)

    assert length(
             Floki.find(
               document,
               "button.is-empty[disabled][aria-hidden=true][data-streamdeck-key='7']"
             )
           ) == 1

    assert Floki.find(document, "svg") == []
    assert Floki.attribute(document, "button", "aria-label") == []
  end

  test "hostile title stays escaped in the image and the accessible name" do
    title = "<img src=x onerror=alert(1)>"
    image = Render.key(%{identifier: "5181", bucket: :running, title: title})
    html = render_component(&ImageComponents.key/1, image: image, index: 0)
    document = Floki.parse_fragment!(html)

    assert Floki.find(document, "img, [onerror]") == []
    assert Floki.attribute(document, "button", "aria-label") == [image.label]
    assert image.label =~ title
    assert html =~ "&lt;img"
    refute html =~ title
  end

  test "strip preserves renderer SVGs and positions every region on the fixed canvas" do
    regions =
      Render.strip([
        %{x: 0, width: 200, label: "Summary", parts: []},
        %{x: 200, width: 600, label: "Fleet", parts: []}
      ])

    html =
      render_component(&ImageComponents.strip/1, regions: regions, "data-transcript-offset": 12)

    document = Floki.parse_fragment!(html)

    assert Floki.attribute(document, "#sd-screen", "data-transcript-offset") == ["12"]

    assert Floki.attribute(document, "[data-streamdeck-region]", "aria-label") == [
             "Summary",
             "Fleet"
           ]

    assert Floki.attribute(document, "[data-streamdeck-region='200']", "style") == [
             "position: absolute; left: 200px; width: 600px; height: 100px;"
           ]

    assert length(Floki.find(document, "#sd-screen > div > svg")) == 2
    for region <- regions, do: assert(html =~ region.svg)
  end
end
