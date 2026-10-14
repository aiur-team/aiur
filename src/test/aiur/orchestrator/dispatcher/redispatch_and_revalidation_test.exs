defmodule Aiur.Orchestrator.Dispatcher.RedispatchAndRevalidationTest do
  use Aiur.DispatcherTestSupport

  describe "redispatch_ready?/4" do
    test "treats the current issue's worker slot as a transferable reservation" do
      write_workflow_file!(Workflow.workflow_file_path(),
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1
      )

      issue = %Issue{id: "issue-1", identifier: "repo#1", selected_backend: "claude"}

      state = %State{
        running: %{
          issue.id => %{
            issue: issue,
            worker_host: "worker-a",
            control: %{status: :working}
          }
        }
      }

      assert :ok = Dispatcher.redispatch_ready?(state, issue, "worker-a", now_ms: 1_000)
      assert thrash_budget(state) == %{}
    end

    test "rejects a swap before teardown when the next restart would trip thrash protection" do
      issue = %Issue{id: "issue-1", identifier: "repo#1", selected_backend: "claude"}

      state = %State{
        dispatch_recovery: dispatch_recovery(%{issue.id => %{window_start_ms: 0, count: 6}})
      }

      assert {:error, :thrash_circuit_open} =
               Dispatcher.redispatch_ready?(state, issue, nil, now_ms: 1_000)

      assert get_in(thrash_budget(state), [issue.id, :count]) == 6
    end

    test "does not silently migrate a remote workspace when its worker is unavailable" do
      write_workflow_file!(Workflow.workflow_file_path(),
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1
      )

      issue = %Issue{id: "issue-1", identifier: "repo#1", selected_backend: "claude"}

      assert {:error, :preferred_worker_unavailable} =
               Dispatcher.redispatch_ready?(%State{}, issue, "worker-b", now_ms: 1_000)
    end
  end

  describe "revalidate_issue_for_dispatch/3" do
    test "returns :ok when issue is found and passes the retry candidate check" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:ok, ^issue} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:skip, :missing} when the fetcher returns an empty list" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, []} end

      assert {:skip, :missing} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:skip, issue} when the issue is in a terminal state" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "done"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:skip, ^issue} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:error, reason} when the fetcher fails" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:error, :network_error} end

      assert {:error, :network_error} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    # #2444: a short, self-clearing local budget hold on the issue refresh is
    # waited out and the revalidation succeeds, so dispatch never declines with
    # `tracker_revalidation_failed` for a hold that would have cleared in
    # seconds (#2311, #2393, #2420). The sleep is injected; the assertion is on
    # the revalidation succeeding (a `{:ok, issue}`), not on a log line.
    test "waits out a short local hold and the revalidation succeeds" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      reset_at = DateTime.add(DateTime.utc_now(), 2, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      detail = %{reason: {:aiur, :locally_held, hold}, hold: hold}
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fetcher = fn _ids ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        if attempt == 1, do: {:error, {:github, :local_hold, detail}}, else: {:ok, [issue]}
      end

      assert {:ok, ^issue} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states, local_hold_sleep_fun: fn _ms -> :ok end)

      # One held fetch, then a successful retry.
      assert Agent.get(counter, & &1) == 2
    end

    # #2444 mutation guard at this site: a hold whose `reset_at` is beyond the
    # ceiling is a genuine capacity problem and must still fail revalidation —
    # without this bound, waiting would be indistinguishable from swallowing
    # the error.
    test "a local hold beyond the ceiling still fails revalidation" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      reset_at = DateTime.add(DateTime.utc_now(), 120, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      detail = %{reason: {:aiur, :locally_held, hold}, hold: hold}
      error = {:github, :local_hold, detail}

      assert {:error, ^error} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fn _ids -> {:error, error} end, terminal_states, local_hold_sleep_fun: fn _ -> flunk("must not sleep for a beyond-ceiling hold") end)
    end

    test "passes through non-Issue values unchanged" do
      assert {:ok, :not_an_issue} =
               Dispatcher.revalidate_issue_for_dispatch(:not_an_issue, nil, nil)
    end
  end

  # #2444 acceptance at the dispatch boundary: a short local budget hold on the
  # post-selection revalidation is waited out, so the ticket is dispatched
  # instead of declining with `tracker_revalidation_failed` (the decline that
  # showed up on #2311, #2393 and #2420 after a restart burst).
  describe "dispatch revalidation local-hold wait-out (#2444)" do
    test "a short hold on the issue refresh is waited out and the dispatch proceeds" do
      test_pid = self()
      candidate = %{issue("hold-refresh") | selected_backend: "codex"}
      reset_at = DateTime.add(DateTime.utc_now(), 2, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      detail = %{reason: {:aiur, :locally_held, hold}, hold: hold}
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      runner = fn dispatched, _recipient, _opts ->
        send(test_pid, {:agent_runner_run, dispatched.id})
        :ok
      end

      next_state =
        Dispatcher.dispatch_issue(%State{max_concurrent_agents: 4, effective_concurrent_agents: 4}, candidate, nil, nil,
          issue_fetcher: fn [id] ->
            attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

            if attempt == 1 do
              {:error, {:github, :local_hold, detail}}
            else
              {:ok, [%{candidate | id: id}]}
            end
          end,
          blocked_by_hydrator: fn refreshed -> {:ok, refreshed} end,
          local_hold_sleep_fun: fn _ms -> :ok end,
          runner: runner
        )

      assert_receive {:agent_runner_run, dispatched_id}, 1000
      assert dispatched_id == candidate.id
      assert Map.has_key?(next_state.running, candidate.id)
      # No `tracker_revalidation_failed` decline was recorded.
      refute Map.has_key?(next_state.dispatch_declines, candidate.id)
      assert Agent.get(counter, & &1) == 2
    end
  end
end
