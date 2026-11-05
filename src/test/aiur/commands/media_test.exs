defmodule Aiur.Commands.MediaTest do
  use ExUnit.Case, async: false

  alias Aiur.Commands.Media

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-command-media")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    %{root: root}
  end

  defp image(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "image",
        "mime_type" => "image/png",
        "locator" => "https://raw.githubusercontent.com/aiur-team/aiur/main/shot.png",
        "alt_text" => "A dashboard screenshot"
      },
      overrides
    )
  end

  describe "normalize/2" do
    test "accepts typed media for every kind" do
      items = [
        image(),
        %{"kind" => "animated_image", "mime_type" => "image/gif", "locator" => "https://github.com/a/b/c.gif", "alt_text" => "Loop"},
        %{"kind" => "video", "mime_type" => "video/mp4", "locator" => "https://github.com/a/b/c.mp4", "caption" => "Walkthrough", "duration_ms" => 4_000, "poster" => "https://github.com/a/b/p.png"},
        %{"kind" => "audio", "mime_type" => "audio/mpeg", "locator" => "https://github.com/a/b/c.mp3", "caption" => "Narration"}
      ]

      assert {:ok, normalized} = Media.normalize(items, [])
      assert Enum.map(normalized, & &1.kind) == [:image, :animated_image, :video, :audio]
      assert Enum.all?(normalized, &String.starts_with?(&1.attachment_id, "med_"))
      assert Enum.map(normalized, & &1.attachment_id) == Enum.uniq(Enum.map(normalized, & &1.attachment_id))
    end

    test "keeps text-only requests free of media" do
      assert {:ok, []} = Media.normalize(nil, [])
      assert {:ok, []} = Media.normalize([], [])
    end

    test "rejects an unknown kind" do
      assert {:error, {:media, :invalid_kind}} = Media.normalize([image(%{"kind" => "hologram"})], [])
    end

    test "rejects a MIME type that does not belong to the kind" do
      assert {:error, {:media, :mime_type_not_allowed}} = Media.normalize([image(%{"mime_type" => "video/mp4"})], [])
      assert {:error, {:media, :mime_type_missing}} = Media.normalize([image(%{"mime_type" => nil})], [])
    end

    test "requires alt text for still and animated images" do
      assert {:error, {:media, :alt_text_required}} = Media.normalize([image(%{"alt_text" => nil})], [])
    end

    test "rejects an expiring signed URL instead of persisting it" do
      signed = "https://bucket.s3.amazonaws.com/shot.png?X-Amz-Signature=deadbeef&X-Amz-Expires=900"
      assert {:error, {:media, :locator_expires}} = Media.normalize([image(%{"locator" => signed})], [])
    end

    test "rejects a locator that is neither an allowlisted URL nor a bounded path", %{root: root} do
      assert {:error, {:media, :locator_not_allowed}} = Media.normalize([image(%{"locator" => "https://evil.example.com/x.png"})], [root])
      assert {:error, {:media, :locator_missing}} = Media.normalize([image(%{"locator" => nil})], [root])
      assert {:error, {:media, :artifact_path_outside_root}} = Media.normalize([image(%{"locator" => "/etc/passwd"})], [root])
    end

    test "rejects a byte size above the kind limit" do
      assert {:error, {:media, :too_large}} = Media.normalize([image(%{"byte_size" => Media.max_bytes(:image) + 1})], [])
    end

    test "rejects a poster on a still image" do
      assert {:error, {:media, :poster_not_allowed}} =
               Media.normalize([image(%{"poster" => "https://github.com/a/b/p.png"})], [])
    end

    test "rejects more than the item cap" do
      assert {:error, {:media, :too_many}} = Media.normalize(List.duplicate(image(), 9), [])
    end

    test "accepts a local file under a safe root", %{root: root} do
      file = Path.join(root, "shot.png")
      File.write!(file, "png")

      assert {:ok, [item]} = Media.normalize([image(%{"locator" => file})], [root])
      assert item.locator.kind == :path
    end
  end

  describe "public/1" do
    test "never exposes a local filesystem path", %{root: root} do
      file = Path.join(root, "shot.png")
      File.write!(file, "png")

      assert {:ok, [item]} = Media.normalize([image(%{"locator" => file})], [root])
      [public] = Media.public([item])

      assert public["locator"] == %{"kind" => "attachment", "attachment_id" => item.attachment_id}
      refute inspect(public) =~ root
      assert public["alt_text"] == "A dashboard screenshot"
      assert public["kind"] == "image"
    end

    test "passes a validated https locator through" do
      assert {:ok, [item]} = Media.normalize([image()], [])
      [public] = Media.public([item])

      assert public["locator"]["kind"] == "url"
      assert public["locator"]["value"] == "https://raw.githubusercontent.com/aiur-team/aiur/main/shot.png"
    end

    test "projects nothing for a non-list" do
      assert Media.public(nil) == []
    end
  end

  describe "answer media" do
    test "resolves an attachment the Command already carries" do
      assert {:ok, [prompt]} = Media.normalize([image()], [])
      index = Media.index([prompt], [])

      assert {:ok, [resolved]} = Media.normalize_answer([%{"attachment_id" => prompt.attachment_id, "caption" => "Same shot"}], index, [])
      assert resolved.attachment_id == prompt.attachment_id
      assert resolved.caption == "Same shot"
    end

    test "rejects an attachment the Command does not carry" do
      assert {:error, {:media, :attachment_unknown}} = Media.normalize_answer([%{"attachment_id" => "med_000000000000000000000000"}], %{}, [])
    end

    test "replays a persisted answer item without a Command index" do
      assert {:ok, [item]} = Media.normalize([image()], [])
      persisted = Media.to_json_safe([item])

      assert {:ok, [resolved]} = Media.normalize_answer(persisted, nil, [])
      assert resolved.attachment_id == item.attachment_id
    end
  end

  describe "find_attachment/2" do
    test "does not resolve an attachment from another Command" do
      assert {:ok, [item]} = Media.normalize([image()], [])

      assert {:ok, found} = Media.find_attachment([item], item.attachment_id)
      assert found.attachment_id == item.attachment_id
      assert Media.find_attachment([], item.attachment_id) == :error
    end
  end
end
