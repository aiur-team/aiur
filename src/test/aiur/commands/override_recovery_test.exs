defmodule Aiur.Commands.OverrideRecoveryTest do
  use ExUnit.Case, async: false
  alias Aiur.{Commands, DecisionStore, Issue}
  alias Aiur.Commands.OverridePrompt
  alias Aiur.Orchestrator.{DispatchPolicy, OverrideResume, OverrideSuccessor, Slots, State}

  defmodule ReleaseTracker do
    def update_issue_state("9000", "todo", []), do: send(self(), :successor_todo) && :ok

    def remove_label("9000", "agent:parked") do
      assert_received :successor_todo
      send(self(), :successor_unparked)
      :ok
    end
  end

  setup do
    dir = Aiur.TestSupport.tmp_root!("override-recovery-6911")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    File.mkdir_p!(Path.join(dir, "workspace"))
    opts = [name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000, answer_comment_publisher: fn _ -> :ok end]
    store = start_supervised!({DecisionStore, opts})
    actor = [actor: %{kind: :operator, id: "human"}, actor_source: :dashboard_session]

    {:ok, %{decision: request}} =
      Commands.request(
        %{question: "Direction?", blocking: false, source_id: "recover", authority: :supervisor_allowed, reversibility: :reversible},
        [ticket: %{identifier: "6911"}, source: %{agent_id: "worker", session_id: "lost"}],
        store
      )

    {:ok, %{decision: first}} = Commands.answer(request.decision_id, payload("first", "Old direction"), actor, store)
    pr = %{number: 77, state: :open, merged?: false, head_sha: "before", head_ref: "original-branch", branch_exists?: true}

    {:ok, %{decision: decision}} =
      Commands.override(first.decision_id, payload("override", "Use the new direction"), Keyword.put(actor, :override_context, %{pr: pr, worker: :resumable, capacity: :available}), store)

    issue = %Issue{id: "6911", identifier: "6911", title: "Recovery", state: "in-progress", labels: ["agent:in-progress"]}
    %{store: store, store_opts: opts, decision: decision, issue: issue, pr: pr}
  end

  test "three non-capacity resume failures replace the session on the same ticket and PR", ctx do
    opts = options(ctx, resume_fun: fn state, _, _ -> {{:error, :worker_not_running}, state} end)
    state = %State{max_concurrent_agents: 1}
    state = apply_request(state, ctx, opts)
    refute_received {:dispatch, _}
    state = apply_request(state, ctx, opts)
    refute_received {:dispatch, _}
    assert :ok = stop_supervised(DecisionStore)
    store = start_supervised!({DecisionStore, ctx.store_opts})
    ctx = %{ctx | store: store}
    state = apply_request(state, ctx, Keyword.put(opts, :decision_store, store))
    assert_received {:dispatch, %Issue{id: "6911", continuation_head_ref: "original-branch", pr_head_ref: nil}}
    assert Map.keys(state.running) == ["6911"]
    assert Slots.active_slots(state) == 1
    {:ok, recovered} = DecisionStore.get(ctx.decision.decision_id, store)
    assert [%{route: :replacement, recovery_path: :replacement, resume_reason: :resume_failed, resume_attempts: 3}] = recovered.overrides
    assert length(Commands.list_decisions(store)) == 1
    prompt_opts = OverridePrompt.prepare("6911", decision_store: store)
    text = OverridePrompt.render(prompt_opts)
    assert String.starts_with?(text, "Operator override")
    assert text =~ "Use the new direction"
    assert text =~ "The previous session ended; continue PR #77 from its head."
    OverridePrompt.received(%{event: :turn_started}, prompt_opts)
    {:ok, delivered} = DecisionStore.get(ctx.decision.decision_id, store)
    assert [%{state: :delivered}] = delivered.overrides
    apply_request(state, ctx, Keyword.put(opts, :decision_store, store))
    refute_received {:dispatch, _}
  end

  # Future regression guard: mutate the capacity classification to constrain this exclusion.
  test "capacity refusals never count as failed resumes or trigger replacement", ctx do
    for reason <- [:max_concurrent_agents_reached, {:max_concurrent_agents_reached, %{fleet: 1}}, {:redispatch_deferred, :max_concurrent_agents_reached}] do
      opts = options(ctx, resume_fun: fn state, _, _ -> {{:error, reason}, state} end)
      Enum.reduce(1..4, %State{max_concurrent_agents: 1}, fn _, state -> apply_request(state, ctx, opts) end)
      {:ok, waiting} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
      assert [%{route: :capacity_wait, resume_reason: :capacity, resume_attempts: 0}] = waiting.overrides
      refute_received {:dispatch, _}
    end
  end

  test "missing workspace replaces only after capacity admission and stops the old runner first", ctx do
    worker = %{issue: ctx.issue, identifier: "6911", workspace_path: Path.join(ctx.store_opts[:state_dir], "missing"), control: %{status: :paused}}
    busy = %Issue{id: "busy", identifier: "busy", state: "in-progress"}
    state = %State{max_concurrent_agents: 1, running: %{"6911" => worker, "busy" => %{issue: busy, control: %{status: :working}}}}
    opts = options(ctx)
    full = apply_request(state, ctx, opts)
    refute_received {:stopped, _}
    refute_received {:dispatch, _}
    ready = %{full | running: Map.delete(full.running, "busy")}
    next = apply_request(ready, ctx, opts)
    assert_received {:stopped, "6911"}
    assert_received {:dispatch, %Issue{id: "6911"}}
    assert Map.keys(next.running) == ["6911"]
    {:ok, replaced} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{route: :replacement, resume_reason: :workspace_missing}] = replaced.overrides
  end

  test "lost runner and missing workspace use a fresh replacement before attempting resume", ctx do
    Aiur.TestCleanup.rm_rf!(Path.join(ctx.store_opts[:state_dir], "workspace"))
    opts = options(ctx, resume_fun: fn _, _, _ -> flunk("missing workspace must not resume the lost session") end)
    next = apply_request(%State{max_concurrent_agents: 1}, ctx, opts)
    assert_received {:dispatch, %Issue{id: "6911", continuation_head_ref: "original-branch"}}
    assert Map.keys(next.running) == ["6911"]
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{resume_reason: :workspace_missing, route: :replacement}] = decision.overrides
  end

  test "replacement refusal retains override and opens an Executor Command", ctx do
    worker = %{identifier: ctx.issue.identifier, issue: ctx.issue, control: %{status: :unrecoverable}}
    state = %State{max_concurrent_agents: 1, running: %{"6911" => worker}}
    opts = options(ctx, dispatch_fun: fn state, _ -> {{:error, :replacement_failed}, state} end)
    apply_request(state, ctx, opts)
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{state: :queued, route: :replacement, resume_reason: :replacement_failed}] = decision.overrides
    assert [command] = Enum.reject(Commands.list_decisions(ctx.store), &(&1.decision_id == decision.decision_id))
    assert command.question == "Recover override for #6911?"
    assert command.decision_status == :open
  end

  test "deleted branch retires old PR before releasing exactly one successor and retargets the override", ctx do
    parent = self()
    remote = start_supervised!({Agent, fn -> %{ticket: nil, open_prs: MapSet.new([77]), creates: 0, released: false, park_attempts: 0} end})

    opts =
      options(ctx,
        label_prefix: "agent",
        find: fn _, _ -> {:ok, Agent.get(remote, & &1.ticket)} end,
        issues: fn ["6911"] -> {:ok, [ctx.issue]} end,
        create: fn attrs, _ ->
          assert "agent:parked" in attrs.labels
          refute "agent:todo" in attrs.labels
          assert attrs.body =~ "Supersedes unmerged PR: #77"
          ticket = %{"number" => 9000, "url" => "https://example.test/9000", "title" => attrs.title}
          Agent.update(remote, &%{&1 | ticket: ticket, creates: &1.creates + 1})
          {:ok, ticket}
        end,
        close_fun: fn 77, "9000" ->
          Agent.update(remote, &%{&1 | open_prs: MapSet.delete(&1.open_prs, 77)})
          send(parent, :closed)
          :ok
        end,
        comment_fun: fn "6911", body ->
          assert body == "superseded by #9000: branch_missing"
          assert_received :closed
          attempt = Agent.get_and_update(remote, fn state -> {state.park_attempts, %{state | park_attempts: state.park_attempts + 1}} end)
          if attempt == 0, do: {:error, :comment_receipt_lost}, else: :ok
        end,
        marker_fun: fn "6911", :add, "agent:parked" -> :ok end,
        release_fun: fn "9000" ->
          assert Agent.get(remote, &MapSet.size(&1.open_prs)) == 0
          Agent.update(remote, &%{&1 | released: true})
          :ok
        end
      )

    pr = %{ctx.pr | branch_exists?: false}
    state = apply_request(%State{max_concurrent_agents: 1}, %{ctx | pr: pr}, opts)
    assert state.last_polled_issues["6911"].parked
    assert {:skip, :already_running} = DispatchPolicy.dispatch_decision(ctx.issue, state)
    assert Agent.get(remote, & &1.creates) == 1
    refute Agent.get(remote, & &1.released)
    {:ok, queued} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{state: :queued, route: :replacement}] = queued.overrides
    assert Enum.any?(Commands.list_decisions(ctx.store), &(&1.question == "Recover override for #6911?" and &1.decision_status == :open))
    # Read back the parked ticket after the unknown write outcome, then retry.
    retry_ctx = %{ctx | pr: %{pr | state: :closed}, issue: state.last_polled_issues["6911"]}
    state = apply_request(state, retry_ctx, opts)
    assert Agent.get(remote, & &1.creates) == 1
    assert Agent.get(remote, & &1.released)
    {:ok, decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert [%{corrective_ticket: %{identifier: "9000"}, recovery_path: :successor, resume_reason: :branch_missing, state: :queued}] = decision.overrides
    assert Commands.override_target_ticket(decision).identifier == "9000"
    apply_request(state, ctx, opts)
    assert Agent.get(remote, & &1.creates) == 1
    refute_received {:dispatch, _}
  end

  test "successor release clears its parked marker only after setting its dispatch state", ctx do
    ticket = %{identifier: "9000", title: "Successor", url: nil}
    record = Map.put(Commands.pending_override(ctx.decision), :resume_reason, :pr_closed)

    opts = [
      label_prefix: "agent",
      tracker: ReleaseTracker,
      successor_fun: fn _, _, _, _ -> {:ok, ticket} end,
      close_fun: fn 77, "9000" -> :ok end,
      comment_fun: fn _, _ -> :ok end,
      marker_fun: fn "6911", :add, "agent:parked" -> :ok end
    ]

    assert {:ok, ^ticket} = OverrideSuccessor.reconcile(ctx.decision, record, %{ctx.pr | state: :closed}, opts)
    assert_received :successor_unparked
  end

  defp options(ctx, extra \\ []) do
    parent = self()

    Keyword.merge(
      [
        decision_store: ctx.store,
        workspace_path_fun: fn _ -> Path.join(ctx.store_opts[:state_dir], "workspace") end,
        admission_fun: fn _ -> :dispatch end,
        stop_fun: fn state, issue, _ ->
          send(parent, {:stopped, issue.id})
          %{state | running: Map.delete(state.running, issue.id)}
        end,
        dispatch_fun: fn state, issue ->
          refute Map.has_key?(state.running, issue.id)
          send(parent, {:dispatch, issue})
          {{:ok, :started}, %{state | running: Map.put(state.running, issue.id, %{identifier: issue.identifier, issue: issue, control: %{status: :working}})}}
        end
      ],
      extra
    )
  end

  defp apply_request(state, ctx, opts), do: OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [ctx.issue]}, {:ok, ctx.pr}}], opts)
  defp payload(key, text), do: %{expected_version: 1, idempotency_key: key, custom_response: text, rationale: "Changed direction"}
end
