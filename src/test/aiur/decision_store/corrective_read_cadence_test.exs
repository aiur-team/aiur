defmodule Aiur.DecisionStore.CorrectiveReadCadenceTest do
  use ExUnit.Case, async: true

  alias Aiur.{Commands, DecisionStore}
  alias Aiur.Commands.CorrectiveTicket

  test "twenty thirty-second ticks bound open-ticket closure reads and never fetch issue labels" do
    ctx = fixture(:open)
    ticks(ctx, 20, 0)
    assert Agent.get(ctx.counts, & &1) == %{closure: 1, graphql: 0, issues: 0}
    ticks(ctx, 20)
    assert Agent.get(ctx.counts, & &1) == %{closure: 3, graphql: 0, issues: 0}
    assert {:ok, %{overrides: [%{state: :queued}]}} = DecisionStore.get(ctx.id, ctx.store)
  end

  test "an unsupported closure capability leaves an observational override queued without a failure fact" do
    ctx = fixture(:unsupported)
    ticks(ctx, 20, 0)
    assert Agent.get(ctx.counts, & &1) == %{closure: 1, graphql: 0, issues: 0}
    assert {:ok, decision} = DecisionStore.get(ctx.id, ctx.store)
    assert [%{state: :queued}] = decision.overrides
    assert {:ok, audit} = DecisionStore.audit_history(ctx.id, ctx.store)
    refute Enum.any?(audit, &match?(%Aiur.DecisionEvent{type: :override_corrective_failed}, &1))
  end

  test "a linked corrective ticket without a PR uses only delivered PR observations over twenty ticks" do
    ctx = fixture(:linked)
    ticks(ctx, 20)
    assert Agent.get(ctx.counts, & &1) == %{closure: 0, graphql: 0, issues: 1}
    assert {:ok, %{overrides: [%{corrective_ticket: %{identifier: "70"}, state: :queued}]}} = DecisionStore.get(ctx.id, ctx.store)
  end

  test "a closed ticket with no repository merge records a final observation across ticks and replay" do
    ctx = fixture(:closed)
    ticks(ctx, 20)
    assert {:ok, %{overrides: [%{closed_without_merged_pr_at: %DateTime{} = at}]}} = DecisionStore.get(ctx.id, ctx.store)
    assert Agent.get(ctx.counts, & &1) == %{closure: 1, graphql: 1, issues: 0}
    stop_supervised!(DecisionStore)
    store = start_supervised!({DecisionStore, ctx.opts})
    ticks(%{ctx | store: store}, 20)
    assert {:ok, %{overrides: [%{closed_without_merged_pr_at: ^at}]}} = DecisionStore.get(ctx.id, store)
    assert Agent.get(ctx.counts, & &1) == %{closure: 1, graphql: 1, issues: 0}
  end

  defp fixture(kind) do
    dir = Aiur.TestSupport.tmp_root!("corrective-read-cadence")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    clock = start_supervised!({Agent, fn -> DateTime.utc_now() end})
    counts = start_supervised!(Supervisor.child_spec({Agent, fn -> %{closure: 0, graphql: 0, issues: 0} end}, id: :counts))
    bump = fn key -> Agent.update(counts, &Map.update!(&1, key, fn n -> n + 1 end)) end

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      corrective_override_now: fn -> Agent.get(clock, & &1) end,
      corrective_override_reconciler: fn decision, record ->
        CorrectiveTicket.reconcile(decision, record,
          pull_request: fn _ ->
            if kind == :linked and is_nil(record.corrective_ticket),
              do: {:ok, %{number: 60, merged?: true, merge_commit_sha: "original-merge"}},
              else: {:ok, nil}
          end,
          issue_closure: fn _identifier, max_age ->
            assert max_age == 300_000
            bump.(:closure)
            if kind == :unsupported, do: {:error, :unsupported}, else: {:ok, %{open?: kind in [:open, :linked]}}
          end,
          resolve_pull_request: fn _identifier, _ ->
            bump.(:graphql)
            {:ok, %{state: :closed, merged?: false}}
          end,
          issues: fn _ ->
            bump.(:issues)
            {:ok, [%Aiur.Issue{labels: []}]}
          end,
          find: fn _, _ -> {:ok, nil} end,
          create: fn _, _ -> {:ok, %{"number" => 70, "url" => "https://example.test/70"}} end,
          comments: fn _ -> {:ok, []} end,
          comment: fn _, _ -> :ok end
        )
      end
    ]

    store = start_supervised!({DecisionStore, opts})
    request = [ticket: %{identifier: "50"}, source: %{agent_id: "worker", session_id: "session"}]
    {:ok, %{decision: decision}} = Commands.request(%{source_id: "cadence", question: "Colour?", blocking: false}, request, store)
    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, _} = Commands.answer(decision.decision_id, payload("blue"), actor, store)
    pr = if kind == :linked, do: %{number: 60, merged?: true}, else: :unknown
    context = %{pr: pr, worker: :unknown, capacity: :available}
    {:ok, _} = Commands.override(decision.decision_id, payload("green"), actor ++ [override_context: context], store)
    drain(store)
    %{store: store, opts: opts, id: decision.decision_id, clock: clock, counts: counts}
  end

  defp ticks(ctx, count, seconds \\ 30) do
    for _ <- 1..count do
      Agent.update(ctx.clock, &DateTime.add(&1, seconds))
      send(ctx.store, :reconcile_corrective_overrides)
      drain(ctx.store)
    end
  end

  defp drain(store) do
    Aiur.DispatcherTestSupport.wait_until(fn -> map_size(:sys.get_state(store).corrective_override_jobs) == 0 end)
  end

  defp payload(value), do: %{expected_version: 1, custom_response: value, rationale: "Correction", idempotency_key: value}
end
