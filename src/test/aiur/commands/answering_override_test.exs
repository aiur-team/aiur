defmodule Aiur.Commands.AnsweringOverrideTest do
  use ExUnit.Case, async: false

  alias Aiur.Commands.Answering
  alias Aiur.{Decision, DecisionStore}

  setup do
    dir = Aiur.TestSupport.tmp_root!("answering-override-6908")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    store =
      start_supervised!(
        {DecisionStore,
         name: nil,
         state_dir: dir,
         filesystem_sync_fun: fn -> :ok end,
         dispatch_delay_ms: 60_000,
         answer_comment_publisher: fn _ -> :ok end,
         relay_enabled: fn -> true end,
         relay_notifier: fn _, _ -> :ok end}
      )

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{question: "Which direction?", blocking: true, source_id: "override-facade", authority: "supervisor_allowed", reversibility: "reversible"},
        [ticket: %{identifier: "6908", title: "Override", url: nil}, source: %{agent_id: "agent", session_id: "session"}],
        store
      )

    %{store: store, decision: decision}
  end

  test "delivered answer accepts an override with trusted dashboard attribution", ctx do
    original = answer_and_deliver(ctx)
    assert %{status: :accepted, decision: revised} = Answering.override(original.decision_id, payload("override", "New direction"), opts(ctx))
    assert revised.revision_sequence == 1
    assert Decision.active_answer(revised).custom_response == "New direction"
    assert Decision.active_answer(revised).actor == %{kind: :operator, id: "dashboard", source: :dashboard_session}
    assert %{status: :duplicate} = Answering.override(original.decision_id, payload("override", "New direction"), opts(ctx))
  end

  test "future regression guard: override before delivery preserves replacement behavior", ctx do
    assert %{status: :accepted, decision: first} = Answering.answer(ctx.decision.decision_id, payload("first", "Initial"), opts(ctx))
    assert %{status: :accepted, decision: replaced} = Answering.override(first.decision_id, payload("second", "Replacement"), opts(ctx))
    assert replaced.active_action_id != first.active_action_id
    assert Decision.active_answer(replaced).custom_response == "Replacement"
  end

  test "acknowledged answer remains overridable", ctx do
    original = answer_and_deliver(ctx)

    assert {:ok, %{decision_status: :acknowledged}} =
             DecisionStore.agent_lifecycle(
               :acknowledged,
               %{decision_id: original.decision_id, action_id: original.active_action_id, expected_version: 1},
               [ticket_identifier: "6908", actor: %{kind: :agent, id: "agent"}, source: %{agent_id: "agent", session_id: "session", invocation_id: "ack"}],
               ctx.store
             )

    assert %{status: :accepted, decision: revised} = Answering.override(original.decision_id, payload("after-ack", "Changed after acknowledgement"), opts(ctx))
    assert Decision.active_answer(revised).custom_response == "Changed after acknowledgement"
  end

  test "delivered override still checks the submitted version", ctx do
    original = answer_and_deliver(ctx)

    assert Answering.override(original.decision_id, %{payload("stale", "Wrong version") | expected_version: 2}, opts(ctx)) ==
             %{status: :stale, current_version: 1}

    assert {:ok, unchanged} = DecisionStore.get(original.decision_id, ctx.store)
    assert unchanged.active_action_id == original.active_action_id
  end

  test "CLI executor cannot override an operator answer after delivery", ctx do
    original = answer_and_deliver(ctx)
    cli = opts(ctx) |> Keyword.put(:actor, %{kind: :executor, id: "executor"}) |> Keyword.put(:actor_source, :executor_cli) |> Keyword.put(:client, %{surface: :cli})

    assert Answering.override(original.decision_id, payload("executor", "Executor direction"), cli) ==
             %{status: :not_allowed, reason: :human_answer}

    assert {:ok, unchanged} = DecisionStore.get(original.decision_id, ctx.store)
    assert unchanged.active_action_id == original.active_action_id
  end

  test "CLI executor can override its own delivered answer", ctx do
    cli = opts(ctx) |> Keyword.put(:actor, %{kind: :executor, id: "executor"}) |> Keyword.put(:actor_source, :executor_cli) |> Keyword.put(:client, %{surface: :cli})
    assert %{status: :accepted, decision: first} = Answering.answer(ctx.decision.decision_id, payload("first", "Initial"), cli)
    deliver(first, ctx.store)
    assert %{status: :accepted, decision: revised} = Answering.override(first.decision_id, payload("second", "Corrected"), cli)
    assert Decision.active_answer(revised).custom_response == "Corrected"
  end

  test "CLI supersede reaches the override route after delivery", ctx do
    assert {:ok, %{decision: first}} =
             DecisionStore.answer(ctx.decision.decision_id, payload("cli-first", "Initial"), [actor: %{kind: :executor, id: "executor"}], ctx.store)

    deliver(first, ctx.store)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Aiur.ExecutorCommandCLI.answer(
                 [
                   decision_id: first.decision_id,
                   expected_version: 1,
                   idempotency_key: "cli-override",
                   custom_response: "Changed from CLI",
                   rationale: "Changed direction",
                   executor_id: "executor",
                   supersede: true
                 ],
                 decision_store: ctx.store,
                 record_fact_fun: fn _, _, _, _ -> {:ok, %{status: :accepted}} end
               ) == 0
      end)

    assert output =~ "superseded the answer"
    assert {:ok, revised} = DecisionStore.get(first.decision_id, ctx.store)
    assert Decision.active_answer(revised).custom_response == "Changed from CLI"
    assert Decision.active_answer(revised).actor.source == :executor_cli
  end

  test "relayed CLI supersede corrects a delivered executor answer", ctx do
    assert {:ok, %{decision: first}} =
             DecisionStore.answer(ctx.decision.decision_id, payload("relay-first", "Initial"), [actor: %{kind: :executor, id: "executor"}], ctx.store)

    deliver(first, ctx.store)

    ExUnit.CaptureIO.capture_io(fn ->
      assert Aiur.OperatorRelayCLI.answer(
               [
                 decision_id: first.decision_id,
                 expected_version: 1,
                 idempotency_key: "relayed-override",
                 custom_response: "Hold the rollout",
                 quote: "Hold the rollout",
                 relayed_by: "executor",
                 supersede: true
               ],
               decision_store: ctx.store
             ) == 0
    end)

    assert {:ok, revised} = DecisionStore.get(first.decision_id, ctx.store)
    assert Decision.active_answer(revised).custom_response == "Hold the rollout"
    assert Decision.active_answer(revised).actor.kind == :operator_relayed
    assert Decision.active_answer(revised).operator_quote == "Hold the rollout"
  end

  defp answer_and_deliver(ctx) do
    assert %{status: :accepted, decision: decision} = Answering.answer(ctx.decision.decision_id, payload("first", "Initial"), opts(ctx))
    deliver(decision, ctx.store)
    decision
  end

  defp deliver(decision, store) do
    item = %{
      id: 1,
      target_issue_identifier: decision.ticket.identifier,
      action_id: decision.active_action_id,
      correlation: %{decision_id: decision.decision_id, decision_version: decision.version, action_id: decision.active_action_id, attempt_id: "attempt"}
    }

    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)
  end

  defp opts(ctx) do
    [
      actor: %{kind: :operator, id: "human"},
      actor_source: :dashboard_session,
      client: %{surface: :dashboard},
      store: ctx.store,
      override_context: %{pr: %{number: 123, merged?: false, head_sha: "before"}, worker: :active, capacity: :available}
    ]
  end

  defp payload(key, text), do: %{expected_version: 1, idempotency_key: key, custom_response: text, rationale: "Changed direction"}
end
