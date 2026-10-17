defmodule Aiur.ExecutorSweep.SnapshotCacheTest do
  use ExUnit.Case, async: true

  alias Aiur.ExecutorSweep.SnapshotCache

  test "joins cached PR bodies, current-head reviews, and ticket labels without a fetch" do
    snapshot =
      SnapshotCache.build(
        [
          {4447,
           %{
             "state" => "open",
             "draft" => false,
             "head" => %{"ref" => "aiur/4429-handback-loop", "sha" => "head-now"},
             "created_at" => "2026-10-14T19:08:00Z"
           }}
        ],
        [{4447, [%{"commit_id" => "old-head"}]}],
        [{4429, [%{"name" => "agent:human-review"}]}]
      )

    assert [%{number: 4447, issue_number: 4429, head_sha: "head-now", reviewed_head_sha: nil, state: "open", draft: false}] =
             snapshot.pull_requests

    assert [%{number: 4429, labels: [%{"name" => "agent:human-review"}]}] = snapshot.tickets
  end

  test "counts a cached review only when it is for the current head" do
    pr = %{"head" => %{"ref" => "aiur/9-fix", "sha" => "current"}, "state" => "open", "draft" => false}

    assert [%{reviewed_head_sha: "current"}] =
             SnapshotCache.build([{3, pr}], [{3, [%{"commit_id" => "current"}]}], []).pull_requests
  end

  test "joins branch-cached approval metadata without another GitHub read" do
    pr = %{"head" => %{"ref" => "aiur/9-fix", "sha" => "current"}, "state" => "open", "draft" => false}
    branch_pr = %{"review_decision" => "APPROVED", "reviewed_head_sha" => "current", "mergeQueueEntry" => %{"id" => "queue-entry"}, "created_at" => "2026-10-15T18:00:00Z"}

    assert [%{review_decision: "APPROVED", reviewed_head_sha: "current", in_merge_queue: true, ready_at: ~U[2026-10-15 18:00:00Z]}] =
             SnapshotCache.build([{3, pr}], [], [], %{}, %{}, [{9, branch_pr}]).pull_requests

    assert [%{number: 3, mergeable: nil}] = SnapshotCache.build([{3, pr}], [], [], %{}, %{}, [{9, branch_pr}]).merge_queue
  end

  test "filters closed cached blockers while retaining unresolved edges" do
    snapshot =
      SnapshotCache.build(
        [],
        [],
        [{42, [%{"name" => "agent:paused"}]}],
        %{42 => %{"created_at" => "2026-10-15T16:00:00Z"}, 90 => %{"state" => "closed"}},
        %{42 => [%{"number" => 90}, %{"number" => 91}]}
      )

    assert [%{number: 42, closed_blockers: [90], open_blocked_by: [%{"number" => 91}]}] = snapshot.tickets
  end

  test "joins rework attempts only for the current open PR head" do
    tickets = [%{number: 4429, labels: ["agent:rework"]}]
    prs = [%{number: 4447, issue_number: 4429, state: "open", head_sha: "current"}]
    attempts = [%{issue_id: "4429", head_sha: "old", count: 4}, %{issue_id: "4429", head_sha: "current", count: 3}]

    assert [%{number: 4429, unchanged_pr_handoffs: 3}] = SnapshotCache.attach_rework_attempts(tickets, prs, attempts)
    closed_pr = Map.put(hd(prs), :state, "closed")
    assert [%{unchanged_pr_handoffs: 0}] = SnapshotCache.attach_rework_attempts(tickets, [closed_pr], attempts)
  end

  test "a failed landing journal read leaves the rerun backlog unknown, not empty" do
    row = %{"pr" => 17, "head" => "abc"}
    assert SnapshotCache.landing_rerun_backlog(%{watcher: :running, rerun_backlog: {:ok, [row]}}) == [row]
    assert SnapshotCache.landing_rerun_backlog(%{watcher: :running, rerun_backlog: {:error, :eacces}}) == nil
    assert SnapshotCache.landing_rerun_backlog(%{watcher: :unavailable}) == []
  end
end
