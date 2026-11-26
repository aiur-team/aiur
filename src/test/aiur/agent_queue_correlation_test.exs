defmodule Aiur.AgentQueue.CorrelationTest do
  use ExUnit.Case, async: true
  @moduletag :r7_characterization

  alias Aiur.AgentQueue
  alias Aiur.AgentQueueStore

  describe "correlated operator-message idempotency" do
    test "a fresh action produces one pending item with structured correlation" do
      assert {:ok, store, item, :accepted} =
               AgentQueueStore.enqueue_correlated(AgentQueueStore.new(), correlated_message())

      assert item.action_id == "act_123"
      assert item.correlation == decision_correlation()
      assert item.body == %{text: "Ship the approved option"}
      assert AgentQueueStore.find_by_action(store, "act_123").id == item.id
    end

    test "exact replay returns the same item in every queue state" do
      attrs = correlated_message()
      assert {:ok, pending_store, pending, :accepted} = AgentQueueStore.enqueue_correlated(AgentQueueStore.new(), attrs)
      assert_same_correlated_item(pending_store, attrs, pending)

      {delivered_store, delivered} = AgentQueueStore.claim_next_deliverable(pending_store, "MT-981")
      assert_same_correlated_item(delivered_store, attrs, delivered)

      {consumed_store, consumed} = AgentQueueStore.mark_consumed(delivered_store, delivered.id)
      assert_same_correlated_item(consumed_store, attrs, consumed)

      {failed_store, failed} = AgentQueueStore.mark_failed(delivered_store, delivered.id, :turn_failed)
      assert_same_correlated_item(failed_store, attrs, failed)

      {superseded_store, superseded} = AgentQueueStore.mark_superseded(pending_store, pending.id)
      assert_same_correlated_item(superseded_store, attrs, superseded)
    end

    test "same action with changed target, body, version, or actor conflicts without mutation" do
      attrs = correlated_message()
      assert {:ok, store, item, :accepted} = AgentQueueStore.enqueue_correlated(AgentQueueStore.new(), attrs)

      conflicts = [
        correlated_message("Different answer"),
        correlated_message("Ship the approved option", target: "MT-OTHER"),
        correlated_message("Ship the approved option", correlation: decision_correlation(%{decision_version: 3})),
        correlated_message(
          "Ship the approved option",
          correlation: decision_correlation(%{actor: %{kind: :operator, id: "operator-2"}})
        )
      ]

      for conflicting <- conflicts do
        assert {:error, {:idempotency_conflict, "act_123"}} =
                 AgentQueueStore.enqueue_correlated(store, conflicting)

        assert AgentQueueStore.find_by_action(store, "act_123") == item
      end
    end

    test "an explicit failed retry restores the original item exactly once" do
      attrs = correlated_message()
      assert {:ok, store, item, :accepted} = AgentQueueStore.enqueue_correlated(AgentQueueStore.new(), attrs)
      {store, _delivered} = AgentQueueStore.claim_next_deliverable(store, "MT-981")
      {store, failed} = AgentQueueStore.mark_failed(store, item.id, :agent_unavailable)
      assert failed.status == :failed

      retry_attrs =
        correlated_message("Ship the approved option",
          correlation: decision_correlation(%{attempt_id: "act_123:2"})
        )

      assert {:ok, retried_store, retried, :retried} =
               AgentQueueStore.enqueue_correlated(store, retry_attrs, retry_failed: true)

      assert retried.id == item.id
      assert retried.status == :pending
      assert retried.failed_at == nil
      assert retried.failure_reason == nil
      assert retried.delivery_attempts == 0
      assert retried.correlation.attempt_id == "act_123:1"
      assert [%{id: id}] = AgentQueueStore.list_pending(retried_store, "MT-981")
      assert id == item.id

      assert {:ok, ^retried_store, duplicate, :duplicate} =
               AgentQueueStore.enqueue_correlated(retried_store, retry_attrs, retry_failed: true)

      assert duplicate.id == item.id
    end

    test "a fresh queue lifetime accepts the same durable action as a new attempt" do
      attrs = correlated_message()
      assert {:ok, _first_store, first, :accepted} = AgentQueueStore.enqueue_correlated(AgentQueueStore.new(), attrs)
      assert {:ok, _second_store, second, :accepted} = AgentQueueStore.enqueue_correlated(AgentQueueStore.new(), attrs)

      assert first.id == 1
      assert second.id == 1
      assert first.action_id == second.action_id
    end
  end

  defp decision_correlation(overrides \\ %{}) do
    Map.merge(
      %{
        decision_id: "dec_123",
        decision_version: 2,
        action_id: "act_123",
        attempt_id: "act_123:1",
        actor: %{kind: :operator, id: "operator-1"}
      },
      overrides
    )
  end

  defp correlated_message(text \\ "Ship the approved option", overrides \\ []) do
    correlation = Keyword.get(overrides, :correlation, decision_correlation())
    action_id = Keyword.get(overrides, :action_id, correlation.action_id)

    AgentQueue.operator_message(
      Keyword.get(overrides, :target, "MT-981"),
      text,
      action_id: action_id,
      correlation: correlation
    )
  end

  defp assert_same_correlated_item(store, attrs, expected) do
    assert {:ok, ^store, replayed, :duplicate} = AgentQueueStore.enqueue_correlated(store, attrs)
    assert replayed.id == expected.id
    assert replayed.status == expected.status
  end
end
