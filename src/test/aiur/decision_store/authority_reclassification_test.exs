Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.AuthorityReclassificationTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.DecisionStore.Persistence

  test "baseline contract: omitted authority defaults to Executor; explicit human-required needs a basis", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: %{authority: :supervisor_allowed, reversibility: :reversible}}} =
             request(pid, %{"question" => "Should we keep the established cap?", "blocking" => true})

    assert {:error, {:decision_invalid, {:authority, :human_required_basis_required}}} =
             DecisionStore.request(
               %{"question" => "Should we keep the established cap?", "blocking" => true, "authority" => "human_required"},
               [ticket: @ticket, source: @source],
               pid
             )

    assert length(DecisionStore.list(pid)) == 1
  end

  test "Executor reclassifies with rationale, then answers; audit attributes both actions", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    legacy = seed_legacy_human_required_decision!(pid)
    GenServer.stop(pid)
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{authority: :human_required, context: %{short_summary: nil, long_context_markdown: nil}}} =
             DecisionStore.get(legacy.decision_id, pid)

    assert {:ok, %{status: :accepted, decision: %{authority: :supervisor_allowed}}} =
             DecisionStore.reclassify_authority(
               legacy.decision_id,
               %{expected_version: 1, executor_id: "executor-1", rationale: "Acceptance already defines the fallback."},
               pid
             )

    assert {:error, {:stale_version, 1, 2}} =
             DecisionStore.reclassify_authority(
               legacy.decision_id,
               %{expected_version: 1, executor_id: "executor-1", rationale: "Stale view."},
               pid
             )

    assert {:ok, %{status: :accepted, action: %{actor: %{kind: :executor, id: "executor-1"}}}} =
             DecisionStore.answer(
               legacy.decision_id,
               %{"expected_version" => 2, "idempotency_key" => "reclassified-answer", "custom_response" => "Keep the cap."},
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert {:ok, audit} = DecisionStore.audit_history(legacy.decision_id, pid)
    assert Enum.any?(audit, &match?(%DecisionEvent{type: :authority_reclassified, data: %{actor: %{kind: :executor, id: "executor-1"}, detail: "Acceptance already defines the fallback."}}, &1))
    assert Enum.any?(audit, &match?(%DecisionEvent{type: :answer_recorded, data: %{actor: %{kind: :executor, id: "executor-1"}}}, &1))

    GenServer.stop(pid)
    recovered = start_store!(dir, dispatch_delay_ms: 60_000)
    assert {:ok, %{authority: :supervisor_allowed, decision_status: :decided, version: 2}} = DecisionStore.get(legacy.decision_id, recovered)
    assert {:ok, recovered_audit} = DecisionStore.audit_history(legacy.decision_id, recovered)
    assert Enum.any?(recovered_audit, &match?(%DecisionEvent{type: :authority_reclassified, data: %{actor: %{kind: :executor, id: "executor-1"}}}, &1))
    assert Enum.any?(recovered_audit, &match?(%DecisionEvent{type: :answer_recorded, data: %{actor: %{kind: :executor, id: "executor-1"}}}, &1))
  end

  test "Executor cannot reclassify a decision with a human-only basis", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Should we publish the private customer data?",
               "blocking" => true,
               "authority" => "human_required"
             })

    assert {:error, :human_required_basis_cannot_be_reclassified} =
             DecisionStore.reclassify_authority(
               decision.decision_id,
               %{expected_version: decision.version, executor_id: "executor-1", rationale: "I consider it safe."},
               pid
             )
  end

  test "Executor cannot reclassify legacy attention Commands", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             project_attention(
               pid,
               %{
                 "question" => "Should the human resolve this attention?",
                 "blocking" => false,
                 "kind" => "legacy_attention",
                 "source_id" => "legacy_attention:authority-reclassification"
               }
             )

    assert {:error, :human_required_basis_cannot_be_reclassified} =
             DecisionStore.reclassify_authority(
               decision.decision_id,
               %{expected_version: decision.version, executor_id: "executor-1", rationale: "No operator needed."},
               pid
             )
  end

  # The store's request path builds the reclassification actor itself, so the
  # actor-kind guard in `DecisionEvent.AuthorityReclassification` is the only
  # thing stopping a non-Executor reclassification that reaches persistence.
  for {label, actor, reason} <- [
        {"a worker kind", %{kind: "worker", id: "agent-1"}, {:actor_kind, :not_executor}},
        {"an operator kind", %{kind: :operator, id: "operator-1"}, {:actor_kind, :not_executor}},
        {"a missing kind", %{id: "agent-1"}, {:actor_kind, :not_executor}},
        {"a non-map actor", "executor", {:actor, :invalid}}
      ] do
    test "reclassification by #{label} is refused and leaves the decision unchanged", %{dir: dir} do
      pid = start_store!(dir, dispatch_delay_ms: 60_000)
      legacy = seed_legacy_human_required_decision!(pid)
      GenServer.stop(pid)
      pid = start_store!(dir, dispatch_delay_ms: 60_000)

      state = :sys.get_state(pid)
      {:ok, decision} = DecisionStore.get(legacy.decision_id, pid)
      journal_before = File.read!(state.ndjson_path)
      data = %{actor: unquote(Macro.escape(actor)), authority: :supervisor_allowed, detail: "Not mine to decide.", expected_version: 1}

      assert {:error, unquote(Macro.escape(reason))} =
               Persistence.build_and_persist_event(:authority_reclassified, decision, data, DateTime.utc_now(), state)

      assert File.read!(state.ndjson_path) == journal_before
      assert {:ok, %{authority: :human_required, version: 1}} = DecisionStore.get(legacy.decision_id, pid)

      GenServer.stop(pid)
      recovered = start_store!(dir, dispatch_delay_ms: 60_000)
      assert {:ok, %{authority: :human_required, version: 1}} = DecisionStore.get(legacy.decision_id, recovered)
    end
  end

  defp seed_legacy_human_required_decision!(pid) do
    now = DateTime.utc_now()

    assert {:ok, decision} =
             DecisionValidation.normalize(
               %{
                 "question" => "Should we keep the established cap?",
                 "blocking" => true,
                 "authority" => "human_required"
               },
               ticket: @ticket,
               source: @source,
               now: now,
               legacy_replay: true
             )

    {:ok, event} =
      DecisionEvent.new(:requested, decision.decision_id, decision.version, decision,
        event_id: IdGenerator.next_id(),
        run_id: "legacy-fixture",
        now: now
      )

    journal_path = :sys.get_state(pid).ndjson_path
    :ok = Aiur.Journal.append(journal_path, DecisionEvent.to_json_safe(event))
    decision
  end
end
