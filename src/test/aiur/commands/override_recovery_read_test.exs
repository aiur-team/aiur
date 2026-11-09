defmodule Aiur.Commands.OverrideRecoveryReadTest do
  use Aiur.TestSupport

  alias Aiur.{Commands, DecisionStore, Issue}
  alias Aiur.Orchestrator.{OverrideResume, OverrideSuccessor, State, TrackerTasks}
  alias Aiur.TestSupport.Isolation

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["in-progress"])
    dir = Aiur.TestSupport.tmp_root!("override-recovery-read")
    File.mkdir_p!(Path.join(dir, "workspace"))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    store_opts = [name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end]
    store = start_supervised!({DecisionStore, store_opts})
    actor = [actor: %{kind: :operator, id: "human"}, actor_source: :dashboard_session]

    {:ok, %{decision: request}} =
      Commands.request(
        %{question: "Direction?", blocking: false, source_id: "read", authority: :supervisor_allowed, reversibility: :reversible},
        [ticket: %{identifier: "6911"}, source: %{agent_id: "worker", session_id: "lost"}],
        store
      )

    {:ok, %{decision: first}} = Commands.answer(request.decision_id, answer("first", "Old direction"), actor, store)
    pr = %{number: 77, state: :open, merged?: false, head_sha: "before", head_ref: "existing", branch_exists?: true}

    {:ok, %{decision: decision}} =
      Commands.override(first.decision_id, answer("override", "New direction"), Keyword.put(actor, :override_context, %{pr: pr, worker: :resumable, capacity: :available}), store)

    issue = %Issue{id: "6911", identifier: "6911", title: "Recovery", state: "in-progress", labels: ["agent:in-progress"]}
    %{dir: dir, store: store, store_opts: store_opts, decision: decision, issue: issue, pr: pr}
  end

  test "normal T2 resume uses only cached PR routing even when fresh GitHub reads would fail", ctx do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["in-progress"])
    Isolation.with_app_env!(:aiur, :memory_tracker_issues, [ctx.issue])
    loaded = OverrideResume.load([ctx.decision])
    assert [{_, {:ok, [issue]}, {:ok, nil}}] = loaded
    assert issue.id == ctx.issue.id

    opts =
      options(ctx,
        recovery_read_fun: fn _ -> flunk("normal T2 resume must not read GitHub") end,
        resume_fun: fn state, issue, _ ->
          send(parent, :resumed)
          {{:ok, :started}, %{state | running: %{issue.id => entry(issue, :working)}}}
        end
      )

    next = OverrideResume.apply_loaded(%State{max_concurrent_agents: 1}, loaded, opts)
    assert_received :resumed
    assert next.running[ctx.issue.id].control.status == :working
  end

  # Future regression guard for the recovery-only admission boundary.
  test "capacity waits and active workers never issue fresh recovery reads", ctx do
    opts = options(ctx, recovery_read_fun: fn _ -> flunk("waiting or active overrides must not read GitHub") end)
    busy = %{ctx.issue | id: "busy", identifier: "busy"}
    full = %State{max_concurrent_agents: 1, running: %{busy.id => entry(busy, :working)}}
    assert apply_request(full, ctx, opts).running == full.running
    active = %State{max_concurrent_agents: 1, running: %{ctx.issue.id => entry(ctx.issue, :working)}}
    assert apply_request(active, ctx, opts).running == active.running
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{resume_attempts: 0}] = decision.overrides
  end

  test "worker capacity blocks recovery reads before touching GitHub", ctx do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["in-progress"],
      max_concurrent_agents: 3,
      worker_ssh_hosts: ["worker-host"],
      worker_max_concurrent_agents_per_host: 1
    )

    busy = %{ctx.issue | id: "busy", identifier: "busy"}
    busy_entry = Map.put(entry(busy, :working), :worker_host, "worker-host")
    state = %State{max_concurrent_agents: 3, running: %{ctx.issue.id => entry(ctx.issue, :unrecoverable), busy.id => busy_entry}}
    opts = options(ctx, recovery_read_fun: fn _ -> flunk("worker capacity must be checked before fresh recovery reads") end)
    apply_request(state, ctx, opts)
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{route: :capacity_wait, resume_reason: :capacity, resume_attempts: 0}] = decision.overrides
    refute Map.has_key?(hd(decision.overrides), :read_attempts)
  end

  test "only admitted recovery reads fresh evidence, with durable exponential backoff and recovery", ctx do
    parent = self()

    opts =
      options(ctx,
        now_ms: 1_000,
        recovery_read_fun: fn 77 ->
          send(parent, :fresh)
          {:error, :rate_limited}
        end,
        recovery_issue_fun: fn _ -> flunk("a failed PR read cannot authorize issue reads") end
      )

    state = %State{max_concurrent_agents: 1, running: %{ctx.issue.id => entry(ctx.issue, :unrecoverable)}}
    state = apply_request(state, ctx, opts)
    assert_received :fresh
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{state: :queued, read_attempts: 1, read_retry_at: 61_000}] = decision.overrides
    apply_request(state, ctx, Keyword.put(opts, :now_ms, 60_999))
    refute_received :fresh

    assert :ok = stop_supervised(DecisionStore)
    store = start_supervised!({DecisionStore, ctx.store_opts})
    ctx = %{ctx | store: store}
    opts = Keyword.put(opts, :decision_store, store)
    apply_request(state, ctx, Keyword.put(opts, :now_ms, 60_999))
    refute_received :fresh
    state = apply_request(state, ctx, Keyword.put(opts, :now_ms, 61_000))
    assert_received :fresh
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, store)
    assert [%{state: :queued, read_attempts: 2, read_retry_at: 181_000}] = decision.overrides

    opts =
      Keyword.merge(opts,
        now_ms: 181_000,
        recovery_read_fun: fn 77 ->
          send(parent, :fresh)
          {:ok, ctx.pr}
        end,
        recovery_issue_fun: fn ["6911"] -> {:ok, [ctx.issue]} end,
        replacement_fun: fn current, issue, _, pr, _ ->
          assert pr.head_ref == "existing"
          send(parent, :replaced)
          {{:ok, :started}, %{current | running: %{issue.id => entry(issue, :working)}}}
        end
      )

    next = apply_request(state, ctx, opts)
    assert_received :fresh
    assert_received :replaced
    assert next.running[ctx.issue.id].control.status == :working
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, store)
    assert [%{state: :queued, read_attempts: 0, read_retry_at: 241_000}] = decision.overrides
  end

  test "polls during one pending lookup count one failed read", ctx do
    parent = self()

    opts =
      options(ctx,
        now_ms: 1_000,
        recovery_read_fun: fn _ ->
          send(parent, {:fresh_started, self()})
          receive do: (:release -> {:error, :rate_limited})
        end
      )

    state = %State{snapshot_key: self(), max_concurrent_agents: 1, running: %{ctx.issue.id => entry(ctx.issue, :unrecoverable)}}
    pending = apply_request(state, ctx, opts)
    receive_barrier({:fresh_started, worker})
    on_exit(fn -> Process.exit(worker, :kill) end)
    # A delayed receipt changes Command metadata without changing the override action.
    assert {:ok, _} = Commands.record_command_fact(ctx.decision.decision_id, :executor_acknowledged, %{executor_id: "executor", via: :explicit, at: DateTime.utc_now()}, server: ctx.store)
    pending = apply_request(pending, ctx, opts)
    [ref] = Map.keys(pending.tracker_tasks)
    send(worker, :release)
    receive_barrier({^ref, result})
    assert {:handled, _} = TrackerTasks.result(pending, ref, result)
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{read_attempts: 1, read_retry_at: 61_000}] = decision.overrides
  end

  test "a pending lookup cannot overwrite an override delivered by a resumed worker", ctx do
    parent = self()

    opts =
      options(ctx,
        now_ms: 1_000,
        recovery_read_fun: fn _ ->
          send(parent, {:fresh_started, self()})
          receive do: (:release -> {:error, :rate_limited})
        end
      )

    state = %State{snapshot_key: self(), max_concurrent_agents: 1, running: %{ctx.issue.id => entry(ctx.issue, :unrecoverable)}}
    pending = apply_request(state, ctx, opts)
    receive_barrier({:fresh_started, worker})
    on_exit(fn -> Process.exit(worker, :kill) end)
    assert {:ok, _} = Commands.record_command_fact(ctx.decision.decision_id, :override_prompt_delivered, %{action_id: ctx.decision.active_action_id, at: DateTime.utc_now()}, server: ctx.store)
    [ref] = Map.keys(pending.tracker_tasks)
    send(worker, :release)
    receive_barrier({^ref, result})
    assert {:handled, _} = TrackerTasks.result(pending, ref, result)
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{state: :delivered}] = decision.overrides
    refute Map.has_key?(hd(decision.overrides), :read_attempts)
  end

  test "successful recovery observations also wait before another fresh read", ctx do
    parent = self()
    state = %State{max_concurrent_agents: 1, running: %{ctx.issue.id => entry(ctx.issue, :unrecoverable)}}

    opts =
      options(ctx,
        now_ms: 1_000,
        recovery_read_fun: fn _ ->
          send(parent, :fresh)
          {:ok, ctx.pr}
        end,
        recovery_issue_fun: fn _ -> {:ok, [ctx.issue]} end,
        replacement_fun: fn current, _, _, _, _ -> {{:error, :replacement_failed}, current} end
      )

    state = apply_request(state, ctx, opts)
    assert_received :fresh
    apply_request(state, ctx, Keyword.put(opts, :now_ms, 60_999))
    refute_received :fresh
    apply_request(state, ctx, Keyword.put(opts, :now_ms, 61_000))
    assert_received :fresh
  end

  test "an operator pause after retirement starts prevents successor release", ctx do
    record = Commands.pending_override(ctx.decision) |> Map.put(:resume_reason, :branch_missing)

    opts = [
      label_prefix: "agent",
      successor_fun: fn _, _, _, _ -> {:ok, %{identifier: "9000"}} end,
      close_fun: fn _, _ -> :ok end,
      comment_fun: fn _, _ -> :ok end,
      marker_fun: fn _, _, _ -> :ok end,
      issues: fn ["6911"] -> {:ok, [%{ctx.issue | paused: true}]} end,
      release_fun: fn _ -> flunk("operator pause must keep the successor parked") end
    ]

    assert {:hold, :operator_pause} = OverrideSuccessor.reconcile(ctx.decision, record, ctx.pr, opts)
  end

  defp options(ctx, extra) do
    Keyword.merge(
      [decision_store: ctx.store, admission_fun: fn _ -> :dispatch end, workspace_path_fun: fn _ -> Path.join(ctx.dir, "workspace") end],
      extra
    )
  end

  defp apply_request(state, ctx, opts), do: OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [ctx.issue]}, {:ok, ctx.pr}}], opts)
  defp entry(issue, status), do: %{identifier: issue.identifier, issue: issue, control: %{status: status}}
  defp answer(key, text), do: %{expected_version: 1, idempotency_key: key, custom_response: text, rationale: "Changed direction"}
end
