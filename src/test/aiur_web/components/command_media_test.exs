defmodule AiurWeb.Components.CommandMediaTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.Components.CommandMedia

  defp render(items, decision_id \\ "dec_media") do
    render_component(&CommandMedia.command_media/1, items: items, decision_id: decision_id)
  end

  defp image(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "image",
        "mime_type" => "image/png",
        "attachment_id" => "med_aaaaaaaaaaaaaaaaaaaaaaaa",
        "locator" => %{"kind" => "attachment", "attachment_id" => "med_aaaaaaaaaaaaaaaaaaaaaaaa"},
        "alt_text" => "A dashboard screenshot",
        "caption" => "Dashboard"
      },
      overrides
    )
  end

  test "renders nothing for a Command without media" do
    assert render([]) == ""
  end

  test "renders an image through the authorized attachment route with alt text" do
    html = render([image()])

    img = Floki.parse_fragment!(html) |> Floki.find("img") |> List.first()
    assert Floki.attribute(img, "src") == ["/api/v1/decisions/dec_media/media/med_aaaaaaaaaaaaaaaaaaaaaaaa"]
    assert Floki.attribute(img, "alt") == ["A dashboard screenshot"]
    assert Floki.attribute(img, "loading") == ["lazy"]
    assert html =~ "Dashboard"
  end

  test "uses a validated https locator directly" do
    item = image(%{"locator" => %{"kind" => "url", "value" => "https://raw.githubusercontent.com/aiur-team/aiur/main/a.png"}})

    img = Floki.parse_fragment!(render([item])) |> Floki.find("img") |> List.first()
    assert Floki.attribute(img, "src") == ["https://raw.githubusercontent.com/aiur-team/aiur/main/a.png"]
  end

  test "marks an animated image as animated" do
    item = image(%{"kind" => "animated_image", "mime_type" => "image/gif"})
    assert render([item]) =~ "Animated"
  end

  test "renders playable video with native controls, a poster and a fallback link" do
    item = %{
      "kind" => "video",
      "mime_type" => "video/mp4",
      "attachment_id" => "med_bbbbbbbbbbbbbbbbbbbbbbbb",
      "locator" => %{"kind" => "attachment", "attachment_id" => "med_bbbbbbbbbbbbbbbbbbbbbbbb"},
      "caption" => "Walkthrough",
      "width" => 1280,
      "height" => 720,
      "poster" => %{"kind" => "url", "value" => "https://raw.githubusercontent.com/aiur-team/aiur/main/p.png"}
    }

    html = render([item])
    video = Floki.parse_fragment!(html) |> Floki.find("video") |> List.first()

    assert Floki.attribute(video, "controls") == ["controls"]
    assert Floki.attribute(video, "aria-label") == ["Walkthrough"]
    assert Floki.attribute(video, "poster") == ["https://raw.githubusercontent.com/aiur-team/aiur/main/p.png"]
    assert Floki.attribute(video, "width") == ["1280"]

    source = Floki.find(video, "source") |> List.first()
    assert Floki.attribute(source, "type") == ["video/mp4"]
    assert Floki.find(video, "a") |> Floki.text() == "Open video"
  end

  test "renders audio with native controls" do
    item = %{
      "kind" => "audio",
      "mime_type" => "audio/mpeg",
      "attachment_id" => "med_cccccccccccccccccccccccc",
      "locator" => %{"kind" => "attachment", "attachment_id" => "med_cccccccccccccccccccccccc"},
      "caption" => "Narration"
    }

    audio = Floki.parse_fragment!(render([item])) |> Floki.find("audio") |> List.first()
    assert Floki.attribute(audio, "controls") == ["controls"]
    assert Floki.attribute(audio, "aria-label") == ["Narration"]
  end

  test "falls back to an unavailable panel when the locator cannot be resolved" do
    html = render([image()], nil)

    assert html =~ "Media unavailable"
    assert html =~ "image/png"
    assert Floki.parse_fragment!(html) |> Floki.find("img") == []
  end

  test "falls back when an attachment has no id" do
    item = image(%{"locator" => %{"kind" => "attachment"}, "attachment_id" => nil})

    assert render([item]) =~ "Media unavailable"
  end
end
