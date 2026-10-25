defmodule Aiur.GitHub.Listeners.Comments.PlainInputsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Listeners.Comments.{Cursor, Input, TargetSelection}
  alias Aiur.Issue

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
end
