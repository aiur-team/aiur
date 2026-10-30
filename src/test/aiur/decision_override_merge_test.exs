defmodule Aiur.DecisionOverrideMergeTest do
  use Aiur.TestSupport
  alias Aiur.AgentRunner.OverrideHandoff
  alias Aiur.{Commands, DecisionStore}
  alias Aiur.Commands.{CorrectiveTicket, OverridePrompt}
  alias Aiur.DecisionStore.Retry

  @pr %{number: 77, merged?: false, head_sha: "before", head_ref: "work"}

  setup do
    dir = Aiur.TestSupport.tmp_root!("override-merge")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    observations = start_supervised!({Agent, fn -> @pr end})
    owner = self()

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      override_pr_reader: fn _ -> {:ok, Agent.get(observations, & &1)} end,
      override_context_reader: fn _ -> %{pr: Agent.get(observations, & &1)} end,
      override_merge_reader: fn pr -> {:ok, pr} end,
      corrective_override_reconciler: fn decision, record ->
        cond do
          is_map(record.corrective_ticket) ->
            {:ok, []}

          record.route == :corrective_ticket ->
            send(owner, {:corrective_requested, record.action_id})
            {:ok, [{:override_corrective_ticket, %{action_id: record.action_id, ticket: %{identifier: "9000", title: "Correction", url: nil}, pr_number: 77, merge_commit_sha: "merged"}}]}

          true ->
            CorrectiveTicket.reconcile(decision, record,
              pull_request: fn _ -> {:ok, Agent.get(observations, & &1)} end,
              merge_head: fn pr -> {:ok, Map.put(pr, :head_contains_worker_push, pr.worker_head_sha == pr.head_sha)} end
            )
        end
      end
    ]

    store = start_supervised!({DecisionStore, opts})
    {:ok, %{decision: requested}} = Commands.request(%{source_id: "merge-race", question: "Proceed?", blocking: false}, [ticket: %{identifier: "6912"}], store)
    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, %{decision: answered}} = Commands.answer(requested.decision_id, payload("initial"), actor, store)
    {:ok, %{decision: override}} = Commands.override(answered.decision_id, payload("override"), actor ++ [override_context: %{pr: @pr, worker: :active, capacity: :full}], store)
    %{store: store, opts: opts, observations: observations, override: override}
  end

  test "merge after routing prevents stale handoff and creates a traceable corrective ticket", ctx do
    Agent.update(ctx.observations, &%{&1 | merged?: true})
    assert {:error, {:answer_withdrawn, :pr_merged}} = DecisionStore.validate_delivery(item(ctx.override), ctx.store)
    action = ctx.override.active_action_id
    wait_for(ctx, fn record -> is_map(record.corrective_ticket) end)
    assert_received {:corrective_requested, ^action}
    {:ok, decision} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    assert [%{state: :queued, corrective_ticket: %{identifier: "9000"}, merge_reason: "PR merged before the change; corrective ticket #9000"}] = decision.overrides
    assert Commands.override_target_ticket(decision).identifier == "9000"
    assert {:error, {:invalid_transition, :stale}} = Commands.record_command_fact(decision.decision_id, :override_prompt_delivered, %{action_id: action, at: DateTime.utc_now()}, server: ctx.store)
    assert {:ok, %{overrides: [%{state: :queued, delivered_at: nil}]}} = DecisionStore.get(decision.decision_id, ctx.store)
  end

  test "merge before dispatch never queues an interrupt for the old worker", ctx do
    Agent.update(ctx.observations, &%{&1 | merged?: true})

    assert {:error, {:override_delivery_deferred, :pr_merged}} =
             Aiur.DecisionRevisionDispatch.dispatch(ctx.override,
               store: ctx.store,
               attempt_id: "routing-race",
               terminal_states: MapSet.new(),
               issue_fetcher: fn _ -> {:ok, []} end,
               revalidate_fun: fn issue, _, _ -> {:ok, issue} end,
               send_fun: fn _, _, _ -> flunk("merged work must not interrupt the worker") end
             )

    action = ctx.override.active_action_id
    assert_receive {:corrective_requested, ^action}, 2_000
  end

  test "resumed prompt excludes work when its PR merged after routing", ctx do
    # Route this pending action through the real resume projection.
    assert {:ok, _} =
             Commands.record_command_fact(ctx.override.decision_id, :override_resume_state, %{action_id: ctx.override.active_action_id, route: :resume_pending, reason: :eligible, attempts: 0},
               server: ctx.store
             )

    Agent.update(ctx.observations, &%{&1 | merged?: true})
    assert OverridePrompt.prepare("6912", decision_store: ctx.store)[:pending_overrides] == []
    action = ctx.override.active_action_id
    assert_receive {:corrective_requested, ^action}, 2_000
  end

  test "acknowledged and resolved old work can still be delivered to the corrective worker", ctx do
    deliver(ctx)

    for type <- [:acknowledged, :resolved] do
      assert {:ok, _} =
               Commands.agent_lifecycle(
                 type,
                 %{decision_id: ctx.override.decision_id, action_id: ctx.override.active_action_id, expected_version: 1},
                 [ticket_identifier: "6912", actor: %{kind: :agent, id: "worker"}],
                 ctx.store
               )
    end

    merge(ctx, "before", DateTime.add(DateTime.utc_now(), -60))
    action = ctx.override.active_action_id
    assert_receive {:corrective_requested, ^action}, 2_000
    wait_for(ctx, &is_map(&1.corrective_ticket))
    {:ok, decision} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    assert decision.decision_status == :decided
    assert decision.acknowledgement == nil
    assert decision.resolution == nil
    assert Retry.dispatchable?(decision, false)
  end

  test "merge notification after delivery without a later commit routes once, including after replay", ctx do
    deliver(ctx)
    merge(ctx, "before", DateTime.add(DateTime.utc_now(), -60))
    action = ctx.override.active_action_id
    assert_receive {:corrective_requested, ^action}, 2_000
    wait_for(ctx, fn record -> is_map(record.corrective_ticket) end)
    stop_supervised!(DecisionStore)
    store = start_supervised!({DecisionStore, ctx.opts})
    assert {:ok, %{overrides: [%{route: :corrective_ticket, corrective_ticket: %{identifier: "9000"}, merge_version: 2}]}} = DecisionStore.get(ctx.override.decision_id, store)
  end

  test "update-branch after delivery without a worker push creates one corrective ticket", ctx do
    deliver(ctx)
    {:ok, delivered} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    [record] = delivered.overrides
    merge(ctx, "merge-main-into-branch", DateTime.add(record.delivered_at, 60))
    action = ctx.override.active_action_id
    assert_receive {:corrective_requested, ^action}, 2_000
    wait_for(ctx, &is_map(&1.corrective_ticket))
    assert {:ok, %{overrides: [%{state: :queued, route: :corrective_ticket, implemented_at: nil}]}} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    send(ctx.store, {:override_ticket_merged, "6912"})
    refute_receive {:corrective_requested, _}, 20
  end

  test "recorded worker push in the merged head implements without a corrective ticket", ctx do
    deliver(ctx)
    {:ok, delivered} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    [record] = delivered.overrides
    push(ctx, "after", DateTime.add(record.delivered_at, 1))
    merge(ctx, "after", DateTime.add(record.delivered_at, 1))
    wait_for(ctx, &(&1.state == :implemented))
    {:ok, merged} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    assert [%{state: :implemented, corrective_ticket: nil, evidence: %{kind: :merge, head_sha: "after"}}] = merged.overrides
    refute_receive {:corrective_requested, _}, 20
  end

  test "corrective delivery has a separate queue identity and remains idempotent after replay", ctx do
    queue = start_supervised!({Agent, fn -> Aiur.AgentQueueStore.new() end}, id: :delivery_queue)

    send_fun = fn _server, target, payload ->
      Agent.get_and_update(queue, fn store ->
        attrs = %{
          target_issue_identifier: target,
          category: :operator_message,
          source: :executor,
          event_type: nil,
          body: %{text: payload.body},
          action_id: payload.action_id,
          correlation: payload.correlation
        }

        assert {:ok, next, item, status} = Aiur.AgentQueueStore.enqueue_correlated(store, attrs)
        {{:ok, %{item: item, status: status}}, next}
      end)
    end

    opts = [store: ctx.store, attempt_id: "original", send_fun: send_fun, terminal_states: MapSet.new(), issue_fetcher: fn _ -> {:ok, []} end, revalidate_fun: fn issue, _, _ -> {:ok, issue} end]
    assert {:ok, %{item: original}} = Aiur.DecisionRevisionDispatch.dispatch(ctx.override, opts)
    assert {:ok, :accepted} = DecisionStore.validate_delivery(original, ctx.store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(original, ctx.store)
    merge(ctx, "before", DateTime.add(DateTime.utc_now(), -60))
    wait_for(ctx, &is_map(&1.corrective_ticket))
    {:ok, linked} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    assert [%{prior_dispatch_attempts: [%{status: :delivered}]}] = linked.overrides
    assert linked.dispatch_attempts == []
    assert {:ok, %{item: corrective, status: :accepted}} = Aiur.DecisionRevisionDispatch.dispatch(linked, Keyword.put(opts, :attempt_id, "corrective"))
    assert corrective.id != original.id
    assert corrective.action_id == original.action_id
    assert corrective.target_issue_identifier == "9000"
    Agent.update(queue, fn store -> Aiur.AgentQueueStore.restore_persisted_items(Aiur.AgentQueueStore.new(), Map.values(store.items)) end)
    assert {:ok, %{item: replayed, status: :duplicate}} = Aiur.DecisionRevisionDispatch.dispatch(linked, Keyword.put(opts, :attempt_id, "corrective"))
    assert replayed.id == corrective.id
    assert {:error, :ticket_mismatch} = DecisionStore.validate_delivery(original, ctx.store)
    assert {:ok, :accepted} = DecisionStore.validate_delivery(corrective, ctx.store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(corrective, ctx.store)
  end

  test "a duplicate handoff after merge waits for commit evidence rather than creating corrective work", ctx do
    deliver(ctx)
    {:ok, delivered} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    [record] = delivered.overrides
    push(ctx, "after", DateTime.add(record.delivered_at, 1))
    Agent.update(ctx.observations, &Map.merge(&1, %{merged?: true, head_sha: "after", committed_at: DateTime.add(record.delivered_at, 1), merge_commit_sha: "merged"}))
    assert {:error, {:answer_withdrawn, :pr_merged}} = DecisionStore.validate_delivery(item(ctx.override), ctx.store)
    wait_for(ctx, &(&1.state == :implemented))
    refute_receive {:corrective_requested, _}, 20
  end

  test "two concurrent merge dispositions use the override version, with one stale loser", ctx do
    deliver(ctx)
    data = %{action_id: ctx.override.active_action_id, expected_version: 1, head_sha: "before", pr_number: 77, committed_at: nil}
    results = 1..2 |> Enum.map(fn _ -> Task.async(fn -> Commands.record_command_fact(ctx.override.decision_id, :override_merge_settled, data, server: ctx.store) end) end) |> Enum.map(&Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:invalid_transition, :stale}}, &1)) == 1

    assert {:error, {:invalid_transition, :stale}} =
             Commands.record_command_fact(ctx.override.decision_id, :override_resume_state, %{action_id: ctx.override.active_action_id, route: :resume_pending, reason: :resume_failed, attempts: 1},
               server: ctx.store
             )

    assert {:ok, %{overrides: [%{route: :corrective_ticket, merge_version: 2}]}} = DecisionStore.get(ctx.override.decision_id, ctx.store)
  end

  test "late ancestry result for an older push cannot create corrective work", ctx do
    deliver(ctx)
    {:ok, delivered} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    push(ctx, "new-push", DateTime.add(hd(delivered.overrides).delivered_at, 1))

    data = %{
      action_id: ctx.override.active_action_id,
      expected_version: 1,
      head_sha: "merged",
      pr_number: 77,
      committed_at: DateTime.add(DateTime.utc_now(), 60),
      worker_head_sha: "older-push",
      head_contains_worker_push: true
    }

    assert {:error, {:invalid_transition, :stale}} = Commands.record_command_fact(ctx.override.decision_id, :override_merge_settled, data, server: ctx.store)
    assert {:ok, %{overrides: [%{state: :delivered, route: :active_worker, corrective_ticket: nil}]}} = DecisionStore.get(ctx.override.decision_id, ctx.store)
    refute_receive {:corrective_requested, _}, 20
  end

  defp merge(ctx, head, at) do
    Agent.update(ctx.observations, &Map.merge(&1, %{merged?: true, head_sha: head, committed_at: at, merge_commit_sha: "merged"}))
    send(ctx.store, {:override_ticket_merged, "6912"})
  end

  defp push(ctx, head, at) do
    Agent.update(ctx.observations, &Map.merge(&1, %{head_sha: head, head_updated_at: at}))
    send(ctx.store, {:event, %{topic: "ticket.6912.branch.push", source: :system, payload: %{sha: head, ref: "refs/heads/work"}}})
    wait_for(ctx, &match?(%{kind: :push, head_sha: ^head}, &1.evidence))

    assert :ok =
             OverrideHandoff.record("6912", "ci-wait", %{head_sha: head, number: 77}, "/worker", nil,
               decision_store: ctx.store,
               override_handoff_head_reader: fn _, _ -> {:ok, %{head_sha: head, upstream_sha: head, committed_at: at}} end
             )
  end

  defp deliver(ctx) do
    assert {:ok, :accepted} = DecisionStore.validate_delivery(item(ctx.override), ctx.store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(item(ctx.override), ctx.store)
  end

  defp item(decision),
    do: %{
      id: 2,
      target_issue_identifier: "6912",
      action_id: decision.active_action_id,
      correlation: %{decision_id: decision.decision_id, decision_version: 1, action_id: decision.active_action_id, attempt_id: "merge-attempt"}
    }

  defp payload(key), do: %{expected_version: 1, custom_response: key, rationale: "Change", idempotency_key: key}

  defp wait_for(ctx, predicate),
    do:
      Aiur.DispatcherTestSupport.wait_until(fn ->
        {:ok, decision} = DecisionStore.get(ctx.override.decision_id, ctx.store)
        predicate.(hd(decision.overrides))
      end)
end
