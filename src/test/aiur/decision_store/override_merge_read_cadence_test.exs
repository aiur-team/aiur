defmodule Aiur.DecisionStore.OverrideMergeReadCadenceTest do
  use ExUnit.Case, async: true

  alias Aiur.{Commands, DecisionStore}
  alias Aiur.Commands.CorrectiveTicket
  alias Aiur.DecisionStore.OverridePushes

  @open %{number: 77, merged?: false, head_sha: "before", head_ref: "work"}

  test "twenty push ticks skip a journaled closed-without-merge result" do
    ctx = fixture()
    assert {:ok, _} = Commands.record_command_fact(ctx.id, :override_corrective_closed, %{action_id: ctx.action}, server: ctx.store)
    assert {:ok, decision} = DecisionStore.get(ctx.id, ctx.store)
    counts = ctx.counts
    owner = self()

    state = %{
      current: %{ctx.id => decision},
      override_context_reader: fn _ ->
        send(owner, :terminal_cache_read)
        Agent.update(counts, &Map.update!(&1, :cache, fn n -> n + 1 end))
        %{pr: :unknown}
      end
    }

    for _ <- 1..20, do: assert(:ok == OverridePushes.reconcile(state))
    refute_receive :terminal_cache_read, 50
    assert Agent.get(counts, & &1.cache) == 0
  end

  test "twenty merged PR cache observations request bounded reconciliation without a remote evidence read" do
    counts = start_supervised!({Agent, fn -> 0 end})
    record = %{state: :delivered, route: :active_worker, action_id: "action", ticket: %{identifier: "50"}}
    decision = %{decision_id: "command", ticket: record.ticket, active_action_id: "action", overrides: [record]}

    state = %{
      current: %{"command" => decision},
      override_context_reader: fn _ -> %{pr: Map.put(@open, :merged?, true)} end,
      override_merge_reader: fn pr ->
        Agent.update(counts, &(&1 + 1))
        {:ok, pr}
      end
    }

    for _ <- 1..20 do
      assert :ok = OverridePushes.reconcile(state)
      assert_receive {:override_ticket_merged, "50"}, 2_000
    end

    assert Agent.get(counts, & &1) == 0
  end

  test "failed original-worker merge evidence uses journaled exponential backoff across twenty ticks" do
    ctx = fixture(@open)
    assert {:ok, _} = Commands.record_command_fact(ctx.id, :override_prompt_delivered, %{action_id: ctx.action, at: DateTime.utc_now()}, server: ctx.store)
    assert {:ok, %{overrides: [%{delivered_at: delivered_at}]}} = DecisionStore.get(ctx.id, ctx.store)
    push = %{action_id: ctx.action, head_sha: "worker", pr_number: 77, at: DateTime.add(delivered_at, 1)}
    assert {:ok, _} = Commands.record_command_fact(ctx.id, :override_implemented, push, server: ctx.store)
    Agent.update(ctx.pr, &Map.merge(&1, %{merged?: true, merge_commit_sha: "merged"}))
    send(ctx.store, {:override_ticket_merged, "50"})
    await(ctx, 1)
    assert Agent.get(ctx.counts, & &1.evidence) == 1

    for {seconds, attempts} <- [{30, 1}, {30, 2}, {30, 2}, {30, 2}, {30, 2}, {30, 3}] do
      tick(ctx, seconds)
      await(ctx, attempts)
      assert Agent.get(ctx.counts, & &1.evidence) == attempts
    end

    for _ <- 1..14, do: tick(ctx, 30)
    await(ctx, 4)
    assert Agent.get(ctx.counts, & &1.evidence) == 4
    assert {:ok, %{overrides: [%{state: :delivered, route: :active_worker, failure: %{attempts: 4}}]}} = DecisionStore.get(ctx.id, ctx.store)
  end

  test "twenty unmerged update-branch observations cannot manufacture a worker push before merge" do
    ctx = fixture(@open)
    assert {:ok, _} = Commands.record_command_fact(ctx.id, :override_prompt_delivered, %{action_id: ctx.action, at: DateTime.utc_now()}, server: ctx.store)
    assert {:ok, %{overrides: [%{delivered_at: delivered_at}]}} = DecisionStore.get(ctx.id, ctx.store)
    pr = @open |> Map.put(:head_sha, "update-branch") |> Map.put(:head_updated_at, DateTime.add(delivered_at, 60))
    owner = self()
    state = :sys.get_state(ctx.store)

    state = %{
      state
      | override_context_reader: fn _ ->
          send(owner, :unmerged_cache_read)
          %{pr: pr}
        end
    }

    for _ <- 1..20 do
      assert :ok = OverridePushes.reconcile(state)
      assert_receive :unmerged_cache_read, 2_000
      refute_receive {:override_push_observed, _, _, _, _, _}, 20
    end

    fact = %{action_id: ctx.action, expected_version: 1, head_sha: "update-branch", pr_number: 77, worker_head_sha: nil, head_contains_worker_push: true}
    assert {:ok, _} = Commands.record_command_fact(ctx.id, :override_merge_settled, fact, server: ctx.store)
    assert {:ok, %{overrides: [%{state: :delivered, route: :corrective_ticket, implemented_at: nil}]}} = DecisionStore.get(ctx.id, ctx.store)
  end

  test "a pending matching push settles before timer-driven merge reconciliation" do
    ctx = fixture(@open, :contains_worker)
    assert {:ok, _} = Commands.record_command_fact(ctx.id, :override_prompt_delivered, %{action_id: ctx.action, at: DateTime.utc_now()}, server: ctx.store)
    assert {:ok, %{overrides: [%{delivered_at: delivered_at}]}} = DecisionStore.get(ctx.id, ctx.store)
    Agent.update(ctx.gate, fn _ -> :sample end)
    send(ctx.store, {:event, %{topic: "ticket.50.branch.push", source: :system, sha: "worker", ref: "refs/heads/work"}})
    assert_receive {:cache_sampled, _, @open}, 2_000
    assert :sys.get_state(ctx.store).override_pending_pushes[{ctx.id, ctx.action}] == %{sha: "worker", ref: "refs/heads/work"}
    Agent.update(ctx.pr, &Map.merge(&1, %{merged?: true, head_sha: "worker", head_updated_at: DateTime.add(delivered_at, 1), merge_commit_sha: "merged"}))
    Agent.update(ctx.gate, fn _ -> {:block, ctx.store} end)
    send(ctx.store, :reconcile_override_pushes)
    assert_receive {:lookup_blocked, lookup}, 2_000
    drain(ctx.store)
    assert {:ok, %{overrides: [%{route: :active_worker, evidence: nil}]}} = DecisionStore.get(ctx.id, ctx.store)
    assert Agent.get(ctx.counts, & &1.evidence) == 0
    send(lookup, :release_lookup)

    Aiur.DispatcherTestSupport.wait_until(fn ->
      {:ok, decision} = DecisionStore.get(ctx.id, ctx.store)
      match?([%{state: :implemented, corrective_ticket: nil}], decision.overrides)
    end)

    assert Agent.get(ctx.counts, & &1.evidence) == 1
    refute_receive :unexpected_corrective_create, 20
  end

  defp fixture(pr_context \\ :unknown, outcome \\ {:error, :lookup_failed}) do
    dir = Aiur.TestSupport.tmp_root!("override-merge-cadence")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    clock = start_supervised!({Agent, fn -> DateTime.utc_now() end})
    pr = start_supervised!(Supervisor.child_spec({Agent, fn -> @open end}, id: :pr))
    gate = start_supervised!(Supervisor.child_spec({Agent, fn -> nil end}, id: :gate))
    counts = start_supervised!(Supervisor.child_spec({Agent, fn -> %{cache: 0, evidence: 0} end}, id: :counts))
    owner = self()

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      override_context_reader: fn _ ->
        case Agent.get(gate, & &1) do
          {:block, store} when store != self() ->
            send(owner, {:lookup_blocked, self()})

            receive do
              :release_lookup -> :ok
            after
              5_000 -> raise "pending lookup was not released"
            end

          _ ->
            :ok
        end

        current = Agent.get(pr, & &1)
        if Agent.get(gate, & &1) == :sample, do: send(owner, {:cache_sampled, self(), current})
        %{pr: current}
      end,
      override_pr_reader: fn _ -> {:ok, Agent.get(pr, & &1)} end,
      override_merge_reader: fn _ -> flunk("push ticks must not perform remote merge evidence reads") end,
      corrective_override_now: fn -> Agent.get(clock, & &1) end,
      corrective_override_alert: fn _, _, _ -> :ok end,
      corrective_override_reconciler: fn decision, record ->
        CorrectiveTicket.reconcile(decision, record,
          pull_request: fn _ -> {:ok, Agent.get(pr, & &1)} end,
          merge_head: fn snapshot ->
            Agent.update(counts, &Map.update!(&1, :evidence, fn n -> n + 1 end))
            if outcome == :contains_worker, do: {:ok, Map.put(snapshot, :head_contains_worker_push, true)}, else: outcome
          end,
          find: fn _, _ -> {:ok, nil} end,
          issues: fn _ -> {:ok, []} end,
          create: fn _, _ ->
            send(owner, :unexpected_corrective_create)
            {:error, :unexpected_create}
          end,
          comments: fn _ -> {:ok, []} end,
          comment: fn _, _ -> :ok end
        )
      end
    ]

    store = start_supervised!({DecisionStore, opts})
    {:ok, %{decision: decision}} = Commands.request(%{source_id: "cadence", question: "Colour?", blocking: false}, [ticket: %{identifier: "50"}], store)
    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, _} = Commands.answer(decision.decision_id, payload("blue"), actor, store)
    {:ok, %{decision: override}} = Commands.override(decision.decision_id, payload("green"), actor ++ [override_context: %{pr: pr_context, worker: :active, capacity: :available}], store)
    drain(store)
    %{store: store, id: decision.decision_id, action: override.active_action_id, clock: clock, pr: pr, counts: counts, gate: gate}
  end

  defp tick(ctx, seconds) do
    Agent.update(ctx.clock, &DateTime.add(&1, seconds))
    send(ctx.store, :reconcile_override_pushes)
    drain(ctx.store)
  end

  defp await(ctx, attempts) do
    Aiur.DispatcherTestSupport.wait_until(fn ->
      {:ok, decision} = DecisionStore.get(ctx.id, ctx.store)
      match?([%{failure: %{attempts: ^attempts}}], decision.overrides)
    end)
  end

  defp drain(store), do: Aiur.DispatcherTestSupport.wait_until(fn -> map_size(:sys.get_state(store).corrective_override_jobs) == 0 end)
  defp payload(value), do: %{expected_version: 1, custom_response: value, rationale: "Correction", idempotency_key: value}
end
