defmodule Aiur.Opencode.ChatCompletions.TurnRequestTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.ChatCompletions.TurnRequest

  describe "validate_body/1" do
    test "returns body_too_large when body exceeds 65,536 bytes" do
      big = String.duplicate("x", 65_537)
      assert TurnRequest.validate_body(big) == {:error, :body_too_large}
    end

    test "returns invalid_utf8 for non-UTF-8 binary" do
      assert TurnRequest.validate_body(<<0xFF, 0xFE>>) == {:error, :invalid_utf8}
    end

    test "strips control chars but preserves tab and newline" do
      # [\x00-\x08\x0B-\x1F] strips all C0 control chars except HT (\x09)
      # and LF (\x0A); CR (\x0D) is in the \x0B-\x1F range and is stripped.
      assert TurnRequest.validate_body("hello\x01world") == {:ok, "helloworld"}
      assert TurnRequest.validate_body("a\tb") == {:ok, "a\tb"}
      assert TurnRequest.validate_body("a\nb") == {:ok, "a\nb"}
    end

    test "returns ok for clean text" do
      assert TurnRequest.validate_body("hello") == {:ok, "hello"}
    end
  end

  describe "trailing_user_texts/1 (coalescing defenses)" do
    test "collects only the user run since the last assistant message" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "old question"},
          %{"role" => "assistant", "content" => "old answer"},
          %{"role" => "user", "content" => "fix the tests"},
          %{"role" => "user", "content" => "__aiur_turn__:t1abc-s2"}
        ]
      }

      assert TurnRequest.trailing_user_texts(body) == [
               "fix the tests",
               "__aiur_turn__:t1abc-s2"
             ]
    end

    test "parts-shaped content is flattened" do
      body = %{
        "messages" => [
          %{"role" => "assistant", "content" => "x"},
          %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}
        ]
      }

      assert TurnRequest.trailing_user_texts(body) == ["hello"]
    end

    test "no trailing user run yields an empty list" do
      assert TurnRequest.trailing_user_texts(%{"messages" => [%{"role" => "assistant", "content" => "x"}]}) ==
               []

      assert TurnRequest.trailing_user_texts(%{}) == []
    end
  end
end
