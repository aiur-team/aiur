defmodule Aiur.DecisionOverrideSubscriptionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.{DecisionStore, DecisionStore.OverridePushes}

  @exchange Module.concat(__MODULE__, MissingExchange)
  @pr %{number: 77, merged?: false, head_sha: "before", head_ref: "work"}

  test "store starts without Exchange and periodic reconciliation implements a delivered override" do
    dir = Aiur.TestSupport.tmp_root!("override-missing-exchange")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    owner = self()
    assert Process.whereis(@exchange) == nil

    opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      override_push_exchange: @exchange,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      override_context_reader: fn "6908" ->
        send(owner, :reconciled_without_exchange)
        %{pr: %{@pr | head_sha: "after"} |> Map.put(:head_updated_at, DateTime.add(DateTime.utc_now(), 1, :second))}
      end
    ]

    log =
      capture_log(fn ->
        store = start_supervised!({DecisionStore, opts})
        send(owner, {:started_store, store})
      end)

    assert log =~ "phase=override_push_subscription_failed"
    assert log =~ "noproc"
    assert_receive {:started_store, store}, 1_000

    assert {:ok, %{decision: requested}} =
             DecisionStore.request(
               %{source_id: "subscription-fallback", question: "Proceed?", blocking: false},
               [ticket: %{identifier: "6908"}, source: %{agent_id: "worker", session_id: "session"}],
               store
             )

    assert {:ok, %{decision: answered}} = DecisionStore.answer(requested.decision_id, payload("original"), [actor: %{kind: :operator, id: "human"}], store)
    deliver(store, answered)

    assert {:ok, %{decision: revised}} =
             DecisionStore.override(answered.decision_id, payload("override"), [actor: %{kind: :operator, id: "human"}, override_context: %{pr: @pr, worker: :active, capacity: :full}], store)

    deliver(store, revised)
    assert {:ok, %{overrides: [%{state: :delivered}]}} = DecisionStore.get(revised.decision_id, store)

    # Drive the real periodic message without a thirty-second wall-clock delay.
    state = :sys.get_state(store)
    Process.cancel_timer(state.override_reconcile_timer)
    send(store, :reconcile_override_pushes)
    assert_receive :reconciled_without_exchange, 2_000

    Aiur.DispatcherTestSupport.wait_until(fn ->
      {:ok, decision} = DecisionStore.get(revised.decision_id, store)
      match?([%{state: :implemented, evidence: %{head_sha: "after", pr_number: 77}}], decision.overrides)
    end)

    assert {:ok, implemented} = DecisionStore.get(revised.decision_id, store)
    assert [%{state: :implemented, evidence: %{head_sha: "after", pr_number: 77}}] = implemented.overrides
    timer = :sys.get_state(store).override_reconcile_timer
    assert Process.read_timer(timer) in 1..30_000
    assert Process.whereis(@exchange) == nil
  end

  test "missing subscription logs redact the failed exchange reference" do
    secret = "ghp_" <> String.duplicate("A", 36)
    log = capture_log(fn -> assert :ok = OverridePushes.subscribe({:global, secret}) end)
    assert log =~ "phase=override_push_subscription_failed"
    assert log =~ "REDACTED"
    refute log =~ secret
  end

  defp deliver(store, decision) do
    item = %{
      id: decision.revision_sequence + 1,
      target_issue_identifier: "6908",
      action_id: decision.active_action_id,
      correlation: %{decision_id: decision.decision_id, decision_version: 1, action_id: decision.active_action_id, attempt_id: "attempt-#{decision.revision_sequence}"}
    }

    assert {:ok, :accepted} = DecisionStore.validate_delivery(item, store)
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)
  end

  defp payload(token), do: %{expected_version: 1, custom_response: token, rationale: "Changed direction", idempotency_key: token}
end
