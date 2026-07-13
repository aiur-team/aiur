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

  describe "return_completed/2" do
    test "returns the final boundary for publication after outer cleanup" do
      issue = %Aiur.Issue{id: "issue-completed"}

      assert {:completed, ^issue} =
               TurnLoop.return_completed(%{codex_update_recipient: self()}, issue)

      refute_receive {:worker_control_state, "issue-completed", :completed}
    end
  end

  describe "continue_after_resume/2" do
    test "returns a completed boundary when max turns were already reached" do
      issue = %Aiur.Issue{id: "issue-max", identifier: "MT-MAX", state: "In Progress"}
      refreshed = %{issue | state: "In Progress"}

      context = %{
        issue: issue,
        issue_state_fetcher: fn ["issue-max"] -> {:ok, [refreshed]} end,
        max_turns: 1,
        turn_number: 1
      }

      assert {:completed, ^refreshed} = TurnLoop.continue_after_resume(context, %{})
    end

    test "returns a completed boundary when the refreshed issue is inactive" do
      issue = %Aiur.Issue{id: "issue-done", identifier: "MT-DONE", state: "In Progress"}
      refreshed = %{issue | state: "Done"}

      context = %{
        issue: issue,
        issue_state_fetcher: fn ["issue-done"] -> {:ok, [refreshed]} end,
        max_turns: 3,
        turn_number: 1
      }

      assert {:completed, ^refreshed} = TurnLoop.continue_after_resume(context, %{})
    end
  end
end
