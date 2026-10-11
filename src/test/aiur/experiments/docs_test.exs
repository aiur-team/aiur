defmodule Aiur.Experiments.DocsTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Catalog, Packs.Loader}
  @fixture Path.expand("../../fixtures/experiments/consumer_repo", __DIR__)
  @docs Path.expand("../../../../website/docs-app/concepts/experiments.md", __DIR__)

  test "the worked documentation pack is the consumer fixture and loads without code changes" do
    doc = File.read!(@docs)
    [_, json] = Regex.run(~r/<!-- consumer-pack-example -->\s*```json\s*(.*?)\s*```\s*<!-- \/consumer-pack-example -->/s, doc)
    pack = Jason.decode!(json)
    assert pack == Jason.decode!(File.read!(Path.join(@fixture, ".aiur/experiments/packs/app.json")))
    assert {:ok, loaded} = Loader.validate(pack)
    assert Enum.map(loaded["metrics"], & &1.id) == ["deploy_latency", "request_latency"]
    catalog = Catalog.load(%{repo_path: @fixture, builtin_packs: []})
    assert catalog.problems == []
    assert Map.keys(catalog.metrics) |> Enum.sort() == ["app/deploy_latency", "app/request_latency"]
  end
end
