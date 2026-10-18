defmodule Aiur.Orchestrator.CommentPolling.PlainInputsTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CommandScan, State, TrackerTasks}
  alias Aiur.Orchestrator.CommentPolling.{Cursor, Input, TargetSelection}

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      pr_watch_enabled: true
    )

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    :ok
  end

  test "plain cursor and input retain running, review, watch, and reconcile ordering" do
    updated_at = DateTime.utc_now() |> DateTime.to_iso8601()
    review_pr = %{"number" => 61, "updated_at" => updated_at}
    watch_pr = %{"number" => 99, "state" => "open"}
    cursor = %Cursor{since: %{}, reconcile_targets: MapSet.new(["77"])}
    input = %Input{running_targets: ["42"], running_titles: %{}, ownership_key: nil, next_github_delay_ms: 0}

    opts = [
      review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] ->
        {:ok, [%Issue{id: "57", identifier: "57", state: "human-review", updated_at: updated_at}]}
      end,
      review_pull_request_fetcher: fn "57" -> {:ok, review_pr} end,
      watch_pull_request_fetcher: fn "agent:watch" -> {:ok, [watch_pr]} end
    ]

    assert {:ok, ["42", "57", "99", "77"], [review_target], [watch_target]} =
             TargetSelection.github_comment_poll_targets(cursor, input, opts)

    assert review_target == %{
             target: "57",
             issue_updated_at: updated_at,
             updated_at: "issue=#{updated_at};pr=#{updated_at}",
             open_pull_request: review_pr
           }

    assert watch_target == %{target: "99", open_pull_request: watch_pr}
  end

  test "command scan refreshes both validators without changing comment target validators" do
    state = %State{
      snapshot_key: self(),
      github_comment_cursor: %Cursor{etags: %{"42" => "target-etag"}},
      github_command_scan_etags: %{command_scan_review: "old-review-etag", command_scan_issue: "old-issue-etag"}
    }

    pending =
      CommandScan.scan_pr_commands(state,
        command_scan_review_comment_fetcher: fn opts ->
          assert Keyword.fetch!(opts, :etag) == "old-review-etag"
          {:ok, [], "new-review-etag"}
        end,
        command_scan_issue_comment_fetcher: fn opts ->
          assert Keyword.fetch!(opts, :etag) == "old-issue-etag"
          {:ok, [], "new-issue-etag"}
        end
      )

    [ref] = Map.keys(pending.tracker_tasks)
    receive_barrier({^ref, result})
    assert {:handled, next} = TrackerTasks.result(pending, ref, result)

    assert next.tracker_tasks == %{}
    assert next.github_command_scan_etags == %{command_scan_review: "new-review-etag", command_scan_issue: "new-issue-etag"}
    assert next.github_comment_cursor.etags == %{"42" => "target-etag"}
  end
end
