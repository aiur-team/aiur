defmodule Aiur.AgentRunner.TurnLoopTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnLoop

  describe "turn_done_reason/1" do
    test "maps coding-agent turn results to stream close reasons" do
      assert TurnLoop.turn_done_reason({:ok, %{}}) == :done
      assert TurnLoop.turn_done_reason({:paused, %{}}) == :input_required
      assert TurnLoop.turn_done_reason({:error, :boom}) == {:failed, :boom}
      assert TurnLoop.turn_done_reason(:other) == :done
    end
  end

  describe "max_turns_display/1" do
    test "renders nil as infinity and integers as strings" do
      assert TurnLoop.max_turns_display(nil) == "∞"
      assert TurnLoop.max_turns_display(3) == "3"
    end
  end
end
