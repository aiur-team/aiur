defmodule Aiur.Protocol.MapAccessTest do
  use ExUnit.Case, async: true

  alias Aiur.Protocol.MapAccess

  describe "get/2" do
    test "tolerates atom and string keyed maps" do
      assert MapAccess.get(%{event: "ok"}, :event) == "ok"
      assert MapAccess.get(%{"event" => "ok"}, :event) == "ok"
      assert MapAccess.get(:not_map, :event) == nil
    end
  end

  describe "dig/2" do
    test "walks exact keys and returns nil on missing paths" do
      assert MapAccess.dig(%{"a" => %{"b" => 1}}, ["a", "b"]) == 1
      assert MapAccess.dig(%{"a" => %{}}, ["a", "b"]) == nil
      assert MapAccess.dig(nil, ["a"]) == nil
    end
  end

  describe "notification helpers" do
    test "extract method and item from atom or string keyed payloads" do
      assert MapAccess.notification_method(%{payload: %{method: "item/completed"}}) ==
               "item/completed"

      assert MapAccess.notification_item(%{
               "payload" => %{"params" => %{"item" => %{"type" => "agentMessage"}}}
             }) == %{"type" => "agentMessage"}
    end

    test "params_turn_id rejects blanks and honors key parameterization" do
      assert MapAccess.params_turn_id(%{payload: %{params: %{turnId: "codex-turn"}}}, :turnId) ==
               "codex-turn"

      assert MapAccess.params_turn_id(%{payload: %{params: %{turn_id: "claude-turn"}}}, :turn_id) ==
               "claude-turn"

      assert MapAccess.params_turn_id(%{payload: %{params: %{turnId: ""}}}, :turnId) == nil
    end
  end

  describe "message_timestamp/1" do
    test "uses supplied DateTime or falls back to current UTC time" do
      timestamp = DateTime.utc_now()
      assert MapAccess.message_timestamp(%{timestamp: timestamp}) == timestamp

      before_call = DateTime.utc_now()
      fallback = MapAccess.message_timestamp(%{})
      after_call = DateTime.utc_now()

      assert DateTime.compare(fallback, before_call) in [:gt, :eq]
      assert DateTime.compare(fallback, after_call) in [:lt, :eq]
    end
  end
end
