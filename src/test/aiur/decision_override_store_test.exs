defmodule Aiur.DecisionOverrideStoreTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.{DecisionPubSub, DecisionRevisionDispatch, DecisionStore, Issue}
  alias Aiur.DecisionStore.Dispatch
  alias Aiur.DecisionStore.Retry
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.Dispatcher.AnsweredDecisions

  @ticket %{identifier: "6908", title: "Override", url: nil}
  @source %{agent_id: "worker", session_id: "session"}
  @context %{pr: %{number: 77, merged?: false, head_sha: "before", head_ref: "work"}, worker: :active, capacity: :full}

  setup do
    dir = Aiur.TestSupport.tmp_root!("overrides-6908")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    :ok = DecisionPubSub.subscribe()
    parent = self()

    dispatcher = fn decision, opts ->
      DecisionRevisionDispatch.dispatch(
        decision,
        opts ++
          [
            issue_fetcher: fn _ -> {:ok, []} end,
            terminal_states: MapSet.new(),
            revalidate_fun: fn %Issue{} = issue, _, _ -> {:ok, %{issue | state: "in-progress"}} end,
            send_fun: fn _, ticket, payload ->
              item = Map.merge(payload, %{id: decision.revision_sequence, target_issue_identifier: ticket})
              send(parent, {:worker_message, item})
              {:ok, %{status: :accepted, item: item}}
            end
          ]
      )
    end

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      dispatcher: dispatcher,
      answer_comment_publisher: fn _ -> :ok end,
      override_context_reader: fn _ -> %{@context | pr: Map.merge(@context.pr, %{head_sha: "after", head_updated_at: DateTime.add(DateTime.utc_now(), 1)})} end
    ]

    store = start_supervised!({DecisionStore, opts})
    {:ok, %{decision: decision}} = DecisionStore.request(%{source_id: "override", question: "Proceed?", blocking: false}, [ticket: @ticket, source: @source], store)
    {:ok, %{decision: answered}} = DecisionStore.answer(decision.decision_id, payload("answer"), [actor: %{kind: :operator, id: "human"}], store)

    item = %{
      id: 1,
      target_issue_identifier: "6908",
      action_id: answered.active_action_id,
      correlation: %{decision_id: answered.decision_id, decision_version: 1, action_id: answered.active_action_id, attempt_id: "original"}
    }

    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)
    %{store: store, decision: answered, dir: dir, store_opts: opts}
  end

  test "delivered override reaches existing worker and acknowledgement implements durable record", ctx do
    override = override!(ctx, "first")
    assert [%{state: :queued, prior_action_id: prior, pr_number: 77, route: :active_worker}] = override.overrides
    assert prior == ctx.decision.active_action_id
    item = dispatch!(ctx, override)
    assert item.body =~ "Replacement response: first"
    assert item.body =~ "Prior action: #{prior}"
    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, ctx.store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, ctx.store)
    assert {:ok, %{overrides: [%{state: :delivered, delivered_at: %DateTime{}}]}} = DecisionStore.get(override.decision_id, ctx.store)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.agent_lifecycle(
               :acknowledged,
               %{decision_id: override.decision_id, action_id: override.active_action_id, expected_version: 1},
               [ticket_identifier: "6908", actor: %{kind: :agent, id: "worker"}, source: @source],
               ctx.store
             )

    assert {:ok, %{overrides: [%{state: :implemented, evidence: :acknowledged}]}} = DecisionStore.get(override.decision_id, ctx.store)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.enrich(override.decision_id, %{context: %{short_summary: "Revised work"}}, [expected_version: 1, actor: %{kind: :supervisor, id: "supervising-agent"}], ctx.store)

    stop_supervised!(DecisionStore)
    replayed_store = start_supervised!({DecisionStore, ctx.store_opts})
    assert {:ok, replayed} = DecisionStore.get(override.decision_id, replayed_store)
    assert [%{state: :implemented, evidence: :acknowledged, decision_id: id, ticket: @ticket}] = replayed.overrides
    assert id == override.decision_id
  end

  test "two overrides supersede the first and stale queued work cannot reach the worker", ctx do
    first = override!(ctx, "first")
    second = override!(ctx, "second")
    assert [%{state: :superseded}, %{state: :queued, prior_action_id: prior}] = second.overrides
    assert prior == first.active_action_id

    stale = %{
      id: 2,
      target_issue_identifier: "6908",
      action_id: first.active_action_id,
      correlation: %{decision_id: first.decision_id, decision_version: 1, action_id: first.active_action_id, attempt_id: "stale"}
    }

    assert {:error, {:answer_withdrawn, :superseded}} = DecisionStore.validate_delivery(stale, ctx.store)
    item = dispatch!(ctx, second)
    assert item.action_id == second.active_action_id
    assert item.body =~ "Replacement response: second"
    refute_receive {:worker_message, _item}, 0
  end

  test "observational routes retain legacy retry, startup prompt and delivery", ctx do
    context = %{@context | pr: %{@context.pr | merged?: true}, worker: :active}
    override = override!(ctx, "merged", context)
    assert [%{route: :corrective_ticket, state: :queued}] = override.overrides
    assert Aiur.Commands.override_dispatchable?(override)
    assert Retry.dispatchable?(override, true)
    assert [%{action_id: action_id, answer: "merged"}] = AnsweredDecisions.for_ticket("6908", ctx.store, 1_000)
    assert action_id == override.active_action_id
    item = dispatch!(ctx, override)
    assert item.action_id == override.active_action_id
    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, ctx.store)
  end

  test "verified branch push after delivery implements the override on its ticket PR", ctx do
    override = override!(ctx, "pushed")
    item = dispatch!(ctx, override)
    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, ctx.store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, ctx.store)
    assert {:ok, delivered} = DecisionStore.get(override.decision_id, ctx.store)
    [%{delivered_at: at}] = delivered.overrides
    event = %{topic: "ticket.6908.branch.push", source: :system, sha: "after", ref: "refs/heads/work", ticket_observation: %{observed_at: DateTime.add(at, 1, :second)}}
    Exchange.publish(event.topic, event)
    implemented = wait_for(ctx.store, override.decision_id, fn d -> hd(d.overrides).state == :implemented end)
    assert [%{evidence: %{kind: :push, head_sha: "after", pr_number: 77}}] = implemented.overrides
    assert implemented.decision_status == :decided
  end

  defp override!(ctx, token, context \\ @context) do
    assert {:ok, %{status: :accepted, decision: decision}} =
             DecisionStore.override(ctx.decision.decision_id, payload(token), [actor: %{kind: :operator, id: "human"}, override_context: context], ctx.store)

    decision
  end

  defp payload(token), do: %{expected_version: 1, custom_response: token, rationale: "Changed direction", idempotency_key: token}

  defp dispatch!(ctx, decision) do
    send(ctx.store, {:dispatch_action, Dispatch.dispatch_fence(decision), false})
    assert_receive {:worker_message, item}, 2_000
    wait_for(ctx.store, decision.decision_id, &(&1.delivery_status == :queued))
    item
  end

  defp wait_for(store, id, predicate) do
    {:ok, decision} = DecisionStore.get(id, store)

    if predicate.(decision),
      do: decision,
      else:
        (
          receive_barrier({:decision_changed, ^id, _version})
          wait_for(store, id, predicate)
        )
  end
end
