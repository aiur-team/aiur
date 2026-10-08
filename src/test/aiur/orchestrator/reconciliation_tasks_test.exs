defmodule Aiur.Orchestrator.ReconciliationTasksTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
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
    assert Map.get(next.terminal_verification_attempts, issue.id, 0) == 0
  end

  test "asynchronous idle verification abandons an unresolved id after five completed reads" do
    issue = %Issue{id: "async-abandoned", identifier: "async-#{System.unique_integer([:positive])}", state: "in-progress"}
    topic = "ticket.#{issue.identifier}.terminal_verification_abandoned"
    :ok = Exchange.subscribe(topic)

    final =
      Enum.reduce(1..5, owned_state(last_polled_issues: %{issue.id => issue}), fn count, state ->
        pending = IssueSync.sync_polled_issue_state(state, [], fn [_] -> {:ok, []} end, fn _, _ -> flunk("absent ticket") end, MapSet.new(["done"]), fn _ -> :ok end, fn _, _ -> :ok end)
        assert pending.terminal_verification_attempts == %{issue.id => Map.get(state.terminal_verification_attempts, issue.id, 0)}
        assert pending.last_polled_issues == %{issue.id => issue}
        next = finish_task(pending)

        if count < 5 do
          assert next.last_polled_issues == %{issue.id => issue}
          assert next.terminal_verification_attempts == %{issue.id => count}
          refute_received {:event, %{topic: ^topic}}
        end

        next
      end)

    assert final.last_polled_issues == %{}
    assert final.terminal_verification_attempts == %{}
    receive_barrier({:event, %{topic: ^topic} = alert})
    assert alert["reason"] =~ "unresolved after 5 attempts"
    refute_received {:event, %{topic: ^topic}}
    :ok = Exchange.unsubscribe(topic)
  end

  test "a hanging idle verifier timeout counts as one attempt and ignores duplicate timeout delivery" do
    issue = %Issue{id: "hung-read", identifier: "hung-read", state: "in-progress"}
    parent = self()

    pending =
      IssueSync.sync_polled_issue_state(
        owned_state(last_polled_issues: %{issue.id => issue}),
        [],
        fn [_] ->
          wait_for_release(parent)
          {:ok, []}
        end,
        fn _, _ -> flunk("a hanging verifier cannot observe membership") end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _, _ -> :ok end
      )

    receive_barrier({:io_waiting, worker})
    [ref] = Map.keys(pending.tracker_tasks)
    assert pending.terminal_verification_attempts == %{issue.id => 0}
    assert {:noreply, timed_out} = Aiur.Orchestrator.handle_info({:tracker_task_timeout, ref}, pending)
    refute Process.alive?(worker)
    assert timed_out.tracker_tasks == %{}
    assert timed_out.last_polled_issues == %{issue.id => issue}
    assert timed_out.terminal_verification_attempts == %{issue.id => 1}
    assert {:noreply, ^timed_out} = Aiur.Orchestrator.handle_info({:tracker_task_timeout, ref}, timed_out)
  end

  test "overlapping polls count one completed idle verification read only once" do
    issue = %Issue{id: "held-read", identifier: "held-read", state: "in-progress"}
    parent = self()

    fetch = fn [_] ->
      wait_for_release(parent)
      {:ok, []}
    end

    poll = fn state, issues ->
      IssueSync.sync_polled_issue_state(state, issues, fetch, fn _, _ -> :ok end, MapSet.new(["done"]), fn _ -> :ok end, fn _, _ -> :ok end)
    end

    pending = poll.(owned_state(last_polled_issues: %{issue.id => issue}), [])
    receive_barrier({:io_waiting, worker})

    overlapping =
      Enum.reduce(1..5, pending, fn n, state ->
        poll.(state, [%Issue{id: "new-#{n}", identifier: "new-#{n}", state: "todo"}])
      end)

    send(worker, :release)
    completed = finish_task(overlapping)
    assert completed.last_polled_issues[issue.id] == issue
    assert completed.terminal_verification_attempts == %{issue.id => 1}
  end

  test "a returned active ticket fences an in-flight idle verification attempt" do
    issue = %Issue{id: "returned-pending", identifier: "returned-pending", state: "in-progress"}
    parent = self()

    poll = fn state, issues, fetch ->
      IssueSync.sync_polled_issue_state(state, issues, fetch, fn _, _ -> :ok end, MapSet.new(["done"]), fn _ -> :ok end, fn _, _ -> :ok end)
    end

    pending =
      poll.(owned_state(last_polled_issues: %{issue.id => issue}), [], fn [_] ->
        wait_for_release(parent)
        {:ok, []}
      end)

    receive_barrier({:io_waiting, worker})
    returned = poll.(pending, [issue], fn _ -> flunk("active return needs no refresh") end)
    assert returned.terminal_verification_attempts == %{}
    send(worker, :release)
    completed = finish_task(returned)
    assert completed.last_polled_issues == %{issue.id => issue}
    assert completed.terminal_verification_attempts == %{}
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
    assert Map.get(next.terminal_verification_attempts, issue.id, 0) == 0
    refute Map.has_key?(next.last_polled_issues, issue.id)
  end

  test "a startup release failure arriving after a second poll still schedules its retry" do
    issue = %Issue{id: "startup-retry", identifier: "3213", state: "in-progress"}
    parent = self()

    opts = [
      active_states: ["todo", "in-progress"],
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
