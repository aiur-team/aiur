defmodule Aiur.DecisionStore.CorrectiveObservationScopeTest do
  use ExUnit.Case, async: true

  alias Aiur.{Commands, DecisionStore}

  @pr %{number: 77, merged?: false, head_sha: "before", head_ref: "work"}

  test "an old asynchronous observation cannot delay corrective creation after provider recheck" do
    ctx = fixture(:blocked)
    send(ctx.store, {:override_ticket_merged, "50"})
    assert_receive {:old_observation, job}, 2_000
    merge_and_recheck(ctx)
    send(job, :release_observation)
    assert_corrective_created(ctx)
    assert Agent.get(ctx.clock, & &1) == ctx.now
  end

  test "a settled observation wait does not carry from the worker route into the corrective route" do
    ctx = fixture(:immediate)
    send(ctx.store, {:override_ticket_merged, "50"})
    assert_receive {:old_observation, _}, 2_000

    Aiur.DispatcherTestSupport.wait_until(fn ->
      state = :sys.get_state(ctx.store)
      state.corrective_override_jobs == %{} and Map.has_key?(state.corrective_override_observations, ctx.id)
    end)

    merge_and_recheck(ctx)
    assert_corrective_created(ctx)
    assert Agent.get(ctx.clock, & &1) == ctx.now
  end

  defp merge_and_recheck(ctx) do
    Agent.update(ctx.pr, &Map.put(&1, :merged?, true))

    item = %{
      id: 2,
      target_issue_identifier: "50",
      action_id: ctx.action,
      correlation: %{decision_id: ctx.id, decision_version: 1, action_id: ctx.action, attempt_id: "scope-recheck"}
    }

    assert {:error, {:answer_withdrawn, :pr_merged}} = DecisionStore.validate_delivery(item, ctx.store)
    assert {:ok, %{overrides: [%{route: :corrective_ticket, merge_version: 2}]}} = DecisionStore.get(ctx.id, ctx.store)
  end

  defp assert_corrective_created(ctx) do
    action = ctx.action
    assert_receive {:corrective_created, ^action}, 2_000

    Aiur.DispatcherTestSupport.wait_until(fn ->
      {:ok, decision} = DecisionStore.get(ctx.id, ctx.store)
      match?([%{route: :corrective_ticket, corrective_ticket: %{identifier: "9000"}}], decision.overrides)
    end)
  end

  defp fixture(mode) do
    dir = Aiur.TestSupport.tmp_root!("corrective-observation-scope")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    now = DateTime.utc_now()
    clock = start_supervised!({Agent, fn -> now end})
    pr = start_supervised!(Supervisor.child_spec({Agent, fn -> @pr end}, id: :pr))
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
      corrective_override_now: fn -> Agent.get(clock, & &1) end,
      corrective_override_reconciler: fn _decision, record -> reconcile(record, mode, owner) end
    ]

    store = start_supervised!({DecisionStore, opts})
    {:ok, %{decision: requested}} = Commands.request(%{source_id: "scope", question: "Proceed?", blocking: false}, [ticket: %{identifier: "50"}], store)
    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, _} = Commands.answer(requested.decision_id, payload("original"), actor, store)
    context = %{pr: @pr, worker: :active, capacity: :available}
    {:ok, %{decision: revised}} = Commands.override(requested.decision_id, payload("override"), actor ++ [override_context: context], store)
    %{store: store, id: requested.decision_id, action: revised.active_action_id, clock: clock, now: now, pr: pr}
  end

  defp reconcile(%{corrective_ticket: ticket}, _mode, _owner) when is_map(ticket), do: {:ok, []}

  defp reconcile(%{route: :corrective_ticket} = record, _mode, owner) do
    send(owner, {:corrective_created, record.action_id})
    {:ok, [{:override_corrective_ticket, %{action_id: record.action_id, ticket: %{identifier: "9000", title: "Correction", url: nil}, pr_number: 77, merge_commit_sha: "merged"}}]}
  end

  defp reconcile(_record, mode, owner) do
    send(owner, {:old_observation, self()})
    if mode == :blocked, do: wait_for_release()
    {:ok, []}
  end

  defp wait_for_release do
    receive do
      :release_observation -> :ok
    after
      5_000 -> raise "old observation was not released"
    end
  end

  defp payload(value), do: %{expected_version: 1, custom_response: value, rationale: "Correction", idempotency_key: value}
end
