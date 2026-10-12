Code.require_file("../../support/restack_fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.PropagationWiringTest do
  use Aiur.TestSupport
  alias Aiur.Events.{BranchRefStore, Exchange}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.{BlockerPropagation, EventTopics, RestackScheduler, State, TrackerTasks}
  alias Aiur.TestSupport.RestackFixture, as: Git

  setup do
    ctx = Git.create()
    root = Path.join([ctx.root, "owner", "repo"])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", workspace_root: root)
    path = Workflow.workflow_file_path()
    File.write!(path, File.read!(path) |> String.replace("tracker:\n", "tracker:\n  propagate_blocker_pushes: true\n"))
    :ok = Aiur.WorkflowStore.force_reload()
    ResourceStore.reset()
    BranchRefStore.reset()

    on_exit(fn ->
      ResourceStore.reset()
      BranchRefStore.reset()
    end)

    Git.git(ctx.workspace, ["branch", "-m", "blocker", "aiur/10-upstream"])
    Git.git(ctx.workspace, ["branch", "-m", "dependent", "aiur/20-middle"])
    Git.git(ctx.workspace, ["checkout", "-b", "aiur/30-leaf"])
    File.write!(Path.join(ctx.workspace, "leaf"), "leaf\n")
    Git.git(ctx.workspace, ["add", "leaf"])
    Git.git(ctx.workspace, ["commit", "-m", "leaf"])
    c = Git.git(ctx.workspace, ["rev-parse", "HEAD"])
    a = Git.git(ctx.workspace, ["rev-parse", "aiur/10-upstream"])
    Git.git(ctx.workspace, ["push", "origin", "aiur/10-upstream", "aiur/20-middle", "aiur/30-leaf"])
    work_c = Path.join(root, "30")
    Git.git(ctx.root, ["clone", "--branch", "aiur/30-leaf", ctx.origin, work_c])
    Git.git(work_c, ["config", "user.name", "Propagation test"])
    Git.git(work_c, ["config", "user.email", "test@example.invalid"])

    for {id, ref, sha} <- [{"10", "aiur/10-upstream", a}, {"20", "aiur/20-middle", ctx.dependent}, {"30", "aiur/30-leaf", c}] do
      put_pr(id, ref, sha)
      :ok = BranchRefStore.record("refs/heads/#{ref}", sha)
    end

    for {id, blocker} <- [{"20", 10}, {"30", 20}] do
      :ok = ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", id), [%{"number" => blocker}])
    end

    issues = for {id, blocker} <- [{"20", "10"}, {"30", "20"}], into: %{}, do: {id, %Issue{id: id, identifier: id, state: "ci-wait", blocked_by: [%{id: blocker}]}}
    Map.merge(ctx, %{a: a, c: c, state: %State{last_polled_issues: issues}})
  end

  test "delivered A push writes B, whose published push alone starts C", ctx do
    bind("ticket.20.branch.push")
    bind("ticket.30.branch.push")
    event = advance(ctx, "blocker-only", "updated\n")
    queued = EventTopics.route(ctx.state, event)
    assert Map.keys(queued.blocker_propagations) == [{"20", "10"}]
    pending = tick(queued)
    {complete, b} = finish(pending)
    assert {:ok, {:pushed, b_head}} = b
    assert Git.git(ctx.origin, ["rev-parse", "refs/heads/aiur/30-leaf"]) == ctx.c
    receive_barrier({:event, %{topic: "ticket.20.branch.push"} = event})
    assert event.sha == b_head
    next = EventTopics.route(complete, event) |> tick()
    {_complete, c} = finish(next)
    assert {:ok, {:pushed, c_head}} = c
    receive_barrier({:event, %{topic: "ticket.30.branch.push", sha: ^c_head}})
    Git.git(ctx.workspace, ["fetch", "origin", "aiur/30-leaf"])
    assert Git.git(ctx.workspace, ["diff", "--name-only", b_head, c_head]) == "leaf"
    assert Git.git(ctx.workspace, ["show", "#{c_head}:blocker-only"]) == "updated"
  end

  test "actual upstream conflict cannot publish a push or modify C", ctx do
    event = advance(ctx, "shared", "upstream conflict\n")
    queued = EventTopics.route(ctx.state, event)
    owner = self()

    report = fn issue, number, paths, opts ->
      RestackScheduler.report_conflict(
        issue,
        number,
        paths,
        Keyword.merge(opts,
          write_state: fn "20", "rework", _ ->
            send(owner, :reworked)
            :ok
          end,
          comment: fn "20", body ->
            send(owner, {:comment, body})
            :ok
          end,
          publish: fn "ticket.20.restack.conflict", payload ->
            send(owner, {:reported, payload})
            :ok
          end
        )
      )
    end

    queued = %{queued | blocker_propagations: Map.new(queued.blocker_propagations, fn {id, job} -> {id, %{job | opts: Keyword.put(job.opts, :report, report)}} end)}
    pending = tick(queued)
    [ref] = Map.keys(pending.tracker_tasks)
    receive_barrier({^ref, result})
    assert result == {:conflict, ["shared"]}
    assert {:handled, reporting} = TrackerTasks.result(pending, ref, result)
    receive_barrier(:reworked)
    receive_barrier({:comment, body})
    assert body =~ "upstream_conflict" and body =~ "`shared`"
    receive_barrier({:reported, %{reason: "upstream_conflict", blocker_pr: 10, paths: ["shared"]}})
    {complete, _} = finish(reporting)
    assert Git.git(ctx.origin, ["rev-parse", "refs/heads/aiur/20-middle"]) == ctx.dependent
    assert Git.git(ctx.origin, ["rev-parse", "refs/heads/aiur/30-leaf"]) == ctx.c
    assert pending.blocker_propagations == %{}
    assert complete.tracker_tasks == %{}
  end

  defp advance(ctx, file, content) do
    Git.git(ctx.workspace, ["checkout", "aiur/10-upstream"])
    File.write!(Path.join(ctx.workspace, file), content)
    Git.git(ctx.workspace, ["add", file])
    Git.git(ctx.workspace, ["commit", "-m", "upstream push"])
    sha = Git.git(ctx.workspace, ["rev-parse", "HEAD"])
    Git.git(ctx.workspace, ["push", "origin", "aiur/10-upstream"])
    %{topic: "ticket.10.branch.push", payload: %{ref: "refs/heads/aiur/10-upstream", sha: sha, previous_sha: ctx.a}}
  end

  defp tick(state), do: BlockerPropagation.flush(state, System.monotonic_time(:millisecond) + 2_000)

  defp finish(state) do
    [ref] = Map.keys(state.tracker_tasks)
    receive_barrier({^ref, result})
    assert {:handled, state} = TrackerTasks.result(state, ref, result)
    {state, result}
  end

  defp bind(topic) do
    :ok = Exchange.subscribe(topic)
  end

  defp put_pr(id, ref, sha) do
    pr = %{"number" => String.to_integer(id), "state" => "open", "merged" => false, "merged_at" => nil, "head" => %{"ref" => ref, "sha" => sha}}
    ResourceStore.put_resource(ResourceStore.key(:branch_pull_request, "owner", "repo", id), pr, source: :webhook)
  end
end
