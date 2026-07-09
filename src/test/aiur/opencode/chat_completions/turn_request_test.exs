defmodule Aiur.Opencode.ChatCompletions.TurnRequestTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.ChatCompletions.TurnRequest

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
