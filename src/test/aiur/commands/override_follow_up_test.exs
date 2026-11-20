defmodule Aiur.Commands.OverrideFollowUpTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.{Commands, DecisionPubSub, DecisionStore, Issue}
  alias Aiur.Commands.OverridePrompt
  alias Aiur.Orchestrator.{OverrideResume, State}

  setup do
    dir = Aiur.TestSupport.tmp_root!("override-follow-up")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    parent = self()
    :ok = DecisionPubSub.subscribe()

    dispatcher = fn decision, _ -> dispatch(decision, parent) end

    store =
      start_supervised!(
        {DecisionStore,
         name: nil,
         state_dir: dir,
         filesystem_sync_fun: fn -> :ok end,
         dispatch_delay_ms: 0,
         reconcile_delay_ms: 60_000,
         dispatcher: dispatcher,
         answer_comment_publisher: fn _ -> :ok end,
         corrective_override_reconciler: fn _, _ -> {:ok, []} end,
         revision_follow_up_projector: fn _, action ->
           send(parent, {:follow_up, action})
           :ok
         end,
         revision_follow_up_resolver: fn _, _ -> :ok end}
      )

    %{store: store}
  end

  test "observational unknown-PR overrides preserve terminal follow-up at either capacity", ctx do
    for capacity <- [:available, :full] do
      revised = override!(ctx.store, "observational", %{pr: :unknown, worker: :unknown, capacity: capacity})
      action = revised.active_action_id
      receive_barrier({:follow_up, ^action})
      assert {:ok, terminal} = DecisionStore.get(revised.decision_id, ctx.store)
      assert terminal.revision_result == :no_longer_applicable
      assert terminal.revision_follow_ups[action].handled_at == nil
      assert [%{state: :queued, pr_merged: :unknown}] = terminal.overrides
      assert_no_resume(terminal, ctx.store)
    end
  end

  test "a terminal result arriving after resume routing cannot resume or inject the override", ctx do
    revised = override!(ctx.store, "race", %{pr: %{merged?: false}, worker: :active, capacity: :available})
    action = revised.active_action_id
    receive_barrier({:dispatch_inflight, worker, ^action})
    on_exit(fn -> if Process.alive?(worker), do: send(worker, :release) end)

    assert {:ok, %{decision: routed}} =
             Commands.record_command_fact(revised.decision_id, :override_resume_state, %{action_id: action, route: :resume_pending, reason: :eligible}, server: ctx.store)

    # Positive witness: this really was a live resume request before the late result.
    assert [waiting] = OverrideResume.waiting([routed])
    assert waiting.active_action_id == action
    assert [pending] = OverridePrompt.prepare("race", decision_store: ctx.store)[:pending_overrides]
    assert pending.active_action_id == action
    send(worker, :release)
    receive_barrier({:follow_up, ^action})
    assert {:ok, terminal} = DecisionStore.get(revised.decision_id, ctx.store)
    assert terminal.revision_result == :no_longer_applicable
    assert terminal.revision_follow_ups[action].handled_at == nil
    assert_no_resume(terminal, ctx.store)
  end

  test "a merged override waits for corrective work instead of resuming its old worker", ctx do
    revised = override!(ctx.store, "unavailable", %{pr: %{merged?: true}, worker: :active, capacity: :full})

    assert {:ok, observational} = DecisionStore.get(revised.decision_id, ctx.store)
    assert [%{route: :corrective_ticket, pr_merged: true}] = observational.overrides
    refute Commands.override_dispatchable?(observational)
    assert_no_resume(observational, ctx.store)
  end

  defp dispatch(%{revision_sequence: 0}, _parent), do: {:ok, %{status: :accepted, item: %{id: 504}}}

  defp dispatch(decision, parent) do
    if decision.ticket.identifier == "race" do
      send(parent, {:dispatch_inflight, self(), decision.active_action_id})
      receive do: (:release -> :ok)
    end

    if decision.ticket.identifier == "unavailable",
      do: {:error, :no_running_agent},
      else: {:no_longer_applicable, :missing}
  end

  defp assert_no_resume(decision, store) do
    assert OverrideResume.waiting([decision]) == []
    assert OverridePrompt.prepare(decision.ticket.identifier, decision_store: store)[:pending_overrides] == []
    issue = %Issue{id: decision.ticket.identifier, identifier: decision.ticket.identifier, state: "in-progress", labels: ["agent:in-progress"]}
    entry = %{issue: issue, identifier: issue.identifier, control: %{status: :paused}, paused_reason: :input_required}
    state = %State{max_concurrent_agents: 1, running: %{issue.id => entry}}

    next =
      OverrideResume.apply_loaded(state, [{decision, {:ok, [issue]}, {:ok, %{merged?: false}}}],
        decision_store: store,
        admission_fun: fn _ -> :dispatch end,
        resume_fun: fn _, _, _ -> flunk("terminal/observational override resumed a worker") end
      )

    assert next.running == state.running
  end

  defp override!(store, identifier, context) do
    {:ok, %{decision: decision}} =
      Commands.request(
        %{source_id: "follow-up-#{System.unique_integer([:positive])}", question: "Proceed?", blocking: false},
        [ticket: %{identifier: identifier}, source: %{agent_id: "worker", session_id: "session"}],
        store
      )

    actor = [actor: %{kind: :operator, id: "human"}, actor_source: :dashboard_session]
    {:ok, %{decision: answered}} = Commands.answer(decision.decision_id, payload("answer"), actor, store)
    {:ok, %{decision: revised}} = Commands.override(answered.decision_id, payload("override"), Keyword.put(actor, :override_context, context), store)
    revised
  end

  defp payload(key), do: %{expected_version: 1, idempotency_key: key, custom_response: "Revised direction", rationale: "Target observation changed"}
end
