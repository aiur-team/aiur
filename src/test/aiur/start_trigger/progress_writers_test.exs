defmodule Aiur.StartTrigger.ProgressWritersTest do
  use Aiur.TestSupport
  alias Aiur.Events.GithubFirehose
  alias Aiur.Orchestrator.{CiLifecycle, State}
  alias Aiur.StartTrigger.ProgressStore

  test "CI lifecycle's passed_heads update also records progress" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    id = "#{System.unique_integer([:positive])}"
    issue = %Aiur.Issue{id: id, identifier: id, state: "human-review", title: "CI progress"}

    next =
      CiLifecycle.poll_github_ci(%State{},
        ci_issue_fetcher: fn _states -> {:ok, [issue]} end,
        ci_poller: fn [^id], _opts -> {:ok, %{results: [%{target: id, decision: :passed, head_sha: "passed-head", pr_number: 99}], errors: []}} end,
        parked_ready_alert_loader: fn -> MapSet.new() end,
        draft_stall_alert_loader: fn -> MapSet.new() end
      )

    assert next.ci_lifecycle.passed_heads[id] == "passed-head"
    :sys.get_state(ProgressStore)
    assert %{pr_number: 99, stage: :pr_ci_green} = ProgressStore.lookup(id)
  end

  test "existing recent-merge event poll records the ticket's merged stage" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    id = "#{System.unique_integer([:positive])}"

    event = %{
      "id" => "merge-event-#{id}",
      "type" => "PullRequestEvent",
      "created_at" => "2026-10-09T10:00:00Z",
      "repo" => %{"name" => "owner/repo"},
      "actor" => %{"login" => "reviewer"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 101,
          "merged" => true,
          "merged_at" => "2026-10-09T10:00:00Z",
          "html_url" => "https://github.com/owner/repo/pull/101",
          "head" => %{"ref" => "aiur/#{id}-progress", "sha" => "head"}
        }
      }
    }

    assert {:ok, _result} =
             GithubFirehose.poll(
               request_fun: fn _request -> {:ok, %{status: 200, body: [event], headers: []}} end,
               recent_merge_fun: fn merge -> {:ok, %{status: :accepted, merge: merge}} end,
               boot_time: 0
             )

    :sys.get_state(ProgressStore)
    assert %{pr_number: 101, stage: :pr_merged} = ProgressStore.lookup(id)
  end
end
