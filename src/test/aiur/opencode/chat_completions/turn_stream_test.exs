defmodule Aiur.Opencode.ChatCompletions.TurnStreamTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Aiur.AgentRunner.TurnLoop
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

    test "a correlated operator pause renders resume guidance without claiming an approval" do
      identifier = "paused-#{System.unique_integer()}"
      turn_id = "paused-turn-#{System.unique_integer()}"
      result = {:paused, %{control: %{request_id: 77, generation: 4}}}
      reason = TurnLoop.turn_done_reason(result)

      assert reason == :paused
      :ok = ActiveTurns.put(identifier, turn_id)
      :ok = ActiveTurns.mark_closed(identifier, turn_id, reason)
      response = TurnStream.stream(conn(:post, "/"), identifier, turn_id)

      assert response.resp_body =~ "Agent is paused. Resume the agent to continue."
      refute response.resp_body =~ "approval"
      assert response.resp_body =~ ~s("finish_reason":"stop")
    end

    test "an :input_required late close renders the approval notice" do
      identifier = "await-#{System.unique_integer()}"
      turn_id = "await-turn-#{System.unique_integer()}"

      :ok = ActiveTurns.put(identifier, turn_id)
      :ok = ActiveTurns.mark_closed(identifier, turn_id, :input_required)

      result = TurnStream.stream(conn(:post, "/"), identifier, turn_id)

      assert result.status == 200
      # finalize_stream(:input_required) chunks the awaiting-approval notice.
      assert result.resp_body =~ "awaiting approval"
    end
  end
end
