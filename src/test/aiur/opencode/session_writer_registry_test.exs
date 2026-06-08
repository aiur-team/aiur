defmodule Aiur.Opencode.SessionWriterRegistryTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.SessionWriterRegistry

  describe "lookup/1" do
    test "returns :not_found for an unknown identifier" do
      assert SessionWriterRegistry.lookup("unknown-#{System.unique_integer([:positive])}") ==
               :not_found
    end
  end

  describe "all/0" do
    test "returns a list" do
      result = SessionWriterRegistry.all()
      assert is_list(result)
    end
  end

  describe "delete_all/1" do
    test "is a no-op on an empty registry" do
      assert SessionWriterRegistry.delete_all() == :ok
      assert SessionWriterRegistry.delete_all(100) == :ok
    end
  end
end
