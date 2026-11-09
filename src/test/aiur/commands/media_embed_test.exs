defmodule Aiur.Commands.MediaEmbedTest do
  use Aiur.TestSupport

  alias Aiur.Commands.Media
  alias Aiur.Config.Schema
  alias Aiur.ControlCLI.MediaSpec
  alias Aiur.Workflow

  @url "https://play.example.com/builds/42/index.html"

  setup do
    allow_embed_hosts(["play.example.com"])
    :ok
  end

  defp allow_embed_hosts(hosts) do
    write_workflow_file!(Workflow.workflow_file_path(), [])
    File.write!(Workflow.workflow_file_path(), "\ndecisions: {embed_hosts: #{Jason.encode!(hosts)}}\n", [:append])
    assert :ok = Aiur.WorkflowStore.force_reload()
  end

  defp embed(overrides \\ %{}) do
    Map.merge(%{"kind" => "embed", "locator" => @url, "alt_text" => "Level 3 playable build"}, overrides)
  end

  test "an embed from an allowlisted host validates with params and a duration hint" do
    item = embed(%{"params" => %{"level" => 3, "mode" => "demo"}, "duration_hint" => 90})

    assert {:ok, [normalized]} = Media.normalize([item], [])
    assert normalized.kind == :embed
    assert normalized.mime_type == "text/html"
    assert normalized.locator == %{kind: :url, value: @url <> "?level=3&mode=demo"}
    assert normalized.duration_ms == 90_000
    assert normalized.alt_text == "Level 3 playable build"
  end

  test "params extend an existing query and keep the fragment" do
    item = embed(%{"locator" => "https://play.example.com/run?build=7#start", "params" => %{"seed" => "abc"}})

    assert {:ok, [%{locator: %{value: "https://play.example.com/run?build=7&seed=abc#start"}}]} = Media.normalize([item], [])
  end

  test "each unsafe locator is refused with a stable error" do
    cases = [
      {"https://elsewhere.example.org/game", :locator_not_allowed},
      {"http://play.example.com/game", :locator_not_allowed},
      {"https://user:pass@play.example.com/game", :locator_not_allowed},
      {"https://play.example.com/game?X-Amz-Expires=300&X-Amz-Signature=abc", :locator_expires},
      {"/tmp/game/index.html", :locator_not_allowed}
    ]

    for {url, reason} <- cases do
      assert Media.normalize([embed(%{"locator" => url})], []) == {:error, {:media, reason}}, url
    end
  end

  test "a signed-expiry query added through params is refused" do
    assert Media.normalize([embed(%{"params" => %{"expires" => "1700000000"}})], []) == {:error, {:media, :locator_expires}}
  end

  test "malformed params, missing alt text and a byte size are refused" do
    assert Media.normalize([embed(%{"params" => %{"level" => %{"nested" => 1}}})], []) == {:error, {:media, :params_invalid}}
    assert Media.normalize([embed(%{"params" => "level=3"})], []) == {:error, {:media, :params_invalid}}
    assert Media.normalize([embed(%{"alt_text" => nil})], []) == {:error, {:media, :alt_text_required}}
    assert Media.normalize([embed(%{"byte_size" => 10})], []) == {:error, {:media, :byte_size_invalid}}
    assert Media.normalize([embed(%{"duration_hint" => -1})], []) == {:error, {:media, :duration_invalid}}
  end

  test "embeds are off while decisions.embed_hosts is empty, even for artifact-allowlisted hosts" do
    allow_embed_hosts([])

    assert Media.normalize([embed(%{"locator" => "https://github.com/aiur-team/aiur"})], []) == {:error, {:media, :locator_not_allowed}}
    assert Media.normalize([embed()], []) == {:error, {:media, :locator_not_allowed}}
  end

  test "an embed host does not widen the allowlist for images" do
    image = %{"kind" => "image", "mime_type" => "image/png", "locator" => "https://play.example.com/a.png", "alt_text" => "Shot"}

    assert Media.normalize([image], []) == {:error, {:media, :locator_not_allowed}}
  end

  test "the durable shape replays to the same item" do
    assert {:ok, [item]} = Media.normalize([embed(%{"params" => %{"level" => 3}, "duration_hint" => 30})], [])

    assert {:ok, [^item]} = Media.normalize(Media.to_json_safe([item]), [])
  end

  test "the public projection republishes an embed only while its host stays allowlisted" do
    assert {:ok, [item]} = Media.normalize([embed()], [])
    assert [%{"kind" => "embed", "locator" => %{"kind" => "url", "value" => @url}}] = Media.public([item])

    allow_embed_hosts([])

    assert [%{"kind" => "embed", "locator" => nil}] = Media.public([item])
  end

  test "decisions.embed_hosts defaults to empty and accepts only bare host names" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.decisions.embed_hosts == []

    assert {:ok, settings} = Schema.parse(%{"decisions" => %{"embed_hosts" => [" Play.Example.com ", "itch.io"]}})
    assert settings.decisions.embed_hosts == ["itch.io", "play.example.com"]

    for bad <- ["https://play.example.com", "*.example.com", "play.example.com/x", "localhost"] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"decisions" => %{"embed_hosts" => [bad]}})
      assert message =~ "decisions.embed_hosts", bad
    end
  end

  test "the CLI --media spec builds an option-bound embed that validates" do
    assert {:ok, {"a", item}} = MediaSpec.parse(@url <> ",kind=embed,alt=Play level 3,option=a")
    assert item == %{locator: @url, kind: "embed", alt_text: "Play level 3"}

    assert {:ok, [%{kind: :embed, mime_type: "text/html"}]} = Media.normalize([item], [])
  end
end
