defmodule Aiur.Orchestrator.RetryEngine.ExhaustionDraftTest do
  use Aiur.TestSupport

  alias Aiur.Config
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State

  # Open-Games #286/#302/#310 sat in ci-wait behind draft PRs: nothing marks a
  # draft ready from there. Rework gives a fresh agent the PR to finish.
  test "an advanced draft PR hands exhaustion back to rework, not ci-wait" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory", opencode_command: System.find_executable("true"))
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    identifier = "MT-REWORK-DRAFT"

    RetryEngine.schedule_issue_retry(%State{}, "issue-rework-draft", Config.max_retry_attempts() + 1, %{
      identifier: identifier,
      error: "agent exited: no-op continuation",
      rework_head_sha: "old-head",
      open_pr_fetcher: fn _ -> {:ok, %{"draft" => true, "head" => %{"sha" => "new-head"}}} end,
      commit_ci_status_fetcher: fn _ ->
        {:ok, %{check_runs: [%{"status" => "queued", "conclusion" => nil}], commit_status: %{"state" => "pending"}}}
      end,
      delay_type: :failure
    })

    assert_receive {:memory_tracker_state_update, ^identifier, "rework"}, 200
    refute_receive {:memory_tracker_state_update, ^identifier, "ci-wait"}, 100
  end
end
