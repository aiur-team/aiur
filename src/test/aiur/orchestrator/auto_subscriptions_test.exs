defmodule Aiur.Orchestrator.AutoSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator.AutoSubscriptions

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
end
