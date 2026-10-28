defmodule AiurWeb.StreamdeckLiveImagesTest do
  use AiurWeb.StreamdeckLiveCase

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.{FrameUpdates, Render}

  test "grid buttons contain exactly the renderer SVG and accessible label for their slot" do
    {:ok, view, html} = live(build_conn(), "/streamdeck")
    assert_grid_images(view, html)
    # LiveViewTest normalizes DOM serialization; the HTTP response retains raw bytes.
    raw_html = build_conn() |> get("/streamdeck") |> html_response(200)
    assigns = :sys.get_state(view.pid).socket.assigns
    {_nav, _model, frame} = FrameUpdates.frame(assigns.deck_nav, assigns.grid, assigns.usage)
    for image <- frame.keys, image, do: assert(raw_html =~ image.svg)

    html = render_hook(view, "input", %{"kind" => "dial", "index" => 3, "action" => "turn", "delta" => 1})
    assert_grid_images(view, html)
    assert has_element?(view, "#sd-keys[data-grid-page='1']")
  end

  test "LiveView displays an injected renderer marker for every fleet key" do
    test_pid = self()
    marker = %{svg: ~s(<svg xmlns="http://www.w3.org/2000/svg"><text>injected-marker</text></svg>), label: "Injected label"}

    EndpointStubs.put(
      streamdeck_render_fun: fn model ->
        send(test_pid, {:rendered_model, model})
        %{keys: List.duplicate(marker, 8), strip: [Map.merge(marker, %{x: 0, width: 800})]}
      end
    )

    {:ok, _view, html} = live(build_conn(), "/streamdeck")
    assert_receive {:rendered_model, %{grid: %{agents: [_ | _]}, page: 0}}
    assert length(Regex.scan(~r/<text>injected-marker<\/text>/, html)) == 8
    assert length(Floki.find(Floki.parse_fragment!(html), "#sd-keys button[aria-label='Injected label'] > svg")) == 8
    refute html =~ "sd-agent-top"
  end

  test "hostile fleet title remains escaped through the real LiveView", %{snapshot_agent: snapshot} do
    title = "<img src=x onerror=alert(1)>"
    Agent.update(snapshot, &put_fixture_agent(&1, "1352", title: title))
    {:ok, _view, html} = live(build_conn(), "/streamdeck")

    assert html =~ "&lt;img"
    refute html =~ title
    assert Floki.find(Floki.parse_fragment!(html), "#sd-keys img, #sd-keys [onerror]") == []
    assert Enum.any?(Floki.attribute(Floki.parse_fragment!(html), "#sd-keys button", "aria-label"), &String.contains?(&1, title))
  end

  test "last page contains eight buttons and disables only empty slots", %{snapshot_agent: snapshot} do
    Agent.update(snapshot, fn _ -> fleet_snapshot(9) end)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    html = render_hook(view, "input", %{"kind" => "dial", "index" => 3, "action" => "turn", "delta" => 1})
    document = Floki.parse_fragment!(html)

    assert length(Floki.find(document, "#sd-keys button")) == 8
    assert length(Floki.find(document, "#sd-keys button[disabled][aria-hidden=true]")) == 7
    assert length(Floki.find(document, "#sd-keys button > svg")) == 1
    assert_grid_images(view, html)
  end

  defp assert_grid_images(view, html) do
    assigns = :sys.get_state(view.pid).socket.assigns
    {_nav, model, frame} = FrameUpdates.frame(assigns.deck_nav, assigns.grid, assigns.usage)
    {faces, _regions} = Render.Grid.compose(model)
    buttons = Regex.scan(~r/<button\b[^>]*data-streamdeck-key="\d+"[^>]*>(.*?)<\/button>/s, html)
    assert length(buttons) == 8

    for {{[_button, body], image}, face} <- buttons |> Enum.zip(frame.keys) |> Enum.zip(faces) do
      if image do
        assert image == Render.key(face)
        assert Floki.raw_html(Floki.parse_fragment!(body)) == Floki.raw_html(Floki.parse_fragment!(image.svg))
        assert length(Floki.find(Floki.parse_fragment!(body), "svg")) == 1
      else
        assert String.trim(body) == ""
      end
    end

    labels = Floki.attribute(Floki.parse_fragment!(html), "#sd-keys button", "aria-label")
    assert labels == for(image <- frame.keys, image, do: image.label)
  end
end
