defmodule Aiur.Orchestrator.OrphanClaimRecoveryTest do
  use Aiur.TestSupport

  # One recovery lifecycle owns these scenarios: observation, guarded release, and async poll completion.

  alias Aiur.Issue
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, StartupClaimReconciler, State, TrackerTasks}
  alias Aiur.Orchestrator.StartupClaimReconciler.Observation

  test "booted orphan becomes dispatchable after the grace period with one comment and Executor wake" do
    issue = issue()
    opts = opts()
    {waiting, [^issue]} = StartupClaimReconciler.reconcile(%State{}, [issue], Keyword.put(opts, :now_ms, 0))
    assert waiting.orphaned_claim_since == %{"3622" => 0}
    assert Observation.dispatch_candidates(waiting, [issue]) == []
    refute_received {:write, _, _, _}
    refute_received {:comment, _, _}

    {waiting, [^issue]} = StartupClaimReconciler.reconcile(waiting, [issue], Keyword.put(opts, :now_ms, 59_999))
    refute_received {:write, _, _, _}

    {released, [todo]} = StartupClaimReconciler.reconcile(waiting, [issue], Keyword.put(opts, :now_ms, 60_000))
    assert todo.state == "todo"
    assert todo.state_labels == ["todo"]
    assert_received {:write, "3622", "todo", "in-progress"}
    assert_received {:comment, "3622", body}
    assert body =~ "no live worker or workspace lease"
    assert body =~ "grace period"
    assert_received {:alert, "ticket.3622.agent.attention.startup_orphan_claim_released", alert}
    assert alert[:central] and alert[:durable]
    refute alert[:needs_attention]
    assert Observation.dispatch_candidates(released, [todo]) == [todo]
    assert DispatchPolicy.dispatch_decision(todo, released, MapSet.new(["todo"]), MapSet.new()) == :dispatch
    {_, [^todo]} = StartupClaimReconciler.reconcile(released, [todo], Keyword.put(opts, :now_ms, 120_000))
    refute_received {:write, _, _, _}
    refute_received {:comment, _, _}
  end

  test "a claimed same-boot marker cannot disable recovery after an Orchestrator restart" do
    opts = Keyword.put(opts(), :read_boot_marker_fun, fn -> {:ok, Aiur.Boot.run_id()} end)
    {waiting, [_]} = StartupClaimReconciler.reconcile(%State{}, [issue()], Keyword.put(opts, :now_ms, 0))
    {_, [%Issue{state: "todo"}]} = StartupClaimReconciler.reconcile(waiting, [issue()], Keyword.put(opts, :now_ms, 60_000))
    assert_received {:write, "3622", "todo", "in-progress"}
  end

  test "periodic polls recover an orphan discovered after startup completed" do
    {complete, []} = StartupClaimReconciler.reconcile(%State{}, [], opts())
    {waiting, [_]} = StartupClaimReconciler.reconcile(complete, [issue()], Keyword.put(opts(), :now_ms, 0))
    {_, [%Issue{state: "todo"}]} = StartupClaimReconciler.reconcile(waiting, [issue()], Keyword.put(opts(), :now_ms, 60_000))
    assert_received {:write, "3622", "todo", "in-progress"}
    assert_received {:comment, "3622", _body}
  end

  for {name, mergeable, threads, reviews, target} <- [
        {"conflict", false, [], [], "rework"},
        {"unresolved finding", true, [%{body: "fix this"}], [], "rework"},
        {"current trusted body review", true, [], [%{:authoritative => true, "state" => "CHANGES_REQUESTED", "commit_id" => "head"}], "rework"},
        {"current blocking comment", true, [], [%{:authoritative => true, "state" => "COMMENTED", "commit_id" => "head", "body" => "Blocking: fix the race"}], "rework"},
        {"old resolved verdict", true, [], [%{:authoritative => true, "state" => "CHANGES_REQUESTED", "commit_id" => "old"}], "human-review"},
        {"untrusted review", true, [], [%{:authoritative => false, "state" => "CHANGES_REQUESTED", "commit_id" => "head"}], "human-review"},
        {"clear PR", true, [], [], "human-review"}
      ] do
    test "routes an orphan with #{name} to #{target}" do
      pr = %{"number" => 42, "mergeable" => unquote(mergeable), "head" => %{"sha" => "head"}}
      opts = pr_opts(pr, unquote(Macro.escape(threads)), unquote(Macro.escape(reviews)))
      {waiting, [_]} = StartupClaimReconciler.reconcile(%State{}, [issue()], Keyword.put(opts, :now_ms, 0))
      {_, [released]} = StartupClaimReconciler.reconcile(waiting, [issue()], Keyword.put(opts, :now_ms, 60_000))
      assert released.state == unquote(target)
      assert_received {:write, "3622", unquote(target), "in-progress"}
      assert_received {:comment, "3622", body}
      assert body =~ unquote(target)
      refute_received {:comment, _, _}
    end
  end

  test "unknown mergeability retains the claim rather than guessing a review state" do
    opts = pr_opts(%{"number" => 42, "mergeable" => nil}, [], [])
    {waiting, [_]} = StartupClaimReconciler.reconcile(%State{}, [issue()], Keyword.put(opts, :now_ms, 0))
    {failed, [%Issue{state: "in-progress"}]} = StartupClaimReconciler.reconcile(waiting, [issue()], Keyword.put(opts, :now_ms, 60_000))
    assert failed.startup_claim_reconciliation_failures["3622"].reason == :mergeability_unknown
    assert Observation.dispatch_candidates(failed, [issue()]) == []
    refute_received {:write, _, _, _}
    refute_received {:comment, _, _}
  end

  for {name, issue, state} <- [
        {"human pause", %{paused: true, labels: ["agent:in-progress", "agent:paused"]}, %{}},
        {"parked ticket", %{parked: true}, %{}},
        {"scheduled retry", %{}, %{retry_attempts: %{"issue-3622" => %{attempt: 1}}}},
        # RetryEngine stages a released workspace wait by issue id, not identifier.
        {"staged redispatch", %{}, %{dispatch_recovery: %{workspace_ownership: %{waits: %{}, ready: %{"issue-3622" => %{}}}, codex_thrash_budget: %{}}}}
      ] do
    test "protects #{name} across periodic recovery" do
      ticket = struct(issue(), unquote(Macro.escape(issue)))
      state = struct(State, unquote(Macro.escape(state)))
      {waiting, [^ticket]} = StartupClaimReconciler.reconcile(state, [ticket], Keyword.put(opts(), :now_ms, 0))
      {_, [^ticket]} = StartupClaimReconciler.reconcile(waiting, [ticket], Keyword.put(opts(), :now_ms, 60_000))
      refute_received {:write, _, _, _}
      refute_received {:comment, _, _}
    end
  end

  # Future regression guard: live-worker protection predates periodic recovery.
  test "a live worker protects its claim" do
    state = %State{running: %{"issue-3622" => %{identifier: "3622", pid: self()}}}
    {waiting, [_]} = StartupClaimReconciler.reconcile(state, [issue()], Keyword.put(opts(), :now_ms, 0))
    {_, [%Issue{state: "in-progress"}]} = StartupClaimReconciler.reconcile(waiting, [issue()], Keyword.put(opts(), :now_ms, 60_000))
    refute_received {:write, _, _, _}
    refute_received {:comment, _, _}
  end

  test "a workspace lease appearing during grace protects a surviving worker and resets its age" do
    {waiting, [_]} = StartupClaimReconciler.reconcile(%State{}, [issue()], Keyword.put(opts(), :now_ms, 0))
    leased = Keyword.merge(opts(), now_ms: 60_000, ownership_fun: fn _ -> {:ok, %{phase: :active}} end)
    {protected, [_]} = StartupClaimReconciler.reconcile(waiting, [issue()], leased)
    assert protected.orphaned_claim_since == %{}
    refute_received {:write, _, _, _}
    {waiting, [_]} = StartupClaimReconciler.reconcile(protected, [issue()], Keyword.put(opts(), :now_ms, 120_000))
    assert waiting.orphaned_claim_since == %{"3622" => 120_000}
    refute_received {:write, _, _, _}
  end

  test "asynchronous release updates tracker truth and comments only once" do
    state = %State{snapshot_key: self()}
    {waiting, [_]} = StartupClaimReconciler.reconcile(state, [issue()], Keyword.put(opts(), :now_ms, 0))
    {pending, []} = StartupClaimReconciler.reconcile(waiting, [issue()], Keyword.put(opts(), :now_ms, 60_000))
    [ref] = Map.keys(pending.tracker_tasks)

    receive_barrier({^ref, result})
    assert {:handled, released} = TrackerTasks.result(pending, ref, result)
    assert released.last_polled_issues["issue-3622"].state == "todo"
    assert released.orphaned_claim_since == %{}
    assert_received {:write, "3622", "todo", "in-progress"}
    assert_received {:comment, "3622", _body}
    refute_received {:write, _, _, _}
    refute_received {:comment, _, _}
  end

  test "candidate polls retain grace-period status and apply async release after snapshot refresh" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["todo", "in-progress", "rework", "human-review"])
    WorkflowStore.force_reload()

    poll_opts = [
      fetch_candidate_issues_fun: fn current -> {:ok, [issue()], current} end,
      stranded_reconciliation_fun: fn current, candidates ->
        send(self(), {:stranded_candidates, candidates})
        current
      end,
      startup_claim_opts: Keyword.put(opts(), :now_ms, 0)
    ]

    waiting = Dispatcher.dispatch_candidate_poll(%State{snapshot_key: self(), max_concurrent_agents: 0, effective_concurrent_agents: 0}, poll_opts)
    assert waiting.last_polled_issues["issue-3622"].state == "in-progress"
    assert waiting.running == %{}
    assert_received {:stranded_candidates, []}
    refute_received {:write, _, _, _}
    pending = Dispatcher.dispatch_candidate_poll(waiting, Keyword.put(poll_opts, :startup_claim_opts, Keyword.put(opts(), :now_ms, 60_000)))
    [ref] = Map.keys(pending.tracker_tasks)
    receive_barrier({^ref, result})
    assert {:handled, released} = TrackerTasks.result(pending, ref, result)
    assert released.last_polled_issues["issue-3622"].state == "todo"
    assert_received {:comment, "3622", _body}
    refute_received {:comment, _, _}
  end

  test "later approval on the same head clears a body-only blocking verdict" do
    pr = %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}

    reviews = [
      %{:authoritative => true, "state" => "CHANGES_REQUESTED", "commit_id" => "head", "submitted_at" => "2026-10-09T00:00:00Z", "user" => %{"login" => "reviewer"}},
      %{:authoritative => true, "state" => "APPROVED", "commit_id" => "head", "submitted_at" => "2026-10-09T01:00:00Z", "user" => %{"login" => "reviewer"}}
    ]

    opts = pr_opts(pr, [], reviews)
    {waiting, [_]} = StartupClaimReconciler.reconcile(%State{}, [issue()], Keyword.put(opts, :now_ms, 0))
    {_, [%Issue{state: "human-review"}]} = StartupClaimReconciler.reconcile(waiting, [issue()], Keyword.put(opts, :now_ms, 60_000))
    assert_received {:write, "3622", "human-review", "in-progress"}
  end

  test "unavailable PR evidence does not permanently exhaust release retries" do
    opts = pr_opts(%{"number" => 42, "mergeable" => nil}, [], [])
    {waiting, [_]} = StartupClaimReconciler.reconcile(%State{}, [issue()], Keyword.put(opts, :now_ms, 0))

    failed =
      Enum.reduce(1..4, waiting, fn n, current ->
        {next, [%Issue{state: "in-progress"}]} = StartupClaimReconciler.reconcile(current, [issue()], Keyword.put(opts, :now_ms, n * 60_000))
        next
      end)

    good = pr_opts(%{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}, [], [])
    {_, [%Issue{state: "human-review"}]} = StartupClaimReconciler.reconcile(failed, [issue()], Keyword.put(good, :now_ms, 300_000))
    assert_received {:write, "3622", "human-review", "in-progress"}
  end

  test "a lease acquired during PR lookup prevents the label write" do
    parent = self()

    opts =
      Keyword.merge(opts(),
        ownership_fun: fn _ ->
          if Process.get(:lease_acquired), do: {:ok, %{phase: :active}}, else: :none
        end,
        open_pr_fetcher: fn _ ->
          Process.put(:lease_acquired, true)
          send(parent, :lease_acquired)
          {:ok, nil}
        end
      )

    {waiting, [_]} = StartupClaimReconciler.reconcile(%State{}, [issue()], Keyword.put(opts, :now_ms, 0))
    {_, [%Issue{state: "in-progress"}]} = StartupClaimReconciler.reconcile(waiting, [issue()], Keyword.put(opts, :now_ms, 60_000))
    assert_received :lease_acquired
    refute_received {:write, _, _, _}
    refute_received {:comment, _, _}
  end

  test "a failed comment alerts the Executor without releasing or commenting twice" do
    opts = Keyword.put(opts(), :create_comment_fun, fn _, _ -> {:error, :comment_denied} end)
    {waiting, [_]} = StartupClaimReconciler.reconcile(%State{}, [issue()], Keyword.put(opts, :now_ms, 0))
    {released, [todo]} = StartupClaimReconciler.reconcile(waiting, [issue()], Keyword.put(opts, :now_ms, 60_000))
    assert todo.state == "todo"
    assert_received {:write, "3622", "todo", "in-progress"}
    assert_received {:alert, "ticket.3622.agent.attention.orphan_release_comment_failed", alert}
    assert alert[:needs_attention] and alert[:durable]
    StartupClaimReconciler.reconcile(released, [todo], opts)
    refute_received {:write, _, _, _}
  end

  defp issue do
    %Issue{id: "issue-3622", identifier: "3622", title: "Recover orphan", state: "in-progress", state_labels: ["in-progress"]}
  end

  defp opts do
    parent = self()

    [
      now_ms: 0,
      active_states: ["todo", "in-progress", "rework", "human-review"],
      ownership_fun: fn _ -> :none end,
      open_pr_fetcher: fn _ -> {:ok, nil} end,
      update_issue_state_fun: fn id, target, expected ->
        send(parent, {:write, id, target, expected})
        :ok
      end,
      create_comment_fun: fn id, body ->
        send(parent, {:comment, id, body})
        :ok
      end,
      emit_alert_fun: fn topic, alert -> send(parent, {:alert, topic, alert}) end
    ]
  end

  defp pr_opts(pr, threads, reviews) do
    Keyword.merge(opts(),
      open_pr_fetcher: fn "3622" -> {:ok, %{"number" => 42}} end,
      pr_fetcher: fn 42 -> {:ok, pr} end,
      unresolved_threads_fetcher: fn _ -> {:ok, threads} end,
      reviews_fetcher: fn 42 -> {:ok, reviews} end
    )
  end
end
