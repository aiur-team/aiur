defmodule Aiur.DecisionCorrectiveRoutingTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Commands.{CorrectiveProvenance, CorrectiveTicketBody, Overrides}
  alias Aiur.{DecisionPubSub, DecisionRevisionDispatch, DecisionStore, Issue}
  alias Aiur.DecisionStore.{Dispatch, Retry}
  alias Aiur.Orchestrator.Dispatcher.AnsweredDecisions

  @ticket %{identifier: "6910", title: "Original work", url: nil}
  @corrective %{identifier: "7100", title: "Override for #6910: Direction", url: "https://example.test/issues/7100"}
  @source %{agent_id: "worker", session_id: "session"}
  @merged %{pr: %{number: 77, merged?: true, head_sha: "old-head", head_ref: "original"}, worker: :active, capacity: :available}
  @open %{pr: %{number: 88, merged?: false, head_sha: "corrective-head", head_ref: "correction"}, worker: :active, capacity: :available}

  defmodule ContextTarget do
    def override_context(identifier) do
      send(self(), {:observed_override_target, identifier})
      %{pr: %{number: 88, merged?: false, head_sha: "corrective-head", head_ref: "correction"}, worker: :active, capacity: :available}
    end
  end

  defmodule ChangingContextTarget do
    def override_context(identifier), do: Process.get(:corrective_context_reader).(identifier)
  end

  setup do
    dir = Aiur.TestSupport.tmp_root!("corrective-routing")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    :ok = DecisionPubSub.subscribe()
    owner = self()

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      corrective_override_reconciler: fn _, _ -> {:ok, []} end,
      override_context_reader: fn _ -> @open end,
      dispatcher: fn decision, dispatch_opts ->
        DecisionRevisionDispatch.dispatch(decision,
          issue_fetcher: fn _ -> {:ok, []} end,
          terminal_states: MapSet.new(),
          revalidate_fun: fn %Issue{} = issue, _, _ -> {:ok, %{issue | state: "in-progress"}} end,
          attempt_id: Keyword.fetch!(dispatch_opts, :attempt_id),
          send_fun: fn _, identifier, payload ->
            item = Map.merge(payload, %{id: decision.revision_sequence + 1, target_issue_identifier: identifier})
            send(owner, {:corrective_worker_message, item})
            {:ok, %{status: :accepted, item: item}}
          end
        )
      end
    ]

    store = start_supervised!({DecisionStore, opts})
    {:ok, %{decision: decision}} = DecisionStore.request(%{source_id: "corrective", question: "Which direction?", blocking: false}, [ticket: @ticket, source: @source], store)
    {:ok, %{decision: answered}} = DecisionStore.answer(decision.decision_id, payload("original"), [actor: %{kind: :operator, id: "human"}], store)
    original = item(answered, "original-attempt", "6910")
    assert {:ok, :accepted} = DecisionStore.validate_delivery(original, store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(original, store)
    %{store: store, id: decision.decision_id, opts: opts}
  end

  test "an unlinked post-merge override cannot reach the original worker", ctx do
    decision = override!(ctx, "new direction", @merged)
    assert [%{route: :corrective_ticket, corrective_ticket: nil, state: :queued}] = decision.overrides
    refute Retry.dispatchable?(decision, false)
    refute Aiur.Commands.override_dispatchable?(decision)

    assert {:error, {:answer_withdrawn, :override_queued}} =
             DecisionStore.validate_delivery(item(decision, "unsafe-attempt", "6910"), ctx.store)
  end

  test "a corrective link survives journal replay and a later override reaches that ticket", ctx do
    first = override!(ctx, "first direction", @merged)
    issue = %Issue{id: "7100", identifier: "7100", url: @corrective.url, description: CorrectiveTicketBody.marker(first.active_action_id), creator_login: "daemon"}
    refute CorrectiveProvenance.check(issue, ctx.store)
    linked = link!(ctx, first)
    assert CorrectiveProvenance.check(issue, ctx.store)
    assert Overrides.target_ticket(linked) == @corrective
    stop_supervised!(DecisionStore)
    store = start_supervised!({DecisionStore, ctx.opts})
    ctx = %{ctx | store: store}
    assert {:ok, replayed} = DecisionStore.get(ctx.id, store)
    assert [%{corrective_ticket: @corrective, state: :queued}] = replayed.overrides
    assert CorrectiveProvenance.check(issue, store)

    previous_target = Application.fetch_env(:aiur, :commands_delivery_target)
    Application.put_env(:aiur, :commands_delivery_target, ContextTarget)
    on_exit(fn -> restore_target(previous_target) end)
    assert {:ok, %{decision: latest}} = DecisionStore.override(ctx.id, payload("second direction"), [actor: %{kind: :operator, id: "human"}], store)
    assert_receive {:observed_override_target, "7100"}, 1_000
    assert [%{state: :superseded}, %{corrective_ticket: @corrective, route: :active_worker, ticket: @corrective}] = latest.overrides
    assert latest.ticket == @ticket
    assert [%{action_id: action, answer: "second direction"}] = AnsweredDecisions.for_ticket("7100", store, 1_000)
    assert action == latest.active_action_id
    assert [] == AnsweredDecisions.for_ticket("6910", store, 1_000)
    assert Retry.dispatchable?(latest, false)
    send(store, {:dispatch_action, Dispatch.dispatch_fence(latest), false})
    assert_receive {:corrective_worker_message, delivered}, 2_000
    assert delivered.target_issue_identifier == "7100"
    assert delivered.action_id == latest.active_action_id
    assert delivered.body =~ "Replacement response: second direction"
    wait_for(store, ctx.id, &(&1.delivery_status == :queued))
    assert {:ok, :accepted} = DecisionStore.validate_delivery(delivered, store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(delivered, store)
    assert {:error, :ticket_mismatch} = DecisionStore.validate_delivery(%{delivered | target_issue_identifier: "6910"}, store)
  end

  test "acknowledgement and push leave a corrective override pending until its PR merges", ctx do
    first = override!(ctx, "first direction", @merged)
    link!(ctx, first)
    decision = override!(ctx, "second direction", @open)
    send(ctx.store, {:dispatch_action, Dispatch.dispatch_fence(decision), false})
    assert_receive {:corrective_worker_message, delivered}, 2_000
    wait_for(ctx.store, ctx.id, &(&1.delivery_status == :queued))
    assert {:ok, :accepted} = DecisionStore.validate_delivery(delivered, ctx.store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(delivered, ctx.store)
    lifecycle = %{decision_id: ctx.id, action_id: decision.active_action_id, expected_version: 1}

    assert {:ok, %{status: :accepted}} =
             DecisionStore.agent_lifecycle(:acknowledged, lifecycle, [ticket_identifier: "7100", actor: %{kind: :agent, id: "worker"}, source: @source], ctx.store)

    assert {:ok, acknowledged} = DecisionStore.get(ctx.id, ctx.store)
    assert List.last(acknowledged.overrides).state == :delivered
    at = DateTime.add(List.last(acknowledged.overrides).delivered_at, 1)
    push = %{action_id: decision.active_action_id, head_sha: "new-corrective-head", pr_number: 88, at: at}
    assert {:error, {:invalid_transition, :override_push_mismatch}} = DecisionStore.record_command_fact(ctx.id, :override_implemented, push, server: ctx.store)

    merged = %{action_id: decision.active_action_id, pr_number: 88, merge_commit_sha: "corrective-merge"}
    assert {:ok, %{decision: implemented}} = DecisionStore.record_command_fact(ctx.id, :override_corrective_implemented, merged, server: ctx.store)
    assert %{state: :implemented, evidence: %{kind: :merge, pr_number: 88, merge_commit_sha: "corrective-merge"}} = List.last(implemented.overrides)
    stop_supervised!(DecisionStore)
    store = start_supervised!({DecisionStore, ctx.opts})
    assert {:ok, replayed} = DecisionStore.get(ctx.id, store)
    assert %{state: :implemented, evidence: %{merge_commit_sha: "corrective-merge"}} = List.last(replayed.overrides)
  end

  test "a link arriving during context lookup refreshes the target before accepting the override", ctx do
    first = override!(ctx, "first direction", @merged)
    previous_target = Application.fetch_env(:aiur, :commands_delivery_target)
    Application.put_env(:aiur, :commands_delivery_target, ChangingContextTarget)
    on_exit(fn -> restore_target(previous_target) end)

    Process.put(:corrective_context_reader, fn
      "6910" ->
        send(self(), {:context_read, "6910"})
        link!(ctx, first)
        @merged

      "7100" ->
        send(self(), {:context_read, "7100"})
        @open
    end)

    assert {:ok, %{decision: latest}} = DecisionStore.override(ctx.id, payload("racing direction"), [actor: %{kind: :operator, id: "human"}], ctx.store)
    assert_receive {:context_read, "6910"}, 1_000
    assert_receive {:context_read, "7100"}, 1_000
    assert latest.revision_sequence == first.revision_sequence + 1
    assert %{route: :active_worker, corrective_ticket: @corrective, ticket: @corrective} = List.last(latest.overrides)
    assert Overrides.target_ticket(latest) == @corrective
  end

  test "a serialized override with stale target binding cannot append a revision", ctx do
    first = override!(ctx, "first direction", @merged)
    link!(ctx, first)
    opts = [actor: %{kind: :operator, id: "human"}, override_context: @merged, override_target_identifier: "6910"]
    assert {:error, {:conflict, :override_target_changed}} = GenServer.call(ctx.store, {:override, ctx.id, payload("stale target"), opts})
    assert {:ok, current} = DecisionStore.get(ctx.id, ctx.store)
    assert current.active_action_id == first.active_action_id
    assert current.revision_sequence == first.revision_sequence
  end

  test "unknown PR observations retain an already linked corrective work target", ctx do
    first = override!(ctx, "first direction", @merged)
    link!(ctx, first)
    latest = override!(ctx, "unknown observation", %{pr: :unknown, worker: :unknown, capacity: :unknown})
    assert %{route: :resume_pending, corrective_ticket: @corrective, ticket: @corrective} = List.last(latest.overrides)
    assert Overrides.target_ticket(latest) == @corrective
    assert Retry.dispatchable?(latest, false)
  end

  test "an override after the corrective PR merged needs a fresh ticket", ctx do
    first = override!(ctx, "first direction", @merged)
    link!(ctx, first)
    merged_correction = put_in(@open, [:pr, :merged?], true)
    latest = override!(ctx, "third direction", merged_correction)
    assert %{route: :corrective_ticket, ticket: @corrective, corrective_ticket: nil} = List.last(latest.overrides)
    refute Retry.dispatchable?(latest, false)
  end

  test "a late terminal result for the original ticket cannot strand its newly linked corrective target", ctx do
    owner = self()

    dispatcher = fn decision, _opts ->
      if Overrides.target_ticket(decision).identifier == "6910" do
        send(owner, {:old_target_dispatch, self()})

        receive do
          :release -> {:no_longer_applicable, {:terminal, "Closed"}}
        after
          5_000 -> {:error, :test_release_timeout}
        end
      else
        send(owner, {:new_target_dispatch, decision.active_action_id})
        {:error, :no_running_agent}
      end
    end

    stop_supervised!(DecisionStore)
    opts = ctx.opts |> Keyword.put(:dispatcher, dispatcher) |> Keyword.put(:dispatch_delay_ms, 0)
    store = start_supervised!({DecisionStore, opts})
    ctx = %{ctx | store: store}
    first = override!(ctx, "late terminal direction", %{pr: :unknown, worker: :active, capacity: :available})
    assert_receive {:old_target_dispatch, worker}, 2_000
    on_exit(fn -> if Process.alive?(worker), do: send(worker, :release) end)
    link!(ctx, first)
    send(worker, :release)
    action = first.active_action_id
    assert_receive {:new_target_dispatch, ^action}, 2_000
    assert {:ok, current} = DecisionStore.get(ctx.id, store)
    assert current.revision_result == :recorded
    assert Overrides.target_ticket(current) == @corrective
    refute Map.has_key?(current.revision_follow_ups, action)
  end

  defp restore_target({:ok, target}), do: Application.put_env(:aiur, :commands_delivery_target, target)
  defp restore_target(:error), do: Application.delete_env(:aiur, :commands_delivery_target)

  defp link!(ctx, decision) do
    data = %{action_id: decision.active_action_id, ticket: @corrective, pr_number: 77, merge_commit_sha: "original-merge"}
    assert {:ok, %{decision: linked}} = DecisionStore.record_command_fact(ctx.id, :override_corrective_ticket, data, server: ctx.store)
    linked
  end

  defp override!(ctx, text, context) do
    assert {:ok, %{decision: decision}} = DecisionStore.override(ctx.id, payload(text), [actor: %{kind: :operator, id: "human"}, override_context: context], ctx.store)
    decision
  end

  defp payload(text), do: %{expected_version: 1, custom_response: text, rationale: "New answer", idempotency_key: text}

  defp item(decision, attempt, identifier) do
    %{
      id: 1,
      target_issue_identifier: identifier,
      action_id: decision.active_action_id,
      correlation: %{decision_id: decision.decision_id, decision_version: 1, action_id: decision.active_action_id, attempt_id: attempt}
    }
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
