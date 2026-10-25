Code.require_file("../../support/restack_fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RestackWiringTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.{ResourceStore, TicketPullRequest}
  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.{CiLifecycle, EventTopics, State, TrackerTasks}
  alias Aiur.TestSupport.RestackFixture
  alias Aiur.Workspace.{Refresh, Restack}

  setup do
    ctx = RestackFixture.create()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", workspace_root: Path.join([ctx.root, "owner", "repo"]))
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)
    dependent = %{"number" => 43, "state" => "open", "merged" => false, "merged_at" => nil, "head" => %{"ref" => "dependent", "sha" => ctx.dependent}}
    put_pr("20", dependent)
    :ok = ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", "20"), [%{"number" => 10}])
    issue = %Issue{id: "20", identifier: "20", state: "ci-wait", blocked_by: [%{id: "10"}]}
    assert Map.get(Aiur.Config.settings!().tracker, :restack_after_blocker_merge) == true
    assert {:ok, %{head_ref: "dependent"}} = TicketPullRequest.read("20")
    Map.put(ctx, :issue, issue)
  end

  test "duplicate blocker merge events restack the idle dependent's real remote", ctx do
    pr = merged_pr(ctx)
    event = %{topic: "ticket.10.pr.merged", pr: pr}
    state = %State{last_polled_issues: %{"20" => ctx.issue}}
    pending = EventTopics.route(state, event)
    duplicate = EventTopics.route(pending, event)
    assert map_size(duplicate.tracker_tasks) == 1
    [ref] = Map.keys(pending.tracker_tasks)
    receive_barrier({^ref, result})
    assert {:ok, {:pushed, sha}} = result
    assert {:handled, complete} = TrackerTasks.result(duplicate, ref, result)
    assert RestackFixture.git(ctx.origin, ["rev-parse", "refs/heads/dependent"]) == sha
    assert RestackFixture.git(ctx.workspace, ["diff", "--name-only", "main", sha]) == "shared"
    assert EventTopics.route(complete, event).tracker_tasks == %{}
    refute File.exists?(ctx.workspace <> ".lock")
  end

  test "CI polling reconciles a missed merge event from delivered facts", ctx do
    put_pr("10", merged_pr(ctx))

    opts = [
      ci_issue_fetcher: fn _states -> {:ok, [ctx.issue]} end,
      ci_poller: fn ["20"], _opts -> {:ok, %{results: [], errors: []}} end,
      parked_ready_alert_loader: fn -> MapSet.new() end,
      draft_stall_alert_loader: fn -> MapSet.new() end
    ]

    pending = CiLifecycle.poll_github_ci(%State{}, opts)
    assert map_size(pending.tracker_tasks) == 1
    [ref] = Map.keys(pending.tracker_tasks)
    receive_barrier({^ref, result})
    assert {:ok, {:pushed, sha}} = result
    assert {:handled, complete} = TrackerTasks.result(pending, ref, result)
    assert RestackFixture.git(ctx.origin, ["rev-parse", "refs/heads/dependent"]) == sha
    next = CiLifecycle.poll_github_ci(%{complete | last_ci_poll_started_at_ms: nil}, opts)
    assert next.tracker_tasks == %{}
  end

  test "resume consumes the pushed restack before the plain main hook", ctx do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      workspace_root: Path.join([ctx.root, "owner", "repo"]),
      hook_before_run: "git merge --no-edit main"
    )

    assert {:ok, {:pushed, sha}} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge)
    assert :ok = Refresh.run(ctx.workspace, ctx.issue)
    assert RestackFixture.git(ctx.workspace, ["rev-parse", "HEAD"]) == sha
    assert File.read!(Path.join(ctx.workspace, "shared")) == "dependent\n"
    assert {_output, 1} = RestackFixture.command(ctx.workspace, ["show-ref", "--verify", "--quiet", "refs/aiur/restack/pending/dependent"])
    File.write!(Path.join(ctx.workspace, "later"), "later work\n")
    RestackFixture.git(ctx.workspace, ["add", "later"])
    RestackFixture.git(ctx.workspace, ["commit", "-m", "later work"])
    head = RestackFixture.git(ctx.workspace, ["rev-parse", "HEAD"])
    RestackFixture.git(ctx.workspace, ["update-ref", "refs/aiur/restack/pending/dependent", sha])
    assert :ok = Refresh.run(ctx.workspace, ctx.issue)
    assert RestackFixture.git(ctx.workspace, ["rev-parse", "HEAD"]) == head
    assert {_output, 1} = RestackFixture.command(ctx.workspace, ["show-ref", "--verify", "--quiet", "refs/aiur/restack/pending/dependent"])
  end

  test "resume preserves divergent local work and skips the main merge hook", ctx do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", workspace_root: Path.join([ctx.root, "owner", "repo"]), hook_before_run: "exit 99")
    assert {:ok, {:pushed, _sha}} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge)
    File.write!(Path.join(ctx.workspace, "local"), "unsent work\n")
    RestackFixture.git(ctx.workspace, ["add", "local"])
    RestackFixture.git(ctx.workspace, ["commit", "-m", "local work"])
    head = RestackFixture.git(ctx.workspace, ["rev-parse", "HEAD"])
    assert :ok = Refresh.run(ctx.workspace, ctx.issue)
    assert RestackFixture.git(ctx.workspace, ["rev-parse", "HEAD"]) == head
    assert File.read!(Path.join(ctx.workspace, "local")) == "unsent work\n"
  end

  test "resume preserves conflicting uncommitted work and retains the receipt", ctx do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", hook_before_run: "exit 99")
    assert {:ok, {:pushed, sha}} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge)
    File.write!(Path.join(ctx.workspace, "shared"), "uncommitted\n")
    assert :ok = Refresh.run(ctx.workspace, ctx.issue)
    assert RestackFixture.git(ctx.workspace, ["rev-parse", "HEAD"]) == ctx.dependent
    assert File.read!(Path.join(ctx.workspace, "shared")) == "uncommitted\n"
    assert RestackFixture.git(ctx.workspace, ["rev-parse", "refs/aiur/restack/pending/dependent"]) == sha
  end

  test "a restack conflict skips the plain merge hook on resume", ctx do
    RestackFixture.git(ctx.workspace, ["checkout", "main"])
    File.write!(Path.join(ctx.workspace, "shared"), "later main\n")
    RestackFixture.git(ctx.workspace, ["add", "shared"])
    RestackFixture.git(ctx.workspace, ["commit", "-m", "later main"])
    RestackFixture.git(ctx.workspace, ["push", "origin", "main"])
    RestackFixture.git(ctx.workspace, ["checkout", "dependent"])
    assert {:conflict, ["shared"]} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", hook_before_run: "exit 99")
    assert :ok = Refresh.run(ctx.workspace, ctx.issue)
    assert RestackFixture.git(ctx.workspace, ["rev-parse", "HEAD"]) == ctx.dependent
    assert RestackFixture.git(ctx.origin, ["rev-parse", "refs/heads/dependent"]) == ctx.dependent
  end

  defp merged_pr(ctx),
    do: %{
      "number" => 42,
      "state" => "closed",
      "merged" => true,
      "merged_at" => "2026-10-09T00:00:00Z",
      "merge_commit_sha" => ctx.merge,
      "body" => "Refs #10",
      "head" => %{"ref" => "blocker", "sha" => RestackFixture.git(ctx.workspace, ["rev-parse", "blocker"])}
    }

  defp put_pr(id, pr), do: ResourceStore.put_resource(ResourceStore.key(:branch_pull_request, "owner", "repo", id), pr, source: :webhook)
end
