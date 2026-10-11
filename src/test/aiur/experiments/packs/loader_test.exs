defmodule Aiur.Experiments.Packs.LoaderTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Packs.Loader

  setup do
    root = Path.join(System.tmp_dir!(), "pack-loader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "packs"))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  defp pack(id \\ "app") do
    %{
      "schema_version" => 1,
      "id" => id,
      "version" => "1",
      "metrics" => [
        %{
          "id" => "latency",
          "label" => "Latency",
          "unit" => "ms",
          "unit_of_analysis" => "deploy",
          "kind" => "duration",
          "better" => "lower",
          "default_direction" => "decrease",
          "group" => "app",
          "requires" => [],
          "source" => %{"kind" => "event_interval", "start" => "app.deploy.started", "end" => "app.deploy.finished", "unit_key" => "/id", "attrs" => %{"branch" => "/branch"}}
        }
      ]
    }
  end

  test "bad file does not hide valid packs; reserved names are rejected", %{root: root} do
    File.write!(Path.join(root, "packs/app.json"), Jason.encode!(pack()))
    File.write!(Path.join(root, "packs/broken.json"), "not json")
    File.write!(Path.join(root, "packs/collision.json"), Jason.encode!(pack("delivery-speed")))
    {packs, problems} = Loader.load(root, ["packs"])
    assert packs["app"]["metrics"] |> hd() |> Map.fetch!(:id) == "latency"
    refute Map.has_key?(packs, "delivery-speed")
    assert Enum.map(problems, &Path.basename(&1.file)) == ["broken.json", "collision.json"]
  end

  test "directory traversal and symlink escapes are rejected", %{root: root} do
    File.ln_s!(Path.dirname(root), Path.join(root, "escape"))
    assert {packs, [_]} = Loader.load(root, ["../packs"])
    assert packs == %{}
    assert {packs, [_]} = Loader.load(root, ["escape"])
    assert packs == %{}
    File.ln_s!(Path.join(root, "../outside.json"), Path.join(root, "packs/outside.json"))
    assert {packs, [_]} = Loader.load(root, ["packs"])
    assert packs == %{}
  end

  test "rejects unsafe sources and malformed JSON pointers" do
    for source <- [
          %{"kind" => "ndjson", "path" => "../secret"},
          %{"kind" => "script", "argv" => "sh script", "cwd" => "repo"},
          %{"kind" => "event_interval", "start" => "app.start", "end" => "app.end", "unit_key" => "/id~7"},
          %{"kind" => "event_count", "match" => "app.event", "unit_key" => "/id", "per" => "hour"}
        ] do
      attrs = put_in(pack(), ["metrics", Access.at(0), "source"], source)
      assert {:error, [_ | _]} = Loader.validate(attrs)
    end
  end
end
