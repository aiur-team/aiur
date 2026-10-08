defmodule Aiur.MemoryTrackerTest do
  use ExUnit.Case, async: false
  alias Aiur.{Issue, Memory.Tracker}

  setup do
    previous_issues = Application.get_env(:aiur, :memory_tracker_issues)
    previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
    Application.put_env(:aiur, :memory_tracker_recipient, self())

    on_exit(fn ->
      for {key, value} <- [memory_tracker_issues: previous_issues, memory_tracker_recipient: previous_recipient] do
        if value == nil, do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, value)
      end
    end)

    :ok
  end

  test "expected_state :none only matches an issue with no state" do
    Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "42", identifier: "42", state: nil}])
    assert :ok = Tracker.update_issue_state("42", "todo", expected_state: :none)
    assert {:ok, [%Issue{state: "todo"}]} = Tracker.fetch_issue_states_by_ids(["42"])
    assert_received {:memory_tracker_state_update, "42", "todo"}
    assert {:error, {:stale_issue_state, :none, "todo"}} = Tracker.update_issue_state("42", "in-progress", expected_state: :none)
    assert {:ok, [%Issue{state: "todo"}]} = Tracker.fetch_issue_states_by_ids(["42"])
    refute_received {:memory_tracker_state_update, _, _}
  end
end
