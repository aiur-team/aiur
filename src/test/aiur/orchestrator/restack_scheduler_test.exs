defmodule Aiur.Orchestrator.RestackSchedulerTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Issue
  alias Aiur.Orchestrator.{RestackScheduler, State, TrackerTasks}

  setup do
    issue = %Issue{id: "20", identifier: "20", state: "ci-wait", blocked_by: [%{id: "10"}]}
    owner = self()

    opts = [
      enabled: true,
      base_branch: "main",
      read_pr: fn "20" -> {:ok, %{state: :open, head_ref: "dependent"}} end,
      blockers: fn "20" -> [%{id: "10", pr: %{merged?: true, number: 42, merge_commit_sha: "merged"}}] end,
      run: fn ^issue, "dependent", %{number: 42, sha: "merged"}, "main" ->
        send(owner, {:started, self()})
        receive do: ({:release, result} -> result)
      end
    ]

    %{issue: issue, opts: opts}
  end

  test "duplicate reconcile starts one supervised task; completed heads are no-ops", ctx do
    state = RestackScheduler.reconcile(%State{}, [ctx.issue], ctx.opts)
    duplicate = RestackScheduler.reconcile(state, [ctx.issue], ctx.opts)
    assert duplicate == state
    receive_barrier({:started, worker})
    send(worker, {:release, {:ok, {:pushed, "new-head"}}})
    receive_barrier({ref, result})
    assert {:handled, complete} = TrackerTasks.result(state, ref, result)
    assert complete.restack_completed[{"20", "merged", nil}] == :done
    assert RestackScheduler.reconcile(complete, [ctx.issue], ctx.opts) == complete
    refute_received {:started, _worker}
  end

  test "a newly delivered dependent head is rechecked after prior completion", ctx do
    state = %State{restack_completed: %{{"20", "merged", "old"} => :done}}
    opts = Keyword.put(ctx.opts, :read_pr, fn "20" -> {:ok, %{state: :open, head_ref: "dependent", head_sha: "new"}} end)
    pending = RestackScheduler.reconcile(state, [ctx.issue], opts)
    receive_barrier({:started, worker})
    send(worker, {:release, {:ok, :already_contained}})
    receive_barrier({ref, result})
    assert {:handled, complete} = TrackerTasks.result(pending, ref, result)
    assert complete.restack_completed[{"20", "merged", "new"}] == :done
  end

  test "live dependents and disabled configuration never start work", ctx do
    state = %State{running: %{"20" => %{}}}
    assert RestackScheduler.reconcile(state, [ctx.issue], ctx.opts) == state
    assert RestackScheduler.reconcile(%State{}, [ctx.issue], Keyword.put(ctx.opts, :enabled, false)) == %State{}
    refute_received {:started, _worker}
  end

  test "conflict reporting is scheduled once with blocker and paths", ctx do
    owner = self()

    report = fn issue, number, paths ->
      RestackScheduler.report_conflict(issue, number, paths,
        write_state: fn "20", "rework", opts ->
          assert opts[:writer] == :restack
          assert opts[:expected_state] == "ci-wait"
          send(owner, :reworked)
          :ok
        end,
        comment: fn "20", body ->
          assert body =~ "#42"
          assert body =~ "`shared`"
          send(owner, :commented)
          :ok
        end,
        publish: fn "ticket.20.restack.conflict", %{reason: "restack_conflict", blocker_pr: 42, paths: ["shared"]} ->
          send(owner, {:reported, issue.id, number, paths})
          :ok
        end
      )
    end

    opts = Keyword.put(ctx.opts, :report, report)
    state = RestackScheduler.reconcile(%State{}, [ctx.issue], opts)
    receive_barrier({:started, worker})
    send(worker, {:release, {:conflict, ["shared"]}})
    receive_barrier({ref, result})
    assert {:handled, reporting} = TrackerTasks.result(state, ref, result)
    assert RestackScheduler.reconcile(reporting, [ctx.issue], opts) == reporting
    receive_barrier(:reworked)
    receive_barrier(:commented)
    receive_barrier({:reported, "20", 42, ["shared"]})
    receive_barrier({report_ref, report_result})
    assert {:handled, complete} = TrackerTasks.result(reporting, report_ref, report_result)
    assert RestackScheduler.reconcile(complete, [ctx.issue], opts) == complete
    refute_received :reworked
    refute_received :commented
    refute_received {:reported, _, _, _}
  end

  test "a failed rework write prevents comment and event publication", ctx do
    assert {:report_failed, :state_changed, ["shared"], []} =
             RestackScheduler.report_conflict(ctx.issue, 42, ["shared"],
               write_state: fn "20", "rework", _opts -> {:error, :state_changed} end,
               comment: fn _, _ -> flunk("must not comment after a refused transition") end,
               publish: fn _, _ -> flunk("must not publish after a refused transition") end
             )
  end

  test "partial conflict reporting retries only unfinished steps", ctx do
    owner = self()

    writes = fn _, _, _ ->
      send(owner, :reworked)
      :ok
    end

    failing = [write_state: writes, comment: fn _, _ -> {:error, :unavailable} end]
    assert {:report_failed, :unavailable, ["shared"], [:state]} = RestackScheduler.report_conflict(ctx.issue, 42, ["shared"], failing)
    receive_barrier(:reworked)

    opts =
      Keyword.merge(ctx.opts,
        completed_steps: [:state],
        write_state: writes,
        comment: fn _, _ ->
          send(owner, :commented)
          :ok
        end,
        publish: fn _, _ -> :ok end
      )

    state = %State{restack_completed: %{{"20", "merged", nil} => %{issue: ctx.issue, number: 42, paths: ["shared"], steps: [:state]}}}
    retry = RestackScheduler.reconcile(state, [], opts)
    receive_barrier(:commented)
    receive_barrier({ref, result})
    assert {:handled, done} = TrackerTasks.result(retry, ref, result)
    assert done.restack_completed[{"20", "merged", nil}] == :done
    refute_received :reworked
    refute_received {:started, _}
  end

  test "a rejected push is retried on the next reconcile", ctx do
    state = RestackScheduler.reconcile(%State{}, [ctx.issue], ctx.opts)
    receive_barrier({:started, worker})
    send(worker, {:release, {:error, :remote_moved}})
    receive_barrier({ref, result})
    assert {:handled, failed} = TrackerTasks.result(state, ref, result)
    retry = RestackScheduler.reconcile(failed, [ctx.issue], ctx.opts)
    receive_barrier({:started, retry_worker})
    send(retry_worker, {:release, {:ok, :already_contained}})
    receive_barrier({retry_ref, retry_result})
    assert {:handled, _complete} = TrackerTasks.result(retry, retry_ref, retry_result)
  end
end
