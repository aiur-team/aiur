defmodule Aiur.Orchestrator.ReconciliationTasksTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.{IssueSync, MergedTicketReconciler, Reconciler, StartupClaimReconciler, State, TrackerTasks, WorkspaceCleanup}

  test "startup cleanup runs off the owner in order and never returns an old state" do
    parent = self()

    pending =
      WorkspaceCleanup.start_startup_workspace_cleanup(owned_state(),
        terminal_cleanup_fun: fn state ->
          wait_for_release(parent)
          %{state | completed: MapSet.new(["worker-only"])}
        end,
        todo_cleanup_fun: fn state ->
          assert MapSet.member?(state.completed, "worker-only")
          send(parent, :todo_cleanup_finished)
          state
        end
      )

    assert TrackerTasks.running?(pending, :startup_workspace_cleanup)
    receive_barrier({:io_waiting, worker})
    current = %{pending | completed: MapSet.new(["current-owner"])}
    send(worker, :release)
    next = finish_task(current)
    receive_barrier(:todo_cleanup_finished)
    assert next.completed == MapSet.new(["current-owner"])
    refute TrackerTasks.running?(next, :startup_workspace_cleanup)
  end

  test "a missing-running read returns before I/O and cannot mutate a replacement generation" do
    issue = %Issue{id: "slow-running", identifier: "3213", state: "in-progress"}
    entry = %{identifier: issue.identifier, issue: issue, pid: self(), control: %{status: :working, generation: 1}}
    state = owned_state(running: %{issue.id => entry})
    parent = self()

    pending =
      Reconciler.refresh_running_issue_states(state, [], fn _ids ->
        wait_for_release(parent)
        {:ok, [%{issue | title: "old generation response"}]}
      end)

    assert map_size(pending.tracker_tasks) == 1
    receive_barrier({:io_waiting, worker})
    assert worker != self()
    replacement = put_in(pending.running[issue.id].control.generation, 2)
    send(worker, :release)
    next = finish_task(replacement)
    assert next.running[issue.id].issue == issue
    assert next.running[issue.id].control.generation == 2
  end

  test "idle terminal verification retains the ticket while reading and ignores a newly owned runtime" do
    issue = %Issue{id: "disappeared", identifier: "3213", state: "in-progress"}
    parent = self()
    state = owned_state(last_polled_issues: %{issue.id => issue}, released_claims: %{issue.id => %{reason: :retry}})

    pending =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn _ids ->
          wait_for_release(parent)
          {:ok, [%{issue | state: "done"}]}
        end,
        fn _identity, _lifecycle -> flunk("stale terminal verification must not mark membership") end,
        MapSet.new(["done"]),
        fn _status -> :ok end,
        fn _identity, _pending -> :ok end
      )

    assert pending.last_polled_issues[issue.id] == issue
    assert TrackerTasks.running?(pending, :idle_terminal_verification)
    receive_barrier({:io_waiting, worker})
    entry = %{identifier: issue.identifier, issue: issue, pid: self(), control: %{generation: 2}}
    send(worker, :release)
    next = finish_task(%{pending | running: %{issue.id => entry}})
    assert next.last_polled_issues[issue.id] == issue
    assert next.released_claims[issue.id] == %{reason: :retry}
    assert next.running[issue.id] == entry
  end

  test "label repair withholds its candidate until the write succeeds and preserves current state" do
    issue = %Issue{id: "labels", identifier: "3213", state: "todo", state_labels: ["todo", "rework"]}
    parent = self()

    {pending, candidates} =
      IssueSync.reconcile_contradictory_state_labels(owned_state(), [issue], fn identifier, target ->
        wait_for_release(parent)
        send(parent, {:written, identifier, target})
        :ok
      end)

    assert candidates == []
    assert map_size(pending.tracker_tasks) == 1
    receive_barrier({:io_waiting, worker})
    send(worker, :release)
    next = finish_task(%{pending | completed: MapSet.new(["unrelated-completion"])})
    receive_barrier({:written, "3213", "todo"})
    assert next.last_polled_issues[issue.id].state_labels == ["todo"]
    assert MapSet.member?(next.completed, "unrelated-completion")
  end

  test "startup release does not apply a late response over a newly owned runtime" do
    issue = %Issue{id: "startup", identifier: "3213", state: "in-progress"}
    parent = self()

    {pending, candidates} =
      StartupClaimReconciler.reconcile(owned_state(), [issue],
        active_states: ["todo", "in-progress"],
        grace_ms: 0,
        ownership_fun: fn _identifier -> :none end,
        open_pr_fetcher: fn _identifier -> {:ok, nil} end,
        create_comment_fun: fn _identifier, _body -> :ok end,
        read_boot_marker_fun: fn -> {:ok, nil} end,
        mark_boot_marker_fun: fn _boot -> :ok end,
        update_issue_state_fun: fn _identifier, _target, _expected ->
          wait_for_release(parent)
          :ok
        end,
        emit_alert_fun: fn _topic, _opts -> flunk("stale release must not be announced") end
      )

    assert candidates == []
    receive_barrier({:io_waiting, worker})
    entry = %{identifier: issue.identifier, issue: issue, pid: self(), control: %{generation: 2}}
    current = %{pending | running: %{issue.id => entry}}
    send(worker, :release)
    next = finish_task(current)
    assert next.running[issue.id] == entry
    refute Map.has_key?(next.last_polled_issues, issue.id)
  end

  test "a startup release failure arriving after a second poll still schedules its retry" do
    issue = %Issue{id: "startup-retry", identifier: "3213", state: "in-progress"}
    parent = self()

    opts = [
      active_states: ["todo", "in-progress"],
      grace_ms: 0,
      ownership_fun: fn _identifier -> :none end,
      open_pr_fetcher: fn _identifier -> {:ok, nil} end,
      mark_boot_marker_fun: fn _boot -> :ok end,
      update_issue_state_fun: fn _identifier, _target, _expected ->
        wait_for_release(parent)
        {:error, :temporary_failure}
      end,
      emit_alert_fun: fn _topic, _opts -> :ok end
    ]

    {pending, []} = StartupClaimReconciler.reconcile(owned_state(), [issue], Keyword.put(opts, :read_boot_marker_fun, fn -> {:ok, nil} end))
    receive_barrier({:io_waiting, worker})
    continuing_opts = Keyword.put(opts, :read_boot_marker_fun, fn -> {:ok, Aiur.Boot.run_id()} end)
    {observed, []} = StartupClaimReconciler.reconcile(pending, [issue], continuing_opts)
    send(worker, :release)
    failed = finish_task(observed)
    refute failed.startup_claim_reconciliation_complete?
    assert failed.startup_claim_reconciliation_failures[issue.identifier].attempts == 1
    {retrying, []} = StartupClaimReconciler.reconcile(failed, [issue], continuing_opts)
    assert TrackerTasks.running?(retrying, {:startup_release, issue.id})
    receive_barrier({:io_waiting, retry_worker})
    send(retry_worker, :release)
    retried = finish_task(retrying)
    assert retried.startup_claim_reconciliation_failures[issue.identifier].attempts == 2
  end

  test "merged-ticket open-PR lookup runs off the owner and writes before announcing reconciliation" do
    issue = %Issue{id: "merged", identifier: "3213", state: "in-progress"}
    now = ~U[2026-10-08 12:00:00Z]

    merge = %RecentMerge{
      id: "merge",
      repository: "owner/repo",
      number: 42,
      url: "https://github.com/owner/repo/pull/42",
      summary: "Closes #3213",
      merged_at: now,
      observation_source: :github_events,
      backfilled?: false,
      live_observed?: true,
      first_observed_at: now,
      last_observed_at: now,
      content_hash: "hash"
    }

    parent = self()

    {pending, candidates} =
      MergedTicketReconciler.reconcile(owned_state(), [issue],
        recent_merges_fun: fn -> [merge] end,
        now_fun: fn -> now end,
        open_pull_requests_fun: fn _identifier ->
          wait_for_release(parent)
          {:ok, [%{"number" => 43, "draft" => false, "review_decision" => "APPROVED"}]}
        end,
        update_issue_state_fun: fn identifier, target, expected ->
          send(parent, {:written, identifier, target, expected})
          :ok
        end,
        emit_alert_fun: fn topic, _opts ->
          send(parent, {:announced, topic})
          :ok
        end
      )

    assert candidates == []
    refute_received {:announced, _topic}
    receive_barrier({:io_waiting, worker})
    send(worker, :release)
    writing = finish_task(pending)
    assert TrackerTasks.running?(writing, {:merged_reconcile, issue.id})
    next = finish_task(writing)
    receive_barrier({:written, "3213", "human-review", "in-progress"})
    receive_barrier({:announced, "ticket.3213.dependency.merged_pr_remaining_open"})
    assert MapSet.member?(next.merged_ticket_reconciliations, {"3213", "merge"})
  end

  defp owned_state(opts \\ []), do: struct!(State, Keyword.merge([snapshot_key: self(), poll_frozen: true], opts))

  defp wait_for_release(parent) do
    send(parent, {:io_waiting, self()})

    receive do
      :release -> :ok
    end
  end

  defp finish_task(state) do
    receive_barrier({ref, result})
    assert {:handled, next} = TrackerTasks.result(state, ref, result)
    next
  end
end
