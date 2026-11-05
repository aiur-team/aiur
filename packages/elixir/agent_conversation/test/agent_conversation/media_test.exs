defmodule AgentConversation.MediaTest do
  use ExUnit.Case, async: true

  alias AgentConversation.Media

  defp artifact(attrs) do
    Map.merge(%{kind: "image", name: "capture.png", url: "https://cdn.example/capture.png"}, attrs)
  end

  test "each artifact kind is classified for an inline element" do
    assert %{kind: :image, fallback: false} = Media.classify(artifact(%{}))
    assert %{kind: :animated_image} = Media.classify(artifact(%{kind: "gif", url: "https://cdn.example/loop.gif"}))
    assert %{kind: :video} = Media.classify(artifact(%{kind: "video", url: "https://cdn.example/clip.mp4"}))
    assert %{kind: :audio} = Media.classify(artifact(%{kind: "audio", url: "https://cdn.example/voice.ogg"}))
  end

  test "a kind is inferred from the URL when the payload does not state one" do
    assert %{kind: :image} = Media.classify(%{url: "https://cdn.example/shot.png", name: "shot.png"})
    assert %{kind: :audio} = Media.classify(%{url: "https://cdn.example/reply.mp3", name: "reply.mp3"})
  end

  test "an unknown or untyped artifact falls back without losing its name" do
    assert %{kind: :unsupported, fallback: true, reason: :unsupported_kind, alt: "Attachment: build"} =
             Media.classify(%{kind: "binary", name: "build", url: "https://cdn.example/build"})
  end

  test "an artifact without a source becomes a placeholder instead of a broken element" do
    assert %{fallback: true, reason: :missing_source, url: nil, alt: "Image: lost.png"} =
             Media.classify(%{kind: "image", name: "lost.png"})
  end

  test "a host allowlist narrows where attachments may load from" do
    assert %{fallback: true, reason: :host_not_allowed, url: nil} =
             Media.classify(artifact(%{url: "https://evil.example/x.png"}), hosts: ["cdn.example"])

    assert %{fallback: false, url: "https://cdn.example/x.png"} =
             Media.classify(artifact(%{url: "https://cdn.example/x.png"}), hosts: ["cdn.example"])
  end

  test "data and javascript URLs are refused by scheme" do
    assert %{fallback: true, reason: :scheme, url: nil} = Media.classify(artifact(%{url: "data:image/png;base64,AAAA"}))
    assert %{fallback: true, reason: :scheme, url: nil} = Media.classify(artifact(%{url: "javascript:alert(1)"}))
  end

  test "alt text names the kind so a screen reader hears what was attached" do
    assert Media.alt(artifact(%{})) == "Image: capture.png"
    assert Media.alt(artifact(%{kind: "audio", name: "reply.ogg"})) == "Audio: reply.ogg"
    assert Media.alt(%{kind: "video", name: "clip.mp4"}) == "Video: clip.mp4"
    assert Media.alt(%{kind: "video"}) == "Video: Attachment"
  end

  test "classify_all ignores values that are not artifacts" do
    assert [%{kind: :image}] = Media.classify_all([nil, "text", artifact(%{})])
    assert Media.classify_all(nil) == []
  end
end
