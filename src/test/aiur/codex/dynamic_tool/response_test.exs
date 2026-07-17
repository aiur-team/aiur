defmodule Aiur.Codex.DynamicTool.ResponseTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.Response

  describe "build/2" do
    test "returns the expected envelope shape on success" do
      result = Response.build(true, "hello")

      assert result == %{
               "success" => true,
               "output" => "hello",
               "contentItems" => [%{"type" => "inputText", "text" => "hello"}]
             }
    end

    test "returns the expected envelope shape on failure" do
      result = Response.build(false, "oops")

      assert result == %{
               "success" => false,
               "output" => "oops",
               "contentItems" => [%{"type" => "inputText", "text" => "oops"}]
             }
    end
  end

  describe "failure/1" do
    test "sets success to false and encodes the payload" do
      result = Response.failure(%{"error" => %{"message" => "bad"}})
      assert result["success"] == false
      decoded = Jason.decode!(result["output"])
      assert decoded["error"]["message"] == "bad"
    end
  end

  describe "encode_payload/1" do
    test "pretty-prints a map" do
      encoded = Response.encode_payload(%{"a" => 1})
      assert is_binary(encoded)
      assert Jason.decode!(encoded) == %{"a" => 1}
      assert String.contains?(encoded, "\n")
    end

    test "pretty-prints a list" do
      encoded = Response.encode_payload([1, 2, 3])
      assert Jason.decode!(encoded) == [1, 2, 3]
    end

    test "falls back to inspect for non-JSON terms" do
      encoded = Response.encode_payload({:error, :boom})
      assert encoded == inspect({:error, :boom})
    end
  end

  describe "jsonable/1" do
    test "converts atoms to strings" do
      assert Response.jsonable(:ok) == "ok"
      assert Response.jsonable(:error) == "error"
    end

    test "preserves JSON-safe maps" do
      map = %{"key" => "value"}
      assert Response.jsonable(map) == map
    end

    test "preserves JSON-safe lists" do
      list = [1, 2, 3]
      assert Response.jsonable(list) == list
    end

    test "passes binaries through unchanged" do
      assert Response.jsonable("hello") == "hello"
    end

    test "recursively normalizes nested maps, lists, and tuples" do
      assert Response.jsonable(%{kind: :exit, detail: {:noproc, [GenServer, :call]}}) == %{
               "kind" => "exit",
               "detail" => ["noproc", ["Elixir.GenServer", "call"]]
             }
    end
  end
end
