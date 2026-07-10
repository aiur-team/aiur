defmodule Aiur.Opencode.ChatCompletions.TurnStreamTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Opencode.ChatCompletions.TurnStream

  describe "stream/3" do
    test "phantom turn (no ActiveTurns entry) closes with finish_reason stop" do
      identifier = "phantom-#{System.unique_integer()}"

      # No ActiveTurns.put → lookup returns :not_found → finalize_stream(:done) → "stop"
      result = TurnStream.stream(conn(:post, "/"), identifier, "phantom-abc")

      assert result.status == 200
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end

    test "late close ({:closed, reason}) renders the reason content then closes with stop" do
      identifier = "late-#{System.unique_integer()}"
      turn_id = "late-turn-#{System.unique_integer()}"

      :ok = ActiveTurns.put(identifier, turn_id)
      :ok = ActiveTurns.mark_closed(identifier, turn_id, {:failed, :boom})

      result = TurnStream.stream(conn(:post, "/"), identifier, turn_id)

      assert result.status == 200
      # finalize_stream({:failed, reason}) chunks the inspect(reason) before "stop"
      assert result.resp_body =~ "boom"
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end
  end
end
