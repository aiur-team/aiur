defmodule Aiur.Orchestrator.Deactivate.NilStateReconcileTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Reconciler

  describe "reconcile with nil / non-binary issue state (crash regression)" do
    # Live crash signature (from production logs):
    #   ** (FunctionClauseError) no function clause matching in
    #      Aiur.Orchestrator.active_issue_state?(nil, MapSet.new(...))
    #   ** (FunctionClauseError) no function clause matching in
    #      Aiur.Orchestrator.normalize_issue_state(nil)
    #
    # GitHub poll can return an Issue with state=nil whenever no
    # `agent:*` label is set. Each predicate guarded by
    # `when is_binary(state_name)` MUST also accept the non-binary
    # case or the entire orchestrator GenServer crashes on the next
    # reconcile/poll cycle.

    test "nil issue.state does not crash reconcile_issue_state cond" do
      issue_id = "issue-nil-state"
      issue_identifier = "NS-1"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      # State derives nil whenever no agent:* label is present on
      # the polled issue.
      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: nil,
        title: "label-less issue",
        description: "",
        labels: []
      }

      # Must NOT raise FunctionClauseError. State unchanged is fine —
      # the orchestrator just leaves the issue alone until a recognized
      # label appears.
      result = Reconciler.reconcile_running_issue_states([issue], state)

      assert result == state
    end

    test "empty string issue.state also survives" do
      issue_id = "issue-empty-state"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: "ES-1",
        state: "",
        title: "blank state",
        description: "",
        labels: []
      }

      result = Reconciler.reconcile_running_issue_states([issue], state)
      assert result == state
    end
  end
end
