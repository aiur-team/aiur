defmodule Aiur.DecisionStore.CorrectiveOverrideFailureTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.{CorrectiveFailures, CorrectiveTicket}
  alias Aiur.{Commands, DecisionPubSub, DecisionStore}

  test "a rejected create backs off across replay, exposes its failure and alerts once until recovery" do
    %{store: store, opts: opts, decision: decision, revised: revised, clock: clock, outcome: outcome, now: now} = failed_override("rejected-create")
    action = revised.active_action_id
    assert_receive {:create_post, ^action}, 2_000
    assert_receive {:corrective_alert, topic, _message, alert_opts}, 2_000
    assert topic =~ "ticket.50.agent.attention.command-corrective-"
    assert alert_opts[:needs_attention]
    failed = await(store, decision.decision_id, &match?([%{state: :failed, failure: %{attempts: 1}}], &1.overrides))
    assert [%{failure: %{attempts: 1, retry_at: retry_at, alerted: true, reason: reason}}] = failed.overrides
    assert DateTime.diff(retry_at, now) == 60
    assert reason =~ "422"
    assert [%{"state" => "failed", "failure" => %{"attempts" => 1, "retry_at" => public_retry, "reason" => ^reason}}] = Commands.public_v2(failed).overrides
    assert public_retry == DateTime.to_iso8601(retry_at)

    Agent.update(clock, &DateTime.add(&1, 30))
    send(store, :reconcile_corrective_overrides)
    assert {:ok, _decision} = DecisionStore.get(decision.decision_id, store)
    refute_receive {:create_post, ^action}, 20
    stop_supervised!(DecisionStore)
    restarted = start_supervised!({DecisionStore, opts})
    send(restarted, :reconcile_corrective_overrides)
    assert {:ok, %{overrides: [%{failure: %{attempts: 1}}]}} = DecisionStore.get(decision.decision_id, restarted)
    refute_receive {:create_post, ^action}, 20

    Agent.update(clock, &DateTime.add(&1, 30))
    send(restarted, :reconcile_corrective_overrides)
    assert_receive {:create_post, ^action}, 2_000
    second = await(restarted, decision.decision_id, &match?([%{failure: %{attempts: 2}}], &1.overrides))
    assert [%{failure: %{retry_at: second_retry}}] = second.overrides
    assert DateTime.diff(second_retry, retry_at) == 120
    refute_receive {:corrective_alert, ^topic, _message, _opts}, 20

    Agent.update(clock, fn _ -> second_retry end)
    Agent.update(outcome, fn _ -> {:ok, %{"number" => 70, "url" => "https://example.test/70"}} end)
    send(restarted, :reconcile_corrective_overrides)
    assert_receive {:create_post, ^action}, 2_000
    recovered = await(restarted, decision.decision_id, &match?([%{state: :queued, failure: nil}], &1.overrides))
    assert [%{state: :queued, failure: nil}] = recovered.overrides
    resolved = topic <> ".resolved"
    assert_receive {:corrective_alert, ^resolved, _message, resolved_opts}, 2_000
    refute resolved_opts[:needs_attention]
  end

  test "a newer override clears the superseded failure alert and starts its own retry ladder" do
    ctx = failed_override("superseded-create")
    first_action = ctx.revised.active_action_id
    assert_receive {:create_post, ^first_action}, 2_000
    assert_receive {:corrective_alert, topic, _message, _opts}, 2_000
    await(ctx.store, ctx.decision.decision_id, &match?([%{failure: %{attempts: 1}}], &1.overrides))
    {:ok, %{decision: revised}} = DecisionStore.override(ctx.decision.decision_id, payload("red"), ctx.actor ++ [override_context: ctx.context], ctx.store)
    second_action = revised.active_action_id
    resolved = topic <> ".resolved"
    assert_receive {:corrective_alert, ^resolved, _message, opts}, 2_000
    refute opts[:needs_attention]
    assert opts[:reason] =~ "superseded"
    assert_receive {:create_post, ^second_action}, 2_000
    updated = await(ctx.store, ctx.decision.decision_id, &match?([%{failure: nil}, %{failure: %{attempts: 1}}], &1.overrides))
    assert [%{state: :superseded, failure: nil}, %{state: :failed, failure: %{attempts: 1}}] = updated.overrides
    send(ctx.store, :reconcile_corrective_overrides)
    assert {:ok, _decision} = DecisionStore.get(ctx.decision.decision_id, ctx.store)
    refute_receive {:corrective_alert, ^resolved, _message, _opts}, 20
    refute_receive {:create_post, ^second_action}, 20
  end

  test "transient failures alert after three passes and cap the retry interval" do
    now = DateTime.utc_now()
    first = CorrectiveFailures.build(%{action_id: "action"}, :outcome_unknown, now)
    refute first.alerted
    second = CorrectiveFailures.build(%{action_id: "action", failure: first}, :outcome_unknown, now)
    refute second.alerted
    third = CorrectiveFailures.build(%{action_id: "action", failure: second}, :outcome_unknown, now)
    assert third.alerted
    assert third.attempts == 3
    assert DateTime.diff(third.retry_at, now) == 240
    capped = CorrectiveFailures.build(%{action_id: "action", failure: %{attempts: 100}}, :outcome_unknown, now)
    assert DateTime.diff(capped.retry_at, now) == 3_600
  end

  defp failed_override(source_id) do
    dir = Aiur.TestSupport.tmp_root!("corrective-override-failure")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    now = DateTime.utc_now()
    clock = start_supervised!({Agent, fn -> now end})
    outcome = start_supervised!(Supervisor.child_spec({Agent, fn -> {:error, {:github, :http, %{status: 422}}} end}, id: :outcome))
    owner = self()
    :ok = DecisionPubSub.subscribe()

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      corrective_override_now: fn -> Agent.get(clock, & &1) end,
      corrective_override_alert: fn topic, message, alert_opts ->
        send(owner, {:corrective_alert, topic, message, alert_opts})
        :ok
      end,
      corrective_override_reconciler: fn command, record ->
        CorrectiveTicket.reconcile(command, record,
          pull_request: fn _ -> {:ok, %{number: 60, merged?: true, merge_commit_sha: "original-merge"}} end,
          find: fn _, _ -> {:ok, nil} end,
          issues: fn _ -> {:ok, [%Aiur.Issue{labels: []}]} end,
          create: fn _, _ ->
            send(owner, {:create_post, record.action_id})
            Agent.get(outcome, & &1)
          end,
          comments: fn _ -> {:ok, []} end,
          comment: fn _, _ -> :ok end
        )
      end
    ]

    store = start_supervised!({DecisionStore, opts})
    request_opts = [ticket: %{identifier: "50", title: "Original", url: nil}, source: %{agent_id: "worker", session_id: "session"}]
    {:ok, %{decision: decision}} = DecisionStore.request(%{source_id: source_id, question: "Which colour?", blocking: false}, request_opts, store)
    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, _answer} = DecisionStore.answer(decision.decision_id, payload("blue"), actor, store)
    context = %{pr: %{number: 60, merged?: true, merge_commit_sha: "original-merge"}, worker: :unknown, capacity: :full}
    {:ok, %{decision: revised}} = DecisionStore.override(decision.decision_id, payload("green"), actor ++ [override_context: context], store)
    %{store: store, opts: opts, decision: decision, revised: revised, clock: clock, outcome: outcome, now: now, actor: actor, context: context}
  end

  defp await(store, id, predicate) do
    {:ok, decision} = DecisionStore.get(id, store)

    if predicate.(decision) do
      decision
    else
      assert_receive {:decision_changed, ^id, _version}, 2_000
      await(store, id, predicate)
    end
  end

  defp payload(token), do: %{expected_version: 1, custom_response: token, rationale: "Changed direction", idempotency_key: token}
end
