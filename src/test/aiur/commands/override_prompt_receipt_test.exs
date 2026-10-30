defmodule Aiur.Commands.OverridePromptReceiptTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.{Commands, DecisionStore}
  alias Aiur.Commands.OverridePrompt

  setup do
    dir = Aiur.TestSupport.tmp_root!("override-prompt-receipt")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    failures = :counters.new(1, [])

    store_opts = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      event_id_reserver: fn ->
        if :counters.get(failures, 1) == 1,
          do: {:error, :not_durable},
          else: Aiur.Events.reserve_durable_id()
      end
    ]

    store = start_supervised!({DecisionStore, store_opts})

    {:ok, %{decision: decision}} =
      Commands.request(
        %{question: "Which direction?", blocking: true, authority: :supervisor_allowed, reversibility: :reversible},
        [ticket: %{identifier: "6909"}, source: %{agent_id: "worker", session_id: "session"}],
        store
      )

    actor = [actor: %{kind: :operator, id: "human"}, actor_source: :dashboard_session]
    {:ok, %{decision: answered}} = Commands.answer(decision.decision_id, payload("answer", "Initial direction"), actor, store)
    context = %{pr: %{number: 77, merged?: false, head_sha: "before"}, worker: :resumable, capacity: :full}
    {:ok, %{decision: override}} = Commands.override(answered.decision_id, payload("override", "New direction"), Keyword.put(actor, :override_context, context), store)
    %{store: store, store_opts: store_opts, decision: override, failures: failures}
  end

  test "a rejected receipt logs and the next turn retries delivery", ctx do
    opts = OverridePrompt.prepare("6909", decision_store: ctx.store)
    :counters.put(ctx.failures, 1, 1)

    log = capture_log(fn -> assert :ok = OverridePrompt.received(%{event: :turn_started}, opts) end)
    assert log =~ "Override prompt receipt could not persist: command=#{ctx.decision.decision_id}"
    assert log =~ "not_durable"
    assert {:ok, %{overrides: [%{state: :queued, delivered_at: nil}]}} = DecisionStore.get(ctx.decision.decision_id, ctx.store)

    :counters.put(ctx.failures, 1, 0)
    assert_receipt_on_next_turn(ctx.store, ctx.decision)
  end

  test "an unavailable store does not crash the provider callback and a later turn retries", ctx do
    opts = OverridePrompt.prepare("6909", decision_store: ctx.store)
    assert :ok = stop_supervised(DecisionStore)

    log = capture_log(fn -> assert :ok = OverridePrompt.received(%{event: :turn_started}, opts) end)
    assert log =~ "Override prompt receipt could not persist: command=#{ctx.decision.decision_id}"
    assert log =~ "noproc"

    store = start_supervised!({DecisionStore, ctx.store_opts})
    assert {:ok, %{overrides: [%{state: :queued, delivered_at: nil}]}} = DecisionStore.get(ctx.decision.decision_id, store)
    assert_receipt_on_next_turn(store, ctx.decision)
  end

  defp assert_receipt_on_next_turn(store, decision) do
    opts = OverridePrompt.prepare("6909", decision_store: store)
    assert [pending] = opts[:pending_overrides]
    assert pending.active_action_id == decision.active_action_id
    assert :ok = OverridePrompt.received(%{event: :turn_started}, opts)
    assert {:ok, %{overrides: [%{state: :delivered, delivered_at: %DateTime{}}]}} = DecisionStore.get(decision.decision_id, store)
  end

  defp payload(key, text), do: %{expected_version: 1, idempotency_key: key, custom_response: text, rationale: "Changed direction"}
end
