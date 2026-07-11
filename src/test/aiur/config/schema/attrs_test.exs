defmodule Aiur.Config.Schema.AttrsTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.Attrs

  describe "normalize_key/1" do
    test "converts atoms to strings" do
      assert Attrs.normalize_key(:foo) == "foo"
    end

    test "passes strings through" do
      assert Attrs.normalize_key("bar") == "bar"
    end

    test "converts other values via to_string" do
      assert Attrs.normalize_key(42) == "42"
    end
  end

  describe "normalize_keys/1" do
    test "stringifies all keys in a flat map" do
      assert Attrs.normalize_keys(%{foo: "bar", baz: 1}) == %{"foo" => "bar", "baz" => 1}
    end

    test "stringifies keys recursively in nested maps" do
      assert Attrs.normalize_keys(%{outer: %{inner: "val"}}) == %{"outer" => %{"inner" => "val"}}
    end

    test "maps list elements recursively" do
      assert Attrs.normalize_keys([%{key: "v"}]) == [%{"key" => "v"}]
    end

    test "passes non-map/list values through" do
      assert Attrs.normalize_keys("plain") == "plain"
      assert Attrs.normalize_keys(42) == 42
      assert Attrs.normalize_keys(nil) == nil
    end
  end

  describe "normalize_optional_map/1" do
    test "returns nil for nil input" do
      assert Attrs.normalize_optional_map(nil) == nil
    end

    test "normalizes map keys" do
      assert Attrs.normalize_optional_map(%{key: "v"}) == %{"key" => "v"}
    end
  end

  describe "drop_nil_values/1" do
    test "drops nil values from a flat map" do
      assert Attrs.drop_nil_values(%{"a" => 1, "b" => nil}) == %{"a" => 1}
    end

    test "drops nil values from nested maps" do
      assert Attrs.drop_nil_values(%{"outer" => %{"inner" => nil, "keep" => 1}}) ==
               %{"outer" => %{"keep" => 1}}
    end

    test "preserves explicit null for agent.max_load_average (FI-CFG-054)" do
      result = Attrs.drop_nil_values(%{"agent" => %{"max_load_average" => nil}})
      assert result == %{"agent" => %{"max_load_average" => nil}}
    end

    test "drops other nil values under agent" do
      result = Attrs.drop_nil_values(%{"agent" => %{"kind" => nil, "max_load_average" => 1.5}})
      assert result == %{"agent" => %{"max_load_average" => 1.5}}
    end

    test "maps list elements recursively" do
      assert Attrs.drop_nil_values([%{"a" => nil, "b" => 1}]) == [%{"b" => 1}]
    end
  end

  describe "preserve_nil_path?/1" do
    test "returns true for the agent max_load_average path" do
      assert Attrs.preserve_nil_path?(["agent", "max_load_average"]) == true
    end

    test "returns false for all other paths" do
      assert Attrs.preserve_nil_path?(["agent", "kind"]) == false
      assert Attrs.preserve_nil_path?([]) == false
      assert Attrs.preserve_nil_path?(["agent"]) == false
    end
  end
end
