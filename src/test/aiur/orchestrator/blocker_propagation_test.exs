defmodule Aiur.Orchestrator.BlockerPropagationTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Issue
  alias Aiur.Orchestrator.{BlockerPropagation, RestackScheduler, State, TrackerTasks}
  @sha String.duplicate("a", 40)
  @old String.duplicate("b", 40)

  setup do
    owner = self()
    clock = :atomics.new(1, [])
    issues = for id <- ["20", "30", "40"], into: %{}, do: {id, %Issue{id: id, identifier: id, state: "ci-wait"}}

    opts = [
      enabled: true,
      latest: fn _ -> nil end,
      clock: fn -> :atomics.get(clock, 1) end,
      blockers: fn
        "30" -> [%{id: "20", pr: %{state: :open, number: 20}}]
        _ -> [%{id: "10", pr: %{state: :open, number: 10}}]
      end,
      read_pr: fn id -> {:ok, %{state: :open, head_ref: "aiur/#{id}", head_sha: @old}} end,
      run: fn job ->
        send(owner, {:started, job.issue.id, job.push.sha, self()})
        receive do: ({:release, result} -> result)
      end,
      publish: fn topic, payload ->
        send(owner, {:published, topic, payload})
        :ok
      end,
      report: fn issue, number, paths, opts ->
        send(owner, {:rework, issue.id, number, paths, opts[:reason]})
        {:ok, :conflict_reported}
      end
    ]

    %{state: %State{last_polled_issues: issues}, opts: opts, clock: clock}
  end

  defp push(id, sha \\ @sha), do: %{ref: "refs/heads/aiur/#{id}", sha: sha, previous_sha: @old}
  defp due(ctx), do: :atomics.put(ctx.clock, 1, 2_000)

  defp result(state) do
    receive_barrier({ref, result})
    {:handled, state} = TrackerTasks.result(state, ref, result)
    state
  end

  test "direct cascade waits for B's pushed result; C never consumes A", ctx do
    queued = BlockerPropagation.pushed(ctx.state, "10", push("10"), ctx.opts)
    assert Map.keys(queued.blocker_propagations) |> Enum.sort() == [{"20", "10"}, {"40", "10"}]
    assert BlockerPropagation.flush(queued).tracker_tasks == %{}
    due(ctx)
    active = BlockerPropagation.flush(queued)
    receive_barrier({:started, "20", @sha, b})
    receive_barrier({:started, "40", @sha, d})
    refute_received {:started, "30", _, _}
    b_head = String.duplicate("c", 40)
    send(b, {:release, {:ok, {:pushed, b_head}}})
    complete = result(active)
    receive_barrier({:published, "ticket.20.branch.push", payload})
    assert payload.sha == b_head
    cascade = BlockerPropagation.pushed(complete, "20", payload, ctx.opts)
    assert cascade.blocker_propagations[{"30", "20"}].push.sha == b_head
    :atomics.put(ctx.clock, 1, 4_000)
    running = BlockerPropagation.flush(cascade)
    receive_barrier({:started, "30", ^b_head, c})
    send(c, {:release, {:ok, :already_contained}})
    running = result(running)
    send(d, {:release, {:ok, :already_contained}})
    result(running)
  end

  test "debounce replaces queued pushes and cap allows only two tasks", ctx do
    blockers = fn _ -> [%{id: "10", pr: %{state: :open, number: 10}}] end
    opts = Keyword.put(ctx.opts, :blockers, blockers)
    queued = BlockerPropagation.pushed(ctx.state, "10", push("10"), opts)
    newer = String.duplicate("c", 40)
    queued = BlockerPropagation.pushed(queued, "10", push("10", newer), opts)
    due(ctx)
    running = BlockerPropagation.flush(queued)
    assert map_size(running.tracker_tasks) == 2
    assert map_size(running.blocker_propagations) == 1
    receive_barrier({:started, "20", ^newer, b})
    receive_barrier({:started, "30", ^newer, c})
    assert BlockerPropagation.flush(running) == running
    send(b, {:release, {:ok, :already_contained}})
    next = running |> result() |> BlockerPropagation.flush()
    receive_barrier({:started, "40", ^newer, d})
    assert map_size(next.tracker_tasks) == 2
    send(c, {:release, {:ok, :already_contained}})
    next = result(next)
    send(d, {:release, {:ok, :already_contained}})
    result(next)
  end

  test "live dependent is skipped both at enqueue and before starting", ctx do
    state = %{ctx.state | running: %{"20" => %{}}}
    queued = BlockerPropagation.pushed(state, "10", push("10"), ctx.opts)
    refute Map.has_key?(queued.blocker_propagations, {"20", "10"})
    queued = BlockerPropagation.pushed(ctx.state, "20", push("20"), ctx.opts)
    due(ctx)
    assert BlockerPropagation.flush(%{queued | running: %{"30" => %{}}}).tracker_tasks == %{}
  end

  test "conflict dispatches rework with paths, without a descendant push", ctx do
    state = %{ctx.state | last_polled_issues: Map.take(ctx.state.last_polled_issues, ["20", "30"])}
    queued = BlockerPropagation.pushed(state, "10", push("10"), ctx.opts)
    due(ctx)
    running = BlockerPropagation.flush(queued)
    receive_barrier({:started, "20", @sha, b})
    send(b, {:release, {:conflict, ["shared"]}})
    reporting = result(running)
    receive_barrier({:rework, "20", 10, ["shared"], "upstream_conflict"})
    complete = result(reporting)
    assert complete.blocker_propagations == %{}
    refute_received {:published, _, _}
    refute_received {:started, "30", _, _}
  end

  test "rewrites dispatch agent rework even for unreviewed draft dependents", ctx do
    state = %{ctx.state | last_polled_issues: Map.take(ctx.state.last_polled_issues, ["20", "30"])}
    opts = Keyword.put(ctx.opts, :read_pr, fn id -> {:ok, %{state: :open, head_ref: "aiur/#{id}", head_sha: @old, draft?: true, reviews: []}} end)
    queued = BlockerPropagation.pushed(state, "10", push("10"), opts)
    due(ctx)
    running = BlockerPropagation.flush(queued)
    receive_barrier({:started, "20", @sha, b})
    send(b, {:release, {:rewrite, []}})
    reporting = result(running)
    receive_barrier({:rework, "20", 10, [], "upstream_rewrite"})
    assert result(reporting).blocker_propagations == %{}
    refute_received {:published, _, _}
  end

  test "a newer dependent push cancels upstream work before it can cascade", ctx do
    queued = BlockerPropagation.pushed(ctx.state, "10", push("10"), ctx.opts)
    due(ctx)
    running = BlockerPropagation.flush(queued)
    receive_barrier({:started, "20", @sha, b})
    receive_barrier({:started, "40", @sha, d})
    monitor = Process.monitor(b)
    next = BlockerPropagation.pushed(running, "20", push("20"), ctx.opts)
    receive_barrier({:DOWN, ^monitor, :process, ^b, _})
    refute TrackerTasks.running?(next, {:propagate, "20"})
    assert next.blocker_propagations[{"30", "20"}].push.blocker == "20"
    send(d, {:release, {:ok, :already_contained}})
    result(next)
    refute_received {:published, _, _}
  end

  test "a newer upstream cancels older workers and retains only the latest push", ctx do
    queued = BlockerPropagation.pushed(ctx.state, "10", push("10"), ctx.opts)
    due(ctx)
    running = BlockerPropagation.flush(queued)
    receive_barrier({:started, "20", @sha, b})
    receive_barrier({:started, "40", @sha, d})
    bm = Process.monitor(b)
    dm = Process.monitor(d)
    newer = String.duplicate("c", 40)
    next = BlockerPropagation.pushed(running, "10", push("10", newer), ctx.opts)
    receive_barrier({:DOWN, ^bm, :process, ^b, _})
    receive_barrier({:DOWN, ^dm, :process, ^d, _})
    assert next.tracker_tasks == %{}
    :atomics.put(ctx.clock, 1, 4_000)
    next = BlockerPropagation.flush(next)
    receive_barrier({:started, "20", ^newer, b})
    receive_barrier({:started, "40", ^newer, d})
    send(b, {:release, {:ok, :already_contained}})
    next = result(next)
    send(d, {:release, {:ok, :already_contained}})
    result(next)
    refute_received {:published, _, _}
  end

  test "unfinished conflict reporting retries without repeating the rework write", ctx do
    owner = self()
    attempt = :atomics.new(1, [])

    report = fn issue, number, paths, opts ->
      RestackScheduler.report_conflict(
        issue,
        number,
        paths,
        Keyword.merge(opts,
          write_state: fn _, _, _ ->
            send(owner, :reworked)
            :ok
          end,
          comment: fn _, _ -> if :atomics.add_get(attempt, 1, 1) == 1, do: {:error, :unavailable}, else: :ok end,
          publish: fn _, payload ->
            send(owner, {:reported, payload})
            :ok
          end
        )
      )
    end

    opts = Keyword.put(ctx.opts, :report, report)
    state = %{ctx.state | last_polled_issues: Map.take(ctx.state.last_polled_issues, ["20"])}
    queued = BlockerPropagation.pushed(state, "10", push("10"), opts)
    due(ctx)
    running = BlockerPropagation.flush(queued)
    receive_barrier({:started, "20", @sha, b})
    send(b, {:release, {:conflict, ["shared"]}})
    reporting = result(running)
    receive_barrier(:reworked)
    retry = result(reporting)
    assert retry.blocker_propagations[{"20", "10"}].report.steps == [:state]
    :atomics.put(ctx.clock, 1, 4_000)
    pending = BlockerPropagation.flush(retry)
    receive_barrier({:reported, %{reason: "upstream_conflict", paths: ["shared"]}})
    assert result(pending).blocker_propagations == %{}
    refute_received :reworked
    refute_received {:started, _, _, _}
  end

  test "default depends on the dependent's own queue trigger" do
    view = %{queues: [%{start_trigger: :pr_opened, items: [%{number: 20}]}, %{start_trigger: :pr_merged, items: [%{number: 30}]}]}
    assert BlockerPropagation.optimistic_queue?("20", view)
    refute BlockerPropagation.optimistic_queue?("30", view)
    refute BlockerPropagation.optimistic_queue?("40", view)
  end
end
