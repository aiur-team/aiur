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

  test "native prerequisites come from the configured issue" do
    Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "42", identifier: "42", blocked_by: [%{id: "7", state: "open"}]}])
    assert Tracker.blocked_by("42") == {:ok, ["7"]}
    assert Tracker.blocked_by("missing") == {:error, :issue_not_found}
  end

  test "added issues are visible to candidate polling and announce the seed" do
    Application.put_env(:aiur, :memory_tracker_issues, [])
    issue = %Issue{id: "seed-1", identifier: "DEMO-1", title: "Seeded", state: "todo", labels: ["agent:todo"]}

    assert :ok = Tracker.add_issue(issue)
    assert {:ok, [^issue]} = Tracker.fetch_candidate_issues()
    assert_received {:memory_tracker_issue_added, ^issue}
  end

  test "added issues reject duplicate ids and identifiers" do
    existing = %Issue{id: "seed-1", identifier: "DEMO-1"}
    Application.put_env(:aiur, :memory_tracker_issues, [existing])

    assert {:error, :duplicate_id} = Tracker.add_issue(%Issue{id: "seed-1", identifier: "DEMO-2"})
    assert {:error, :duplicate_identifier} = Tracker.add_issue(%Issue{id: "seed-2", identifier: "DEMO-1"})
    assert {:ok, [^existing]} = Tracker.fetch_candidate_issues()
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
