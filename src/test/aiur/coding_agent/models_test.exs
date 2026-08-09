defmodule Aiur.CodingAgent.ModelsTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent.Models

  describe "parse/1" do
    test "splits a tiered id into prefix, numeric version, and tier" do
      assert {:ok, %{prefix: "gpt", version: [5, 6], tier: "sol"}} = Models.parse("gpt-5.6-sol")
    end

    test "a versioned id with no tier carries no tier" do
      assert {:ok, %{prefix: "gpt", version: [5, 5], tier: nil}} = Models.parse("gpt-5.5")
    end

    test "an id that is not prefix-version[-tier] is not forced into the grammar" do
      # Anything unparseable must stay usable as an explicit pin; misreading it
      # would invent a family and let an alias hijack a deliberate choice.
      assert Models.parse("o3") == :error
      assert Models.parse("gpt-sol") == :error
      assert Models.parse("gpt-5.6-sol-preview") == :error
      assert Models.parse(nil) == :error
    end
  end

  describe "aliases/1" do
    test "one alias per family, in the order the list introduces them" do
      # List order is the registry's most-capable-first intent, and it is the
      # order labels are seeded and init offers models in.
      assert Models.aliases(["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.5", "gpt-5.4", "gpt-5.5-mini"]) ==
               ["sol", "terra", "gpt", "mini"]
    end

    test "unparseable ids contribute no alias" do
      assert Models.aliases(["o3", "gpt-5.6-sol"]) == ["sol"]
    end

    test "a family name that is also a concrete model id is not offered as an alias" do
      # Otherwise resolving the alias would redirect a pin that names the very
      # same string, quietly changing which model runs.
      assert Models.aliases(["sol", "gpt-5.6-sol"]) == []
    end
  end

  describe "latest/2" do
    @models ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.5-mini", "gpt-5.4-mini"]

    test "resolves a family to its highest version" do
      assert Models.latest(@models, "sol") == "gpt-5.6-sol"
      assert Models.latest(@models, "mini") == "gpt-5.5-mini"
      assert Models.latest(@models, "gpt") == "gpt-5.5"
    end

    test "a newly released version takes over its family with no code change" do
      # This is the whole point: a routing table pinned to a family must follow
      # the provider, not the release this repo happened to be edited on.
      assert Models.latest(["gpt-5.7-sol" | @models], "sol") == "gpt-5.7-sol"
    end

    test "compares version segments numerically, not as text" do
      assert Models.latest(["gpt-5.9-sol", "gpt-5.10-sol"], "sol") == "gpt-5.10-sol"
    end

    test "a concrete model id resolves to nil so callers pass the pin through" do
      assert Models.latest(@models, "gpt-5.4") == nil
      assert Models.latest(@models, "unheard-of") == nil
      assert Models.latest(@models, nil) == nil
    end
  end
end
