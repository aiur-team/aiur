defmodule Aiur.AgentRunner.OverrideHandoffTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.OverrideHandoff
  alias Aiur.{Commands, DecisionStore}
  alias Aiur.Commands.CorrectiveTicket

  @before String.duplicate("a", 40)
  @worker String.duplicate("b", 40)
  @new_worker String.duplicate("d", 40)
  @base_merge String.duplicate("c", 40)
  @pr %{number: 77, merged?: false, head_sha: @before, head_ref: "work"}

  setup do
    dir = Aiur.TestSupport.tmp_root!("worker-override-handoff")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    pr = start_supervised!({Agent, fn -> @pr end})
    owner = self()

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      override_pr_reader: fn _ -> {:ok, Agent.get(pr, & &1)} end,
      override_context_reader: fn _ -> %{pr: Agent.get(pr, & &1)} end,
      corrective_override_reconciler: fn decision, record ->
        cond do
          is_map(record.corrective_ticket) ->
            {:ok, []}

          record.route == :corrective_ticket ->
            {:ok, [{:override_corrective_ticket, %{action_id: record.action_id, ticket: %{identifier: "9000", title: "Correction", url: nil}, pr_number: 77, merge_commit_sha: "merged"}}]}

          true ->
            CorrectiveTicket.reconcile(decision, record,
              pull_request: fn _ -> {:ok, Agent.get(pr, & &1)} end,
              merge_head: fn snapshot ->
                send(owner, {:ancestry, snapshot.worker_head_sha})
                {:ok, Map.put(snapshot, :head_contains_worker_push, true)}
              end
            )
        end
      end
    ]

    store = start_supervised!({DecisionStore, opts})
    {:ok, %{decision: decision}} = Commands.request(%{source_id: "worker-handoff", question: "Proceed?", blocking: false}, [ticket: %{identifier: "50"}], store)
    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, _} = Commands.answer(decision.decision_id, payload("original"), actor, store)
    {:ok, %{decision: override}} = Commands.override(decision.decision_id, payload("override"), actor ++ [override_context: %{pr: @pr, worker: :active, capacity: :available}], store)
    assert {:ok, _} = Commands.record_command_fact(decision.decision_id, :override_prompt_delivered, %{action_id: override.active_action_id, at: DateTime.utc_now()}, server: store)
    {:ok, delivered} = DecisionStore.get(decision.decision_id, store)
    %{store: store, opts: opts, pr: pr, id: decision.decision_id, action: override.active_action_id, delivered: hd(delivered.overrides).delivered_at, actor: actor}
  end

  test "a real update-branch push signal without worker attestation routes corrective", ctx do
    observe_push(ctx, @base_merge, DateTime.add(ctx.delivered, 1))
    await(ctx, &match?(%{worker_reported: false, head_sha: @base_merge}, &1.evidence))
    merge(ctx, @base_merge)
    await(ctx, &is_map(&1.corrective_ticket))
    assert {:ok, %{overrides: [%{route: :corrective_ticket, implemented_at: nil, corrective_ticket: %{identifier: "9000"}}]}} = DecisionStore.get(ctx.id, ctx.store)
    refute_received {:ancestry, _}
  end

  test "worker checkout attestation survives a later base push and replay before merge", ctx do
    assert :ok = handoff(ctx, @worker, @worker, DateTime.add(ctx.delivered, 1))
    assert {:ok, %{overrides: [%{evidence: %{head_sha: @worker, worker_reported: true}}]}} = DecisionStore.get(ctx.id, ctx.store)
    observe_push(ctx, @base_merge, DateTime.add(ctx.delivered, 2))
    Aiur.DispatcherTestSupport.wait_until(fn -> :sys.get_state(ctx.store).override_pending_pushes == %{} end)
    assert {:ok, %{overrides: [%{evidence: %{head_sha: @worker, worker_reported: true}}]}} = DecisionStore.get(ctx.id, ctx.store)
    stop_supervised!(DecisionStore)
    store = start_supervised!({DecisionStore, ctx.opts})
    ctx = %{ctx | store: store}
    merge(ctx, @base_merge)
    await(ctx, &(&1.state == :implemented))
    assert_received {:ancestry, @worker}
    assert {:ok, %{overrides: [%{state: :implemented, corrective_ticket: nil}]}} = DecisionStore.get(ctx.id, store)
  end

  test "an unpushed or pre-delivery head supplies no attestation and does not block handoff", ctx do
    assert :ok = handoff(ctx, @worker, @before, DateTime.add(ctx.delivered, 1))
    assert :ok = handoff(ctx, @worker, @worker, DateTime.add(ctx.delivered, -1))
    assert {:ok, %{overrides: [%{state: :delivered, evidence: nil}]}} = DecisionStore.get(ctx.id, ctx.store)
  end

  test "an override delivered during the checkout probe cannot inherit an older worker receipt", ctx do
    reader = fn _, _ ->
      {:ok, %{decision: next}} = Commands.override(ctx.id, payload("new-override"), ctx.actor ++ [override_context: %{pr: @pr, worker: :active, capacity: :available}], ctx.store)
      {:ok, _} = Commands.record_command_fact(ctx.id, :override_prompt_delivered, %{action_id: next.active_action_id, at: DateTime.utc_now()}, server: ctx.store)
      {:ok, %{head_sha: @worker, upstream_sha: @worker, committed_at: DateTime.add(ctx.delivered, 1)}}
    end

    assert {:error, {:override_handoff_unconfirmed, message}} =
             OverrideHandoff.record("50", "ci-wait", %{number: 77, head_sha: @worker}, "/worker", nil, decision_store: ctx.store, override_handoff_head_reader: reader)

    assert message =~ "stale_override_handoff"
    assert {:ok, decision} = DecisionStore.get(ctx.id, ctx.store)
    assert List.last(decision.overrides).evidence == nil
  end

  test "a newer worker attestation or changed route invalidates an older checkout probe", ctx do
    for change <- [:new_worker_head, :route] do
      reader = fn _, _ ->
        case change do
          :new_worker_head ->
            assert :ok = handoff(ctx, @new_worker, @new_worker, DateTime.add(ctx.delivered, 2))

          :route ->
            assert {:ok, _} = Commands.record_command_fact(ctx.id, :override_resume_state, %{action_id: ctx.action, route: :capacity_wait, reason: :capacity, attempts: 1}, server: ctx.store)
        end

        {:ok, %{head_sha: @worker, upstream_sha: @worker, committed_at: DateTime.add(ctx.delivered, 3)}}
      end

      assert {:error, {:override_handoff_unconfirmed, message}} =
               OverrideHandoff.record("50", "ci-wait", %{number: 77, head_sha: @worker}, "/worker", nil, decision_store: ctx.store, override_handoff_head_reader: reader)

      assert message =~ "stale_override_handoff"
      assert {:ok, %{overrides: [%{evidence: %{worker_reported: true, head_sha: @new_worker}}]}} = DecisionStore.get(ctx.id, ctx.store)
    end
  end

  test "a ticket with no eligible overrides does not probe a checkout", ctx do
    assert :ok =
             OverrideHandoff.record("other", "ci-wait", %{head_sha: @worker, number: 77}, "/worker", nil,
               decision_store: ctx.store,
               override_handoff_head_reader: fn _, _ -> flunk("no checkout needed") end
             )
  end

  test "an unavailable store does not block a handoff when no override exists" do
    dir = Aiur.TestSupport.tmp_root!("unavailable-worker-handoff")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    store = start_supervised!(Supervisor.child_spec({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end}, id: :unavailable_worker_handoff_test_store))
    :sys.replace_state(store, &%{&1 | writable?: false, health: {:unavailable, :test}})
    assert :ok = OverrideHandoff.record("50", "ci-wait", %{head_sha: @worker, number: 77}, "/worker", nil, decision_store: store)
    assert %{writable?: false} = :sys.get_state(store)
  end

  test "an unavailable store still refuses a handoff when an override exists", ctx do
    :sys.replace_state(ctx.store, &%{&1 | writable?: false, health: {:unavailable, :test}})

    assert {:error, {:override_handoff_unconfirmed, message}} =
             OverrideHandoff.record("50", "ci-wait", %{head_sha: @worker, number: 77}, "/worker", nil,
               decision_store: ctx.store,
               override_handoff_head_reader: fn _, _ ->
                 {:ok, %{head_sha: @worker, upstream_sha: @worker, committed_at: DateTime.add(ctx.delivered, 1)}}
               end
             )

    assert message =~ "store_read_only"
    assert %{writable?: false, health: {:unavailable, :test}} = :sys.get_state(ctx.store)
  end

  test "missing PR or workspace evidence skips store and checkout probing" do
    opts = [decision_store: :no_store_for_handoff_test, override_handoff_head_reader: fn _, _ -> flunk("missing evidence cannot probe") end]
    assert :ok = OverrideHandoff.record("50", "ci-wait", nil, "/worker", nil, opts)
    assert :ok = OverrideHandoff.record("50", "human-review", %{head_sha: @worker, number: 77}, nil, nil, opts)
  end

  defp handoff(ctx, head, upstream, at),
    do:
      OverrideHandoff.record("50", "ci-wait", %{number: 77, head_sha: head}, "/worker", nil,
        decision_store: ctx.store,
        override_handoff_head_reader: fn _, _ -> {:ok, %{head_sha: head, upstream_sha: upstream, committed_at: at}} end
      )

  defp observe_push(ctx, head, at) do
    Agent.update(ctx.pr, &Map.merge(&1, %{head_sha: head, head_updated_at: at}))
    send(ctx.store, {:event, %{topic: "ticket.50.branch.push", source: :system, sha: head, ref: "refs/heads/work"}})
  end

  defp merge(ctx, head) do
    Agent.update(ctx.pr, &Map.merge(&1, %{head_sha: head, merged?: true, merge_commit_sha: "merged"}))
    send(ctx.store, {:override_ticket_merged, "50"})
  end

  defp await(ctx, predicate),
    do:
      Aiur.DispatcherTestSupport.wait_until(fn ->
        {:ok, decision} = DecisionStore.get(ctx.id, ctx.store)
        predicate.(hd(decision.overrides))
      end)

  defp payload(key), do: %{expected_version: 1, custom_response: key, rationale: "Correction", idempotency_key: key}
end
