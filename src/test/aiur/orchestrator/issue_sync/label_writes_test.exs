defmodule Aiur.Orchestrator.IssueSync.LabelWritesTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.IssueSync.LabelWrites

  test "label healing is limited to issues in this tracker's observed scope" do
    issue = %Issue{id: "42", identifier: "agent:42", state: "todo"}
    parent = self()

    update_fun =
      LabelWrites.guarded_update_fun([issue], fn selected, target ->
        send(parent, {:state_write, selected.identifier, target})
        :ok
      end)

    assert :ok = update_fun.(issue.identifier, "in-progress")
    assert_receive {:state_write, "agent:42", "in-progress"}, 100

    assert {:error, :outside_tracker_scope} = update_fun.("infra:99", "in-progress")
    refute_receive {:state_write, "infra:99", _target}, 100
  end
end
