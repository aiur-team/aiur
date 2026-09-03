defmodule Aiur.Orchestrator.AutoSubscriptionsTest do
  # async: false — set_add_subscription_fn writes to node-global persistent_term
  use ExUnit.Case, async: false

  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.AutoSubscriptions

  setup do
    :ok = Aiur.TestSupport.ensure_subscription_store_supervisor_running()
  end

  test "declared blockers receive the reserved force-push subscription" do
    blockee = "blockee-#{System.unique_integer([:positive])}"
    blocker = "blocker-#{System.unique_integer([:positive])}"

    :ok = AutoSubscriptions.subscribe_for_declared_blocker(blockee, blocker)
    on_exit(fn -> SubscriptionStore.stop(blockee) end)
    on_exit(fn -> SubscriptionStore.stop(blocker) end)

    topics = blockee |> SubscriptionStore.snapshot() |> Map.fetch!(:subscribed_to) |> Enum.map(& &1["topic"])

    assert "ticket.#{blocker}.branch.push" in topics
    assert "ticket.#{blocker}.branch.force-push" in topics
  end

  test "declared blocker subscriptions can be removed idempotently" do
    blockee = "blockee-#{System.unique_integer([:positive])}"
    blocker = "blocker-#{System.unique_integer([:positive])}"

    :ok = AutoSubscriptions.subscribe_for_declared_blocker(blockee, blocker)
    on_exit(fn -> SubscriptionStore.stop(blockee) end)
    on_exit(fn -> SubscriptionStore.stop(blocker) end)

    assert :ok = AutoSubscriptions.unsubscribe_for_declared_blocker(blockee, blocker)
    assert :ok = AutoSubscriptions.unsubscribe_for_declared_blocker(blockee, blocker)

    blockee_topics = blockee |> SubscriptionStore.snapshot() |> Map.fetch!(:subscribed_to)
    blocker_topics = blocker |> SubscriptionStore.snapshot() |> Map.fetch!(:subscribed_to)
    refute Enum.any?(blockee_topics, &(&1["reason"] == "blocker:auto"))
    refute Enum.any?(blocker_topics, &(&1["reason"] == "blockee:auto"))
  end

  describe "auto_subscribe_for_dependency failure injection" do
    setup do
      on_exit(fn -> AutoSubscriptions.set_add_subscription_fn(nil) end)
      :ok
    end

    test "returns {:error, _} when add_subscription fails for any topic" do
      blockee_id = "blockee-#{System.unique_integer([:positive])}"
      blocker_id = "blocker-#{System.unique_integer([:positive])}"
      blockee = %Issue{identifier: blockee_id}
      blocker = %{"identifier" => blocker_id}

      # Inject a failing add_subscription — simulates GenServer exit or store rejection
      AutoSubscriptions.set_add_subscription_fn(fn _id, _topic, _reason ->
        {:error, :simulated_store_failure}
      end)

      assert {:error, _} = AutoSubscriptions.auto_subscribe_for_dependency(blockee, blocker)
    end

    test "no subscriptions are recorded when add_subscription fails" do
      blockee_id = "blockee-#{System.unique_integer([:positive])}"
      blocker_id = "blocker-#{System.unique_integer([:positive])}"
      blockee = %Issue{identifier: blockee_id}
      blocker = %{"identifier" => blocker_id}

      # Attach the stores first so snapshots work, then override the add fn
      :ok = SubscriptionStore.attach(blockee_id)
      :ok = SubscriptionStore.attach(blocker_id)
      on_exit(fn -> SubscriptionStore.stop(blockee_id) end)
      on_exit(fn -> SubscriptionStore.stop(blocker_id) end)

      AutoSubscriptions.set_add_subscription_fn(fn _id, _topic, _reason ->
        {:error, :simulated_store_failure}
      end)

      {:error, _} = AutoSubscriptions.auto_subscribe_for_dependency(blockee, blocker)

      blockee_topics = blockee_id |> SubscriptionStore.snapshot() |> Map.fetch!(:subscribed_to)
      assert blockee_topics == []
    end
  end

  describe "auto_unsubscribe_for_dependency failure injection" do
    setup do
      on_exit(fn -> AutoSubscriptions.set_remove_subscription_fn(nil) end)
      :ok
    end

    test "returns {:error, _} when remove_subscription fails" do
      blockee_id = "blockee-#{System.unique_integer([:positive])}"
      blocker_id = "blocker-#{System.unique_integer([:positive])}"
      blockee = %Issue{identifier: blockee_id}
      blocker = %{"identifier" => blocker_id}

      :ok = AutoSubscriptions.auto_subscribe_for_dependency(blockee, blocker)
      on_exit(fn -> SubscriptionStore.stop(blockee_id) end)
      on_exit(fn -> SubscriptionStore.stop(blocker_id) end)

      AutoSubscriptions.set_remove_subscription_fn(fn _id, _topic, _reason ->
        {:error, :simulated_remove_failure}
      end)

      assert {:error, _} = AutoSubscriptions.auto_unsubscribe_for_dependency(blockee, blocker)
    end

    test "subscriptions remain when remove_subscription fails" do
      blockee_id = "blockee-#{System.unique_integer([:positive])}"
      blocker_id = "blocker-#{System.unique_integer([:positive])}"
      blockee = %Issue{identifier: blockee_id}
      blocker = %{"identifier" => blocker_id}

      :ok = AutoSubscriptions.auto_subscribe_for_dependency(blockee, blocker)
      on_exit(fn -> SubscriptionStore.stop(blockee_id) end)
      on_exit(fn -> SubscriptionStore.stop(blocker_id) end)

      AutoSubscriptions.set_remove_subscription_fn(fn _id, _topic, _reason ->
        {:error, :simulated_remove_failure}
      end)

      {:error, _} = AutoSubscriptions.auto_unsubscribe_for_dependency(blockee, blocker)

      blockee_topics =
        blockee_id |> SubscriptionStore.snapshot() |> Map.fetch!(:subscribed_to) |> Enum.map(& &1["topic"])

      assert "ticket.#{blocker_id}.agent.unblocked" in blockee_topics
    end
  end

  describe "auto_subscribe_for_dependency" do
    test "returns :ok and registers subscriptions on both sides" do
      blockee_id = "blockee-#{System.unique_integer([:positive])}"
      blocker_id = "blocker-#{System.unique_integer([:positive])}"
      blockee = %Issue{identifier: blockee_id}
      blocker = %{"identifier" => blocker_id}

      assert :ok = AutoSubscriptions.auto_subscribe_for_dependency(blockee, blocker)

      on_exit(fn -> SubscriptionStore.stop(blockee_id) end)
      on_exit(fn -> SubscriptionStore.stop(blocker_id) end)

      blockee_topics =
        blockee_id |> SubscriptionStore.snapshot() |> Map.fetch!(:subscribed_to) |> Enum.map(& &1["topic"])

      blocker_topics =
        blocker_id |> SubscriptionStore.snapshot() |> Map.fetch!(:subscribed_to) |> Enum.map(& &1["topic"])

      # Blockee subscribes to the blocker's events.
      assert "ticket.#{blocker_id}.agent.unblocked" in blockee_topics
      assert "ticket.#{blocker_id}.branch.push" in blockee_topics

      # Blocker subscribes to blockee's block-state events.
      assert "ticket.#{blockee_id}.agent.blocked" in blocker_topics
      assert "ticket.#{blockee_id}.agent.unblocked" in blocker_topics
    end

    test "returns :ok when blockee or blocker has no binary identifier (no-op)" do
      assert :ok = AutoSubscriptions.auto_subscribe_for_dependency(%Issue{identifier: nil}, %{"identifier" => "blocker"})
      assert :ok = AutoSubscriptions.auto_subscribe_for_dependency(%Issue{identifier: "blockee"}, %{})
    end
  end
end
