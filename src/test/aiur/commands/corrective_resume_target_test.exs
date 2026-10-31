defmodule Aiur.Commands.CorrectiveResumeTargetTest do
  use ExUnit.Case, async: false

  alias Aiur.{Commands, DecisionStore, Issue}
  alias Aiur.Commands.OverridePrompt
  alias Aiur.Orchestrator.{OverrideResume, State}

  @source %{agent_id: "worker", session_id: "session"}

  setup do
    dir = Aiur.TestSupport.tmp_root!("corrective-resume-target")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    store =
      start_supervised!(
        {DecisionStore,
         name: nil,
         state_dir: dir,
         filesystem_sync_fun: fn -> :ok end,
         dispatch_delay_ms: 60_000,
         reconcile_delay_ms: 60_000,
         answer_comment_publisher: fn _ -> :ok end,
         corrective_override_reconciler: fn _, _ -> {:ok, []} end}
      )

    decision = corrective_override(store, "first", "43")
    issue = %Issue{id: "43", identifier: "43", title: "Corrective work", state: "in-progress", labels: ["agent:in-progress"]}
    %{store: store, decision: decision, issue: issue}
  end

  test "corrective resume prompts reach the new ticket and acknowledgement still waits for its PR merge", ctx do
    assert [] == OverridePrompt.prepare("42", decision_store: ctx.store)[:pending_overrides]
    opts = OverridePrompt.prepare("43", decision_store: ctx.store)
    assert [pending] = opts[:pending_overrides]
    assert pending.decision_id == ctx.decision.decision_id
    assert OverridePrompt.render(opts) =~ "Latest correction"
    assert :ok = OverridePrompt.received(%{event: :turn_started}, opts)

    assert {:ok, delivered} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    assert %{state: :delivered, delivered_at: %DateTime{}, corrective_ticket: %{identifier: "43"}} = List.last(delivered.overrides)
    lifecycle = %{decision_id: delivered.decision_id, action_id: delivered.active_action_id, expected_version: 1}
    assert {:ok, _} = Commands.agent_lifecycle(:acknowledged, lifecycle, [ticket_identifier: "43", actor: %{kind: :agent, id: "worker"}, source: @source], ctx.store)
    assert {:ok, acknowledged} = DecisionStore.get(delivered.decision_id, ctx.store)
    assert %{state: :delivered, implemented_at: nil} = List.last(acknowledged.overrides)
  end

  test "resume admission uses the corrective target and rejects an earlier original-ticket lookup", ctx do
    owner = self()
    state = %State{max_concurrent_agents: 1}

    opts = [
      decision_store: ctx.store,
      admission_fun: fn _ -> :dispatch end,
      resume_fun: fn current, issue, _entry ->
        send(owner, {:resumed, issue.identifier})
        {{:ok, :started}, current}
      end
    ]

    original = %{ctx.issue | id: "42", identifier: "42"}
    assert OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [original]}, {:ok, nil}}], opts) == state
    refute_received {:resumed, _}
    OverrideResume.apply_loaded(state, [{ctx.decision, {:ok, [ctx.issue]}, {:ok, nil}}], opts)
    assert_received {:resumed, "43"}
    refute_received {:resumed, "42"}
  end

  test "corrective resume deduplication and parked questions use the corrective ticket", ctx do
    other = corrective_override(ctx.store, "other", "44")
    assert [first, second] = OverrideResume.waiting([ctx.decision, other])
    assert first.decision_id == ctx.decision.decision_id
    assert second.decision_id == other.decision_id
    parked = %{ctx.issue | parked: true}
    OverrideResume.apply_loaded(%State{max_concurrent_agents: 1}, [{ctx.decision, {:ok, [parked]}, {:ok, nil}}], decision_store: ctx.store)
    assert [question] = Enum.filter(Commands.list_decisions(ctx.store), &(&1.question == "Resume #43 to apply the override?"))
    assert question.requester.ticket == "43"
    refute Enum.any?(Commands.list_decisions(ctx.store), &(&1.question == "Resume #42 to apply the override?"))
  end

  defp corrective_override(store, source_id, target) do
    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, %{decision: decision}} = Commands.request(%{source_id: source_id, question: "Which direction?", blocking: false}, [ticket: %{identifier: "42"}, source: @source], store)
    {:ok, _} = Commands.answer(decision.decision_id, payload("original"), actor, store)
    merged = %{pr: %{number: 77, merged?: true}, worker: :resumable, capacity: :full}
    {:ok, %{decision: first}} = Commands.override(decision.decision_id, payload("first correction"), actor ++ [override_context: merged], store)
    ticket = %{identifier: target, title: "Correction", url: "https://example.test/issues/#{target}"}

    {:ok, _} =
      Commands.record_command_fact(first.decision_id, :override_corrective_ticket, %{action_id: first.active_action_id, ticket: ticket, pr_number: 77, merge_commit_sha: "original-merge"},
        server: store
      )

    open = %{pr: %{number: 88, merged?: false}, worker: :resumable, capacity: :full}
    {:ok, %{decision: newest}} = Commands.override(first.decision_id, payload("Latest correction"), actor ++ [override_context: open], store)
    newest
  end

  defp payload(text), do: %{expected_version: 1, custom_response: text, rationale: "Changed direction", idempotency_key: text}
end
