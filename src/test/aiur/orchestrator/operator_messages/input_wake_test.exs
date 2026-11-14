defmodule Aiur.Orchestrator.OperatorMessages.InputWakeTest do
  # Open-Games #780: an answered Command, and an `aiur message`, sat queued for a
  # ticket that could never take a turn (ci-wait, human-review, or an in-progress
  # claim whose worker had exited) until the Executor relabelled it by hand.
  use Aiur.TestSupport

  import Aiur.OrchestratorLifecycleSupport

  alias Aiur.Orchestrator.OperatorMessages

  defp answer(decision_id),
    do: %{action_id: "act-#{decision_id}", correlation: %{action_id: "act-#{decision_id}", decision_id: decision_id}}

  defp tracker_state(id), do: Enum.find(Application.get_env(:aiur, :memory_tracker_issues), &(&1.id == id)).state

  test "a Command answer on a ci-wait ticket moves it to rework and stays queued for the next worker" do
    memory_tracker!([%Issue{id: "780", identifier: "780", state: "ci-wait", title: "Settings panel"}])

    assert {{:ok, %{item: item}}, state} =
             OperatorMessages.enqueue_operator_message(base_state(), "780", "Use option B: keep the toggle", answer("dec_a1"), :correlated)

    assert_receive {:memory_tracker_state_update, "780", "rework"}
    assert tracker_state("780") == "rework"
    # The worker the dispatcher starts for rework reads the answer first.
    assert {_store, claimed} = Aiur.AgentQueueStore.claim_next_deliverable(state.queue_store, "780")
    assert claimed.id == item.id
    assert claimed.body.text == "Use option B: keep the toggle"
  end

  test "an Executor message wakes a human-review ticket and an orphaned in-progress claim" do
    memory_tracker!([
      %Issue{id: "321", identifier: "321", state: "human-review", title: "Logo"},
      %Issue{id: "366", identifier: "366", state: "in-progress", title: "Pop"}
    ])

    for id <- ["321", "366"] do
      assert {{:ok, _item_id}, _state} = OperatorMessages.enqueue_operator_message(base_state(), id, "Address the splash", %{origin: :executor_cli})
      assert_receive {:memory_tracker_state_update, ^id, "rework"}
    end
  end

  test "input leaves a live worker, an active ticket and internal notes alone, and wakes a ticket once" do
    memory_tracker!([
      %Issue{id: "400", identifier: "400", state: "in-progress", title: "Live"},
      %Issue{id: "401", identifier: "401", state: "todo", title: "Todo"},
      %Issue{id: "402", identifier: "402", state: "human-review", title: "Review"}
    ])

    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(worker, :kill) end)
    live = running_entry("400", "400", :working) |> Map.put(:pid, worker)
    state = base_state(running: %{"400" => live}, claimed: MapSet.new(["400"]))

    assert {{:ok, _}, _} = OperatorMessages.enqueue_operator_message(state, "400", "steer", %{origin: :executor_cli})
    assert {{:ok, _}, _} = OperatorMessages.enqueue_operator_message(base_state(), "401", "note", %{origin: :executor_cli})
    assert {{:ok, _}, _} = OperatorMessages.enqueue_operator_message(base_state(), "402", "digest", %{origin: :internal})
    refute_receive {:memory_tracker_state_update, _id, _state}, 100

    assert {{:ok, _}, _} = OperatorMessages.enqueue_operator_message(base_state(), "402", "first", %{origin: :executor_cli})
    assert_receive {:memory_tracker_state_update, "402", "rework"}
    assert {{:ok, _}, _} = OperatorMessages.enqueue_operator_message(base_state(), "402", "second", answer("dec_a2"), :correlated)
    refute_receive {:memory_tracker_state_update, "402", _state}, 100
  end
end
