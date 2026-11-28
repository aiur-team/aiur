defmodule Aiur.DecisionDispatchRedispatchTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator.OperatorMessages.EnqueueNextWorker

  test "re-dispatches an idle ticket when a correlated answer is queued for its next worker" do
    dir = Aiur.TestSupport.tmp_root!("optional-answer-redispatch")
    previous = Application.get_env(:aiur, :pending_operator_messages_store_path)
    Application.put_env(:aiur, :pending_operator_messages_store_path, Path.join(dir, "pending.json"))

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:aiur, :pending_operator_messages_store_path)
        value -> Application.put_env(:aiur, :pending_operator_messages_store_path, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    state = %Aiur.Orchestrator.State{queue_store: Aiur.AgentQueueStore.new(), running: %{}}

    request = %{
      origin: :decision,
      actor: "executor",
      turn_id: nil,
      action_id: "answer-action",
      correlation: %{decision_id: "decision-1"},
      mode: :correlated
    }

    enqueue_plain = fn store, attrs, _request ->
      {next_store, item} = Aiur.AgentQueueStore.enqueue(store, attrs)
      {:ok, next_store, item, :accepted}
    end

    assert {{:ok, %{status: :accepted}}, next_state} =
             EnqueueNextWorker.enqueue(state, "979", "Answer", request, enqueue_plain, fn _item -> :ok end, [])

    assert next_state.queued_demand_hints["979"] == 2
  end
end
