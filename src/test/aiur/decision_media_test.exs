defmodule Aiur.DecisionMediaTest do
  use ExUnit.Case, async: false

  alias Aiur.Commands.Media
  alias Aiur.{DecisionAnswer, DecisionProjection, DecisionValidation}
  alias Aiur.DecisionApi.PublicProjection

  @ticket %{identifier: "7486", title: "Rich media", url: "https://github.com/aiur-team/aiur/issues/7486"}

  # Replay re-validates a stored path against the *configured* safe roots, so
  # these fixtures live inside one rather than in the system temp directory.
  setup do
    base = Aiur.DecisionValidation.safe_roots() |> Enum.find(&(Path.type(&1) == :absolute))
    root = Path.join(base, "aiur-decision-media-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    %{root: root}
  end

  defp image(path) do
    %{
      "kind" => "image",
      "mime_type" => "image/png",
      "locator" => path,
      "alt_text" => "A local design reference",
      "width" => 640,
      "height" => 480
    }
  end

  describe "canonical request media" do
    test "keeps a text-only request hash byte-identical to the pre-media shape", %{root: root} do
      payload = %{
        "question" => "Q",
        "blocking" => false,
        "options" => [%{"id" => "a", "label" => "A"}, %{"id" => "b", "label" => "B"}]
      }

      assert {:ok, decision} = DecisionValidation.normalize(payload, ticket: @ticket, safe_roots: [root])
      assert decision.media == []
      assert Enum.all?(decision.options, &(&1.media == []))

      # Exactly the map the hash covered before the media contract existed:
      # no `media` key at all, and none on any option.
      legacy_content = %{
        question: "Q",
        authority: :supervisor_allowed,
        urgency: :normal,
        blocking: false,
        reversibility: :reversible,
        kind: nil,
        context: %{short_summary: nil, long_context_markdown: nil},
        options: [
          %{id: "a", label: "A", description: nil, benefits: nil, drawbacks: nil, risk: nil},
          %{id: "b", label: "B", description: nil, benefits: nil, drawbacks: nil, risk: nil}
        ],
        recommendation: nil,
        consequence_of_delay: nil,
        artifacts: []
      }

      assert decision.content_hash == DecisionValidation.content_hash(legacy_content)
    end

    test "accepts typed media on the prompt and on an option", %{root: root} do
      file = Path.join(root, "layout.png")
      File.write!(file, "png")

      assert {:ok, decision} =
               DecisionValidation.normalize(
                 %{
                   "question" => "Which layout?",
                   "blocking" => false,
                   "media" => [image(file)],
                   "options" => [
                     %{"id" => "a", "label" => "Dense", "media" => [image(file)]},
                     %{"id" => "b", "label" => "Sparse"}
                   ]
                 },
                 ticket: @ticket,
                 safe_roots: [root]
               )

      assert [prompt] = decision.media
      assert prompt.kind == :image
      assert prompt.locator.kind == :path
      assert [%{media: [option_media]}, %{media: []}] = decision.options
      assert option_media.attachment_id == prompt.attachment_id
    end

    test "rejects unsafe media at the canonical boundary", %{root: root} do
      assert {:error, {:decision_invalid, {:media, :locator_expires}}} =
               DecisionValidation.normalize(
                 %{
                   "question" => "Q",
                   "blocking" => false,
                   "media" => [%{"kind" => "image", "mime_type" => "image/png", "locator" => "https://bucket.s3.amazonaws.com/a.png?X-Amz-Signature=x", "alt_text" => "a"}]
                 },
                 ticket: @ticket,
                 safe_roots: [root]
               )

      assert {:error, {:decision_invalid, {:media, :mime_type_not_allowed}}} =
               DecisionValidation.normalize(
                 %{
                   "question" => "Q",
                   "blocking" => false,
                   "options" => [%{"id" => "a", "label" => "A", "media" => [%{"kind" => "audio", "mime_type" => "image/png", "locator" => "https://github.com/a/b.mp3"}]}]
                 },
                 ticket: @ticket,
                 safe_roots: [root]
               )
    end

    test "persists and replays the same media reference", %{root: root} do
      file = Path.join(root, "layout.png")
      File.write!(file, "png")

      assert {:ok, decision} =
               DecisionValidation.normalize(
                 %{"question" => "Q", "blocking" => false, "media" => [image(file)]},
                 ticket: @ticket,
                 safe_roots: [root]
               )

      persisted = decision |> DecisionProjection.to_json_safe() |> Jason.encode!() |> Jason.decode!()
      assert [%{"kind" => "image", "locator" => %{"kind" => "path"}}] = persisted["media"]

      assert {:ok, replayed} = DecisionProjection.decode_request_record(persisted, nil)
      assert replayed.content_hash == decision.content_hash
      assert [%{attachment_id: id, locator: %{kind: :path}}] = replayed.media
      assert id == hd(decision.media).attachment_id
    end

    test "the public projection hides local paths and keeps the metadata", %{root: root} do
      file = Path.join(root, "layout.png")
      File.write!(file, "png")

      assert {:ok, decision} =
               DecisionValidation.normalize(
                 %{
                   "question" => "Q",
                   "blocking" => false,
                   "media" => [image(file)],
                   "options" => [%{"id" => "a", "label" => "Dense", "media" => [image(file)]}]
                 },
                 ticket: @ticket,
                 safe_roots: [root]
               )

      encoded = PublicProjection.encode(decision)
      refute inspect(encoded) =~ root

      assert [media] = encoded["media"]
      assert media["kind"] == "image"
      assert media["mime_type"] == "image/png"
      assert media["alt_text"] == "A local design reference"
      assert media["width"] == 640
      assert media["locator"]["kind"] == "attachment"
      assert String.starts_with?(media["locator"]["attachment_id"], "med_")

      assert [option] = encoded["options"]
      assert [option_media] = option["media"]
      assert option_media["attachment_id"] == media["attachment_id"]
    end
  end

  describe "canonical answer media" do
    setup %{root: root} do
      file = Path.join(root, "evidence.png")
      File.write!(file, "png")

      {:ok, decision} =
        DecisionValidation.normalize(
          %{"question" => "Q", "blocking" => false, "media" => [image(file)]},
          ticket: @ticket,
          safe_roots: [root]
        )

      %{decision: decision}
    end

    defp answer_opts(decision) do
      [
        decision_id: decision.decision_id,
        decision_version: decision.version,
        options: decision.options,
        command_media: Media.index(decision.media, decision.options),
        actor: %{kind: :operator, id: "operator"},
        safe_roots: [Path.dirname(hd(decision.media).locator.value)]
      ]
    end

    test "accepts an attachment reference from the Command", %{decision: decision} do
      attachment_id = hd(decision.media).attachment_id

      assert {:ok, answer} =
               DecisionAnswer.normalize(
                 %{"idempotency_key" => "k1", "expected_version" => 1, "custom_response" => "Use this", "media" => [%{"attachment_id" => attachment_id, "caption" => "Chosen"}]},
                 answer_opts(decision)
               )

      assert [media] = answer.media
      assert media.attachment_id == attachment_id
      assert media.caption == "Chosen"
    end

    test "rejects an attachment the Command does not carry", %{decision: decision} do
      assert {:error, {:answer_invalid, {:media, :attachment_unknown}}} =
               DecisionAnswer.normalize(
                 %{"idempotency_key" => "k2", "expected_version" => 1, "custom_response" => "Use this", "media" => [%{"attachment_id" => "med_000000000000000000000000"}]},
                 answer_opts(decision)
               )
    end

    test "round trips through the durable answer shape", %{decision: decision} do
      attachment_id = hd(decision.media).attachment_id

      assert {:ok, answer} =
               DecisionAnswer.normalize(
                 %{"idempotency_key" => "k3", "expected_version" => 1, "custom_response" => "Use this", "media" => [%{"attachment_id" => attachment_id}]},
                 answer_opts(decision)
               )

      persisted = answer |> DecisionAnswer.to_json_safe() |> Jason.encode!() |> Jason.decode!()
      assert [_media] = persisted["media"]

      assert {:ok, replayed} = DecisionAnswer.from_json_safe(persisted)
      assert replayed.content_hash == answer.content_hash
      assert [%{attachment_id: ^attachment_id}] = replayed.media
    end

    test "an answer without media keeps the hash it had before the contract" do
      base = %{"idempotency_key" => "k4", "expected_version" => 1, "custom_response" => "Proceed"}
      opts = [decision_id: "dec", decision_version: 1, options: [], actor: %{kind: :operator, id: "operator"}]

      assert {:ok, with_absent_key} = DecisionAnswer.normalize(base, opts)
      assert {:ok, with_empty_list} = DecisionAnswer.normalize(Map.put(base, "media", []), opts)
      assert with_absent_key.content_hash == with_empty_list.content_hash
      assert with_absent_key.media == []
    end
  end

  describe "serving index" do
    test "resolves only the media the Command actually carries", %{root: root} do
      {:ok, decision} =
        DecisionValidation.normalize(
          %{"question" => "Q", "blocking" => false, "media" => [image(Path.join(root, "layout.png"))]},
          ticket: @ticket,
          safe_roots: [root]
        )

      attachment_id = hd(decision.media).attachment_id
      assert [%{attachment_id: ^attachment_id}] = Media.all_items(decision)
      assert :error = Media.find_attachment(Media.all_items(%{decision | media: []}), attachment_id)
    end
  end
end
