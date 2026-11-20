defmodule Aiur.Commands.ExecutorAnswerGuardsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{DecisionStore, ExecutorCommandCLI, OperatorRelayCLI}

  setup do
    dir = Aiur.TestSupport.tmp_root!("executor-answer-guards")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    {:ok, delegated} = Agent.start_link(fn -> false end)

    store =
      start_supervised!(
        {DecisionStore,
         name: nil,
         state_dir: dir,
         filesystem_sync_fun: fn -> :ok end,
         dispatch_delay_ms: 60_000,
         relay_enabled: fn -> true end,
         allow_reversible_human_required_answers: fn -> Agent.get(delegated, & &1) end,
         relay_notifier: fn _, _ -> :ok end,
         answer_comment_publisher: fn _ -> :ok end}
      )

    %{store: store, journal: Path.join(dir, "decisions.ndjson"), delegated: delegated}
  end

  test "operator delegation permits only reversible legacy human-required Commands and keeps Executor attribution", ctx do
    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{
          question: "Use the established trailer format?",
          kind: "legacy_attention",
          blocking: true,
          authority: "human_required",
          reversibility: "reversible",
          source_id: "delegated-legacy",
          options: [%{id: "yes", label: "Use the established format"}]
        },
        [ticket: %{identifier: "6410"}, source: %{agent_id: "worker", session_id: "delegated-test"}],
        ctx.store
      )

    assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} =
             DecisionStore.answer(decision.decision_id, payload("before-delegation"), actor(:executor), ctx.store)

    assert :ok = Agent.update(ctx.delegated, fn _ -> true end)

    assert {:ok, %{decision: answered, status: :accepted}} =
             DecisionStore.answer(decision.decision_id, payload("after-delegation"), actor(:executor), ctx.store)

    assert answered.answer.actor.kind == :executor
    assert answered.answer.rationale == "Operator choice"
  end

  test "delegation cannot authorize product, spend, publication, or security basis", ctx do
    :ok = Agent.update(ctx.delegated, fn _ -> true end)

    for basis <- ["product", "spend", "external_publication", "security"] do
      {:ok, %{decision: decision}} =
        DecisionStore.request(
          %{
            question: "Do the protected action?",
            kind: "legacy_attention",
            context: %{authority_basis: basis},
            blocking: true,
            authority: "human_required",
            reversibility: "reversible",
            source_id: "protected-#{basis}",
            options: [%{id: "yes", label: "Yes"}]
          },
          [ticket: %{identifier: "6410"}, source: %{agent_id: "worker", session_id: "delegated-test"}],
          ctx.store
        )

      assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} =
               DecisionStore.answer(decision.decision_id, payload("protected-#{basis}"), actor(:executor), ctx.store)
    end
  end

  test "Executor cannot answer its own Command even with delegable authority", ctx do
    decision = request(ctx.store, :executor)
    before = File.read!(ctx.journal)

    assert {:error, {:answer_invalid, {:executor_scope, :executor_originated}}} =
             DecisionStore.answer(decision.decision_id, payload("executor-answer"), actor(:executor), ctx.store)

    assert File.read!(ctx.journal) == before
  end

  test "relay cannot answer an Executor Command and the CLI names direct human surfaces", ctx do
    decision = request(ctx.store, :executor)
    before = File.read!(ctx.journal)

    assert {:error, {:answer_invalid, :relay_on_executor_command}} =
             DecisionStore.answer(decision.decision_id, relay_payload("relay-answer"), actor(:operator_relayed), ctx.store)

    error =
      capture_io(:stderr, fn ->
        assert OperatorRelayCLI.answer(
                 [
                   decision_id: decision.decision_id,
                   expected_version: 1,
                   option_id: "yes",
                   quote: "Ship",
                   relayed_by: "executor",
                   idempotency_key: "relay-cli"
                 ],
                 decision_store: ctx.store
               ) == 1
      end)

    assert error =~ "this Command was raised by the Executor"
    assert error =~ "dashboard, Stream Deck or phone"
    assert File.read!(ctx.journal) == before
  end

  for operation <- [:revise, :supersede], kind <- [:executor, :operator_relayed] do
    test "#{kind} #{operation} of an operator answer on an Executor Command is refused before replacement", ctx do
      decision = request(ctx.store, :executor)

      assert {:ok, %{status: :accepted, action: accepted}} =
               DecisionStore.answer(decision.decision_id, payload("operator-answer"), actor(:operator), ctx.store)

      Aiur.DispatcherTestSupport.wait_until(fn ->
        {:ok, current} = DecisionStore.get(decision.decision_id, ctx.store)
        current.ticket_comment_status == :published
      end)

      before = File.read!(ctx.journal)
      revision = relay_payload("relay-revision") |> Map.merge(%{expected_action_id: accepted.action_id, expected_revision_sequence: 0})

      expected = if unquote(kind) == :executor, do: {:executor_scope, :executor_originated}, else: :relay_on_executor_command

      assert {:error, {:answer_invalid, ^expected}} =
               apply(DecisionStore, unquote(operation), [decision.decision_id, revision, actor(unquote(kind)), ctx.store])

      assert {:ok, current} = DecisionStore.get(decision.decision_id, ctx.store)
      assert current.active_action_id == accepted.action_id
      assert current.revisions == []
      assert File.read!(ctx.journal) == before
    end
  end

  test "Executor CLI explains that its own Command needs the human", ctx do
    decision = request(ctx.store, :executor)

    error =
      capture_io(:stderr, fn ->
        assert ExecutorCommandCLI.answer(
                 [
                   decision_id: decision.decision_id,
                   expected_version: 1,
                   option_id: "yes",
                   rationale: "Looks obvious",
                   idempotency_key: "executor-cli"
                 ],
                 decision_store: ctx.store
               ) == 1
      end)

    assert error =~ "you raised this Command; it needs the human"
  end

  test "future regression: a relay may still answer a worker Command", ctx do
    decision = request(ctx.store, :worker)

    assert {:ok, %{status: :accepted, action: answer}} =
             DecisionStore.answer(decision.decision_id, relay_payload("worker-relay"), actor(:operator_relayed), ctx.store)

    assert answer.actor.kind == :operator_relayed
    assert answer.operator_quote == "Ship"
  end

  defp request(store, kind) do
    ticket = if kind == :executor, do: "executor", else: "6410"

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{
          question: "Ship the beta?",
          blocking: true,
          authority: "supervisor_allowed",
          reversibility: "reversible",
          source_id: "request-#{kind}",
          options: [%{id: "yes", label: "Ship"}, %{id: "no", label: "Wait"}]
        },
        [ticket: %{identifier: ticket}, requester: %{kind: kind}, origin: :executor_cli, source: %{agent_id: "executor", session_id: "guards-test"}],
        store
      )

    decision
  end

  defp payload(key), do: %{expected_version: 1, option_id: "yes", rationale: "Operator choice", idempotency_key: key}
  defp relay_payload(key), do: Map.merge(payload(key), %{operator_quote: "Ship", relayed_by: "executor"})
  defp actor(kind), do: [actor: %{kind: kind, id: "executor"}, actor_source: if(kind == :operator_relayed, do: :relay_cli, else: :executor_cli)]
end
