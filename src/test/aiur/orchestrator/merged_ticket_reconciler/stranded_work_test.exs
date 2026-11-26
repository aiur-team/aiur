defmodule Aiur.Orchestrator.MergedTicketReconciler.StrandedWorkTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.{AgentQueueStore, Issue}
  alias Aiur.Orchestrator.MergedTicketReconciler.StrandedWork
  alias Aiur.Orchestrator.{State, TrackerTasks}

  # The 2026-10-15 sequence (#3846): PR #3928 entered the merge queue at the
  # worker's head, the worker committed three more commits (its pushes were
  # refused while queued, so they stayed local), then the queue merged the PR.
  setup %{tmp_dir: root} do
    git = fn args ->
      {out, 0} = Aiur.TestGit.cmd(["-C", root, "-c", "user.name=t", "-c", "user.email=t@t" | args])
      out
    end

    sha = fn -> git.(["rev-parse", "HEAD"]) |> String.trim() end

    # Each commit carries its own patch: empty commits would all be patch-equivalent.
    commit = fn message ->
      File.write!(Path.join(root, String.replace(message, " ", "_")), message)
      git.(["add", "-A"])
      git.(["commit", "--quiet", "-m", message])
      sha.()
    end

    git.(["init", "--quiet", "-b", "aiur/3846-warm-poll"])
    commit.("base")
    git.(["update-ref", "refs/remotes/origin/main", "HEAD"])
    queued_head = commit.("Warm first poll")
    # A base integration after the queued head is not new scope.
    git.(["checkout", "--quiet", "-b", "side", "origin/main"])
    git.(["update-ref", "refs/remotes/origin/main", commit.("main moved")])
    git.(["checkout", "--quiet", "aiur/3846-warm-poll"])
    git.(["merge", "--quiet", "--no-edit", "origin/main"])
    added = Enum.map(["Initialize capacity", "Assign adoption capacity", "Verify unadopted tickets"], commit)

    {:ok, workspace: root, queued_head: queued_head, added: added, commit: commit, git: git}
  end

  test "a local rebase of the queued commits is not new scope", context do
    context.git.(["checkout", "--quiet", "-b", "rebased", context.queued_head])
    context.git.(["rebase", "--quiet", "origin/main"])
    assert StrandedWork.unmerged_commits(context.workspace, context.queued_head, "main") == []

    added = context.commit.("Wire adoption")
    assert StrandedWork.unmerged_commits(context.workspace, context.queued_head, "main") == [added]
  end

  test "finds the commits made after the queued head, ignoring base integration", context do
    assert StrandedWork.unmerged_commits(context.workspace, context.queued_head, "main") == Enum.reverse(context.added)
    assert StrandedWork.unmerged_commits(context.workspace, List.last(context.added), "main") == []
    # An unknown head is no evidence: the merge closes the ticket as usual.
    assert StrandedWork.unmerged_commits(context.workspace, String.duplicate("0", 40), "main") == []
  end

  test "keeps the ticket open and tells the live worker instead of tearing it down", context do
    parent = self()
    result = StrandedWork.mark_merged(state(context.workspace), "3846", opts(context, parent))

    assert_received {:reopened, "3846"}
    assert_received {:state_written, "3846"}
    assert_received {:alert, false}
    refute_received :terminated
    assert Map.has_key?(result.running, "issue-3846")
    assert MapSet.member?(result.merged_ticket_reconciliations, {"3846", "owner/repo#3928"})

    assert [item] = Map.values(result.queue_store.items)
    assert item.target_issue_identifier == "3846"
    assert item.body.text =~ "PR #3928 merged"
    assert item.body.text =~ "3 commit(s)"
    assert item.body.text =~ "Closes #3846"
  end

  test "still keeps the worker when the ticket cannot be reopened, and asks the Executor", context do
    parent = self()
    opts = Keyword.put(opts(context, parent), :reopen_issue_fun, fn _ -> {:error, :forbidden} end)
    result = StrandedWork.mark_merged(state(context.workspace), "3846", opts)

    assert_received {:alert, true}
    refute_received {:state_written, _}
    refute_received :terminated
    assert Map.has_key?(result.running, "issue-3846")
    assert [item] = Map.values(result.queue_store.items)
    assert item.body.text =~ "could not reopen the ticket"
    refute item.body.text =~ "reopened the ticket as in-progress"
  end

  test "a reopen held by the local budget is waited out, and the ticket still ends up open", context do
    parent = self()
    calls = :counters.new(1, [])
    hold = {:error, {:github, :local_hold, %{hold: %{reason: :shared_budget, resource: "core", reset_at: ~U[2026-01-01 00:00:00Z]}}}}

    reopen = fn id ->
      :counters.add(calls, 1, 1)
      if :counters.get(calls, 1) == 1, do: hold, else: send(parent, {:reopened, id}) && :ok
    end

    opts = Keyword.merge(opts(context, parent), reopen_issue_fun: reopen, local_hold_sleep_fun: fn _ -> :ok end)
    StrandedWork.mark_merged(state(context.workspace), "3846", opts)

    assert_received {:reopened, "3846"}
    assert_received {:state_written, "3846"}
    assert_received {:alert, false}
  end

  test "on the owner path a held reopen has no generic timeout, and a crashed check keeps the worker", context do
    parent = self()
    opts = Keyword.put(opts(context, parent), :reopen_issue_fun, fn _ -> exit(:controlled_crash) end)
    pending = StrandedWork.mark_merged(%{state(context.workspace) | snapshot_key: self()}, "3846", opts)

    assert [%{key: {:stranded_work, "3846"}, timer: nil}] = Map.values(pending.tracker_tasks)
    receive_barrier({:DOWN, ref, :process, _pid, :controlled_crash})
    {:handled, result} = TrackerTasks.down(pending, ref, :controlled_crash)

    assert_received {:alert, true}
    refute_received :terminated
    assert Map.has_key?(result.running, "issue-3846")
    assert result.tracker_tasks == %{}
  end

  test "a reopened ticket whose state write failed is reported as such", context do
    parent = self()
    opts = Keyword.put(opts(context, parent), :keep_open_state_fun, fn _ -> {:error, :conflict} end)
    result = StrandedWork.mark_merged(state(context.workspace), "3846", opts)

    assert_received {:reopened, "3846"}
    assert_received {:alert, true}
    assert [item] = Map.values(result.queue_store.items)
    assert item.body.text =~ "reopened the ticket but could not set it in-progress"
  end

  test "the webhook and the poll route report one merge once", context do
    parent = self()
    state = StrandedWork.mark_merged(state(context.workspace), "3846", opts(context, parent))
    result = StrandedWork.mark_merged(state, "3846", opts(context, parent))

    assert_received {:alert, false}
    refute_received {:alert, _}
    assert [_item] = Map.values(result.queue_store.items)
  end

  test "a merge that leaves another open PR keeps its routing and skips the check", context do
    parent = self()

    opts =
      Keyword.merge(opts(context, parent),
        target_state: "rework",
        unmerged_commits_fun: fn _, _ -> flunk("git was called") end,
        update_issue_state_fun: fn id, target -> send(parent, {:target_written, id, target}) && :ok end
      )

    result = StrandedWork.mark_merged(state(context.workspace), "3846", opts)

    assert_received {:target_written, "3846", "rework"}
    refute_received {:reopened, _}
    refute_received :terminated
    assert result.queue_store.items == %{}
  end

  test "a merge at the worker's head completes the ticket as before", context do
    parent = self()
    opts = Keyword.put(opts(context, parent), :head_sha, List.last(context.added))
    result = StrandedWork.mark_merged(state(context.workspace), "3846", opts)

    assert_received :terminated
    refute_received {:reopened, _}
    refute Map.has_key?(result.running, "issue-3846")
  end

  test "a head SHA that is not a hex object id is never handed to git", context do
    parent = self()
    opts = Keyword.merge(opts(context, parent), head_sha: "--output=/tmp/x", unmerged_commits_fun: fn _, _ -> flunk("git was called") end)
    StrandedWork.mark_merged(state(context.workspace), "3846", opts)

    assert_received :terminated
  end

  defp state(workspace) do
    issue = %Issue{id: "issue-3846", identifier: "3846", state: "human-review"}

    %State{
      running: %{"issue-3846" => %{pid: nil, ref: nil, identifier: "3846", issue: issue, workspace_path: workspace}},
      claimed: MapSet.new(["issue-3846"]),
      completed: MapSet.new(),
      queue_store: AgentQueueStore.new()
    }
  end

  defp opts(context, parent) do
    [
      head_sha: context.queued_head,
      pr_number: 3928,
      pr_body: "Closes #3846",
      target_state: "done",
      unmerged_commits_fun: &StrandedWork.unmerged_commits(&1, &2, "main"),
      repo_fun: fn -> "owner/repo" end,
      reopen_issue_fun: fn id -> send(parent, {:reopened, id}) && :ok end,
      keep_open_state_fun: fn id -> send(parent, {:state_written, id}) && :ok end,
      emit_alert_fun: fn _name, alert -> send(parent, {:alert, alert[:needs_attention]}) end,
      update_issue_state_fun: fn _identifier, "done" -> :ok end,
      merger_allowed_fun: fn _login -> true end,
      clear_session_handle_fun: fn _identifier -> :ok end,
      observe_membership_fun: fn _identity, _lifecycle -> :ok end,
      mark_reconciled_fun: fn _identifier -> :ok end,
      set_terminal_verification_pending_fun: fn _identity, _pending -> :ok end,
      resume_blockees_fun: fn state, _identifier -> state end,
      terminate_running_issue_fun: fn current, issue_id, true ->
        send(parent, :terminated)
        %{current | running: Map.delete(current.running, issue_id)}
      end
    ]
  end
end
