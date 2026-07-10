defmodule Aiur.Orchestrator.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State

  describe "reconcile_running_issue_states/4" do
    test "returns state unchanged for empty list" do
      state = %State{running: %{"issue-1" => %{pid: self()}}}
      active = MapSet.new(["todo"])
      terminal = MapSet.new(["done"])

      assert Reconciler.reconcile_running_issue_states([], state, active, terminal) == state
    end
  end

  describe "reconcile_issue_state/4" do
    test "returns state unchanged for non-Issue first arg" do
      state = %State{}
      active = MapSet.new(["todo"])
      terminal = MapSet.new(["done"])

      assert Reconciler.reconcile_issue_state(:not_an_issue, state, active, terminal) == state
      assert Reconciler.reconcile_issue_state(nil, state, active, terminal) == state
      assert Reconciler.reconcile_issue_state(%{}, state, active, terminal) == state
    end
  end

  describe "refresh_running_issue_state/2" do
    test "updates the stored issue in the running entry" do
      old_issue = %Issue{id: "issue-1", identifier: "repo#1", title: "old", state: "todo"}
      new_issue = %Issue{id: "issue-1", identifier: "repo#1", title: "new", state: "in-progress"}

      state = %State{
        running: %{"issue-1" => %{pid: self(), issue: old_issue}}
      }

      result = Reconciler.refresh_running_issue_state(state, new_issue)
      assert get_in(result.running, ["issue-1", :issue]) == new_issue
    end

    test "returns state unchanged when issue_id is not running" do
      issue = %Issue{id: "issue-x", identifier: "repo#x", title: "t", state: "todo"}
      state = %State{running: %{}}

      assert Reconciler.refresh_running_issue_state(state, issue) == state
    end
  end

  describe "reconcile_missing_running_issue_ids/3" do
    test "returns state unchanged when all requested ids are visible" do
      issue = %Issue{id: "issue-1", identifier: "repo#1", title: "t", state: "todo"}

      state = %State{
        running: %{"issue-1" => %{pid: self(), identifier: "repo#1"}},
        claimed: MapSet.new(["issue-1"])
      }

      assert Reconciler.reconcile_missing_running_issue_ids(state, ["issue-1"], [issue]) == state
    end

    test "returns state unchanged for non-State first arg" do
      assert Reconciler.reconcile_missing_running_issue_ids(:not_state, [], []) == :not_state
    end

    test "ignores non-Issue entries in the issues list" do
      state = %State{
        running: %{"issue-1" => %{pid: self(), identifier: "repo#1"}},
        claimed: MapSet.new(["issue-1"])
      }

      issue = %Issue{id: "issue-1", identifier: "repo#1", title: "t", state: "todo"}
      issues = [issue, :bad_entry, nil]

      assert Reconciler.reconcile_missing_running_issue_ids(state, ["issue-1"], issues) == state
    end
  end
end
