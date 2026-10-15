defmodule Aiur.Orchestrator.IssueSync.DependencyTransitionsTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.AgentQueueStore
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator.AutoSubscriptions
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  describe "dependency transition event gating" do
    test "does not enqueue dependency_added when the auto-subscribe fails" do
      on_exit(fn -> AutoSubscriptions.set_add_subscription_fn(nil) end)

      issue_id = "sync-gating-#{System.unique_integer([:positive])}"
      blocker_id = "sync-blocker-#{System.unique_integer([:positive])}"
      identifier = "its-everdred/aiur##{issue_id}"
      blocker = %{id: blocker_id, identifier: blocker_id, state: "in-progress"}

      previous_issue = %{issue(issue_id, "in-progress") | blocked_by: []}
      current_issue = %{issue(issue_id, "in-progress") | blocked_by: [blocker]}
      on_exit(fn -> SubscriptionStore.stop(identifier) end)

      queue_store = AgentQueueStore.new()
      state = %State{last_polled_issues: %{issue_id => previous_issue}, queue_store: queue_store}

      # Force the subscribe step to fail: a dependency_added event must NOT be
      # enqueued behind a subscription that did not land (that is what leaves
      # a blockee never auto-resuming — the #1059 defect this gates).
      AutoSubscriptions.set_add_subscription_fn(fn _id, _topic, _reason ->
        {:error, :simulated_store_failure}
      end)

      result =
        IssueSync.sync_polled_issue_state(
          state,
          [current_issue],
          fn _ids -> {:ok, []} end,
          fn _identity, _lifecycle -> :ok end,
          MapSet.new(["done", "cancelled"]),
          fn _status -> :ok end,
          fn _identity, _pending? -> :ok end
        )

      dependency_items =
        result.queue_store.items
        |> Map.values()
        |> Enum.filter(&(&1.event_type == :dependency_added))

      assert dependency_items == []
      assert result.queue_store == queue_store
    end

    test "does not enqueue dependency_removed when the auto-unsubscribe fails" do
      on_exit(fn -> AutoSubscriptions.set_remove_subscription_fn(nil) end)

      issue_id = "sync-gating-rem-#{System.unique_integer([:positive])}"
      blocker_id = "sync-blocker-rem-#{System.unique_integer([:positive])}"
      identifier = "its-everdred/aiur##{issue_id}"
      blocker = %{id: blocker_id, identifier: blocker_id, state: "in-progress"}

      previous_issue = %{issue(issue_id, "in-progress") | blocked_by: [blocker]}
      current_issue = %{issue(issue_id, "in-progress") | blocked_by: []}
      on_exit(fn -> SubscriptionStore.stop(identifier) end)

      queue_store = AgentQueueStore.new()
      state = %State{last_polled_issues: %{issue_id => previous_issue}, queue_store: queue_store}

      AutoSubscriptions.set_remove_subscription_fn(fn _id, _topic, _reason ->
        {:error, :simulated_remove_failure}
      end)

      result =
        IssueSync.sync_polled_issue_state(
          state,
          [current_issue],
          fn _ids -> {:ok, []} end,
          fn _identity, _lifecycle -> :ok end,
          MapSet.new(["done", "cancelled"]),
          fn _status -> :ok end,
          fn _identity, _pending? -> :ok end
        )

      dependency_items =
        result.queue_store.items
        |> Map.values()
        |> Enum.filter(&(&1.event_type == :dependency_removed))

      assert dependency_items == []
      assert result.queue_store == queue_store
    end
  end
end
