defmodule Aiur.Commands.ComponentState.MediaTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.ComponentState
  alias Aiur.Commands.ComponentState.Media

  defp item(overrides) do
    Map.merge(
      %{
        kind: :image,
        mime_type: "image/png",
        locator: %{kind: :path, value: "/tmp/evidence.png"},
        alt_text: "Evidence",
        caption: nil,
        byte_size: 10,
        width: 800,
        height: 600,
        duration_ms: nil,
        poster: nil
      },
      overrides
    )
  end

  test "a typed item projects to its safe public shape and an attachment id" do
    assert [public] = Media.list(%{"media" => [item(%{})]})

    assert public["kind"] == "image"
    assert public["mime_type"] == "image/png"
    assert public["alt_text"] == "Evidence"
    assert %{"kind" => "attachment", "attachment_id" => attachment_id} = public["locator"]
    assert String.starts_with?(attachment_id, "med_")
  end

  test "a filesystem path never reaches the contract" do
    [public] = Media.list(%{media: [item(%{})]})

    refute inspect(public) =~ "/tmp/evidence.png"
  end

  test "an expiring signed URL is refused rather than published" do
    signed = item(%{locator: %{kind: :url, value: "https://github.com/a/b.png?X-Amz-Signature=abc"}})

    assert [%{"locator" => nil}] = Media.list(%{"media" => [signed]})
  end

  test "a non-allowlisted URL host is refused rather than published" do
    offhost = item(%{locator: %{kind: :url, value: "https://cdn.test/a.png"}})

    assert [%{"locator" => nil}] = Media.list(%{"media" => [offhost]})
  end

  test "an allowlisted https locator passes through" do
    public_url = item(%{locator: %{kind: :url, value: "https://github.com/a/b.png"}})

    assert [%{"locator" => %{"kind" => "url", "value" => "https://github.com/a/b.png"}}] =
             Media.list(%{"media" => [public_url]})
  end

  test "an already-public projection passes through unchanged" do
    [public] = Media.list(%{"media" => [item(%{})]})

    assert Media.list(%{"media" => [public]}) == [public]
  end

  test "artifact references keep the pre-existing kind/value shape" do
    projection = %{"artifacts" => [%{"kind" => "url", "value" => "https://example.test/notes"}, %{"kind" => "path", "value" => "/srv/notes.md"}]}

    assert Media.list(projection) == [
             %{"kind" => "url", "value" => "https://example.test/notes"},
             %{"kind" => "path", "value" => "/srv/notes.md"}
           ]
  end

  test "typed items come before artifact references and both are renderable" do
    projection = %{
      "media" => [item(%{})],
      "artifacts" => [%{"kind" => "url", "value" => "https://example.test/notes"}]
    }

    assert [typed, artifact] = Media.list(projection)
    assert Map.has_key?(typed, "locator")
    assert artifact == %{"kind" => "url", "value" => "https://example.test/notes"}
  end

  test "the component contract carries the typed list and option media" do
    projection = %{
      "decision_id" => "dec_1",
      "version" => 1,
      "question" => "Which cover?",
      "decision_status" => "open",
      "revision_sequence" => 0,
      "options" => [%{"id" => "cover-a", "label" => "Cover A", "media" => [item(%{alt_text: "Cover A"})]}],
      "recommendation" => %{"option_id" => "cover-a"},
      "media" => [item(%{kind: :video, mime_type: "video/mp4", alt_text: "Clip"})],
      "artifacts" => [],
      "answer" => nil
    }

    component = ComponentState.from_projection(projection)

    assert [video] = component["media"]
    assert video["kind"] == "video"
    assert [option] = component["options"]
    assert [%{"kind" => "image", "alt_text" => "Cover A"}] = option["media"]
  end

  test "a projection without media yields an empty list" do
    assert Media.list(%{"decision_id" => "dec_1"}) == []
    assert Media.list(nil) == []
  end
end
