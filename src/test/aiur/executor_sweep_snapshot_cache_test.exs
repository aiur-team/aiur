defmodule Aiur.ExecutorSweep.SnapshotCacheTest do
  use Aiur.TestSupport

  alias Aiur.ExecutorSweep.{Checks, SnapshotCache}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.OpenTicketSource.Snapshot
  alias Aiur.TestSupport.Isolation

  setup context do
    [owner, repo] = ["aiur-test", "#{Isolation.unique_name(context, :repo)}"]
    Aiur.TestSupport.write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "#{owner}/#{repo}")

    on_exit(fn -> ResourceStore.clear(:issue, owner, repo) end)
    {:ok, resource_owner: owner, resource_repo: repo}
  end

  test "skips a metadata-only ResourceStore entry while reading cached resources", ctx do
    owner = ctx.resource_owner
    repo = ctx.resource_repo
    key = ResourceStore.key(:issue, owner, repo, 3787)
    neighboring_key = ResourceStore.key(:issue, owner, repo, 3788)
    assert :ok = ResourceStore.put_resource(key, %{"number" => 3787, "created_at" => "2026-10-15T13:25:40Z"}, source: :mutation, version: "2026-10-15T13:25:40Z")
    ResourceStore.drop_data(key)
    assert :ok = ResourceStore.put_resource(neighboring_key, %{"number" => 3788, "created_at" => "2026-10-15T13:25:41Z"}, source: :poll, version: "2026-10-15T13:25:41Z")

    assert [{{:issue, ^owner, ^repo, "3787"}, %{data_source: :mutation} = entry}] = ResourceStore.list(:issue, owner, repo) |> Enum.filter(fn {{:issue, _, _, id}, _} -> id == "3787" end)
    refute Map.has_key?(entry, :data)

    assert %{tickets: [%{number: 3788, created_at: "2026-10-15T13:25:41Z"}]} =
             SnapshotCache.read(fn -> %Snapshot{status: :available, tickets: [%{identifier: "3788", labels: []}]} end)
  end

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

  test "a webhook-shaped branch row without GraphQL landing facts does not claim the PR is not landing" do
    direct = %{
      "number" => 3,
      "state" => "open",
      "head" => %{"ref" => "aiur/9-fix", "sha" => "current"},
      "auto_merge" => nil
    }

    branch = %{
      "number" => 3,
      "state" => "open",
      "head" => %{"ref" => "aiur/9-fix", "sha" => "current"},
      "updated_at" => "2026-10-15T18:00:00Z"
    }

    snapshot = SnapshotCache.build([{3, direct}], [{3, [%{"commit_id" => "current", "state" => "APPROVED"}]}], [], %{}, %{}, [{9, branch}])

    assert [%{landing_state_known?: false, in_merge_queue: false, auto_merge: false}] = snapshot.pull_requests
    refute Enum.any?(Checks.all(snapshot, ~U[2026-10-18 14:00:00Z]), &(&1.kind == "approved_pr_not_landing"))
  end

  test "a stale open branch row does not reopen a merged PR" do
    merged = %{"number" => 4574, "head" => %{"ref" => "aiur/4574-fix", "sha" => "head"}, "state" => "closed", "merged_at" => "2026-10-16T01:07:00Z"}
    stale = %{"number" => 4574, "head" => %{"ref" => "aiur/4574-fix", "sha" => "head"}, "state" => "open", "merged_at" => nil}

    assert [%{state: "closed", merged_at: "2026-10-16T01:07:00Z"}] = SnapshotCache.build([{4574, merged}], [], [], %{}, %{}, [{4574, stale}]).pull_requests
  end

  test "filters closed cached blockers while retaining unresolved edges" do
    snapshot =
      SnapshotCache.build(
        [],
        [],
        [{42, [%{"name" => "agent:paused"}]}],
        %{42 => %{"created_at" => "2026-10-15T16:00:00Z"}, 90 => %{"state" => "closed"}, 91 => %{"state" => "open"}},
        %{42 => [%{"number" => 90}, %{"number" => 91}]}
      )

    assert [%{number: 42, closed_blockers: [90], open_blocked_by: [%{"number" => 91}]}] = snapshot.tickets
  end

  test "retains an open blocker from the edge when its issue row has expired" do
    snapshot =
      SnapshotCache.build(
        [],
        [],
        [{42, [%{"name" => "agent:rework"}]}],
        %{},
        %{42 => [%{"number" => 90, "state" => "open"}]}
      )

    assert [%{open_blocked_by: [%{"number" => 90}], closed_blockers: []}] = snapshot.tickets
    assert Enum.any?(Checks.all(snapshot, ~U[2026-10-18 14:00:00Z]), &(&1.kind == "rework_ticket_blocked"))
  end

  test "the complete open-ticket listing confirms an open blocker without an issue row" do
    ticket_snapshot = %Snapshot{status: :available, tickets: [%{identifier: "90", labels: []}]}

    snapshot =
      SnapshotCache.build(
        [],
        [],
        [{42, [%{"name" => "agent:rework"}]}],
        %{},
        %{42 => [%{"number" => 90}]},
        [],
        %{},
        ticket_snapshot
      )

    assert [%{open_blocked_by: [%{"number" => 90}], closed_blockers: []}] = snapshot.tickets
    assert Enum.any?(Checks.all(snapshot, ~U[2026-10-18 14:00:00Z]), &(&1.kind == "rework_ticket_blocked"))
  end

  test "a complete open-ticket listing overrides a stale open blocker edge" do
    ticket_snapshot = %Snapshot{status: :available, tickets: []}

    snapshot =
      SnapshotCache.build(
        [],
        [],
        [{42, [%{"name" => "agent:rework"}]}],
        %{},
        %{42 => [%{"number" => 90, "state" => "open"}]},
        [],
        %{},
        ticket_snapshot
      )

    assert [%{open_blocked_by: [], closed_blockers: [90]}] = snapshot.tickets
    refute Enum.any?(Checks.all(snapshot, ~U[2026-10-18 14:00:00Z]), &(&1.kind == "rework_ticket_blocked"))
  end

  test "a cross-repository blocker uses its edge state instead of this repository's ticket listing" do
    ticket_snapshot = %Snapshot{status: :available, tickets: []}

    snapshot =
      SnapshotCache.build(
        [],
        [],
        [{42, [%{"name" => "agent:rework"}]}],
        %{},
        %{42 => [%{"number" => 77, "state" => "open", "repository_url" => "https://api.github.com/repos/other/repo"}]},
        [],
        %{},
        ticket_snapshot
      )

    assert [%{open_blocked_by: [%{"number" => 77}], closed_blockers: []}] = snapshot.tickets
    assert Enum.any?(Checks.all(snapshot, ~U[2026-10-18 14:00:00Z]), &(&1.kind == "rework_ticket_blocked"))
  end

  test "the blocker issue cache overrides an open state embedded in the held edge" do
    snapshot =
      SnapshotCache.build(
        [],
        [],
        [{42, [%{"name" => "agent:rework"}]}],
        %{90 => %{"state" => "closed"}},
        %{42 => [%{"number" => "90", "state" => "open"}]}
      )

    assert [%{open_blocked_by: [], closed_blockers: ["90"]}] = snapshot.tickets
    refute Enum.any?(Checks.all(snapshot, ~U[2026-10-18 14:00:00Z]), &(&1.kind == "rework_ticket_blocked"))
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

  test "a secondary instance reports no landing or default-branch watcher service row" do
    previous = Application.get_env(:aiur, :booted_instance_role)
    on_exit(fn -> if previous, do: Application.put_env(:aiur, :booted_instance_role, previous), else: Application.delete_env(:aiur, :booted_instance_role) end)
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nmerge_policy:\n  main_watch:\n    enabled: true\n")
    :ok = Aiur.WorkflowStore.force_reload()
    watcher_names = fn -> SnapshotCache.read(fn -> nil end).services |> Enum.map(& &1.name) end

    Application.put_env(:aiur, :booted_instance_role, "primary")
    assert "landing watcher" in watcher_names.()
    assert "default-branch watcher" in watcher_names.()

    Application.put_env(:aiur, :booted_instance_role, "secondary")
    assert watcher_names.() == []
  end
end
