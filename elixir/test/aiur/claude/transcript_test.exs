defmodule Aiur.Claude.TranscriptTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.Transcript

  describe "extract/2" do
    test "returns :skip for any payload — Claude transcripts fall back to the legacy path" do
      assert Transcript.extract(%{event: :agent_message}, nil) == :skip
    end

    test "returns :skip for Claude-native item/created shapes" do
      message = %{
        payload: %{
          method: "item/created",
          params: %{turn_id: "t1", item: %{type: "text", text: "hi"}}
        }
      }

      assert Transcript.extract(message, "fallback") == :skip
    end

    test "returns :skip for string-keyed JSON shapes" do
      message = %{
        "payload" => %{
          "method" => "item/created",
          "params" => %{"turn_id" => "t1", "item" => %{"type" => "text", "text" => "hi"}}
        }
      }

      assert Transcript.extract(message, nil) == :skip
    end
  end
end
