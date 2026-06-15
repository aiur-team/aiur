defmodule Aiur.OrchestratorAutoSubscribeTest do
  @moduledoc """
  Asymmetric auto-subscribe: when the orchestrator's poll observes a `blocked_by` change,
  asymmetric auto-subscriptions are added (added blocker -> blockee gets
  default subset, blocker gets blockee's block-state) or removed
  (removed blocker tears down the auto-added entries scoped by reason).

  Direct unit test against the default-subset helpers + SubscriptionStore
  interaction is hard without spinning the orchestrator GenServer + the
  whole supervision tree. We test the topic-list generators here; the
  add/remove side effects are exercised in integration.
  """

  use ExUnit.Case, async: true

  alias Aiur.Events.SubscriptionStore

  describe "SubscriptionStore.add_subscription/3 (first-write-wins reason)" do
    setup do
      identifier = unique_identifier("test-fww")
      :ok = SubscriptionStore.attach(identifier)
      on_exit(fn -> :ok = SubscriptionStore.stop(identifier) end)
      %{identifier: identifier}
    end

    test "second add for same topic does NOT overwrite reason", %{identifier: id} do
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.branch.push", "manual:agent")
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.branch.push", "blocker:auto")

      [entry] = SubscriptionStore.snapshot(id).subscribed_to
      assert entry["reason"] == "manual:agent"
    end

    test "auto-sub-then-manual leaves reason as auto so reason-filtered remove drops it", %{identifier: id} do
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.branch.push", "blocker:auto")
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.branch.push", "manual:agent")

      [entry] = SubscriptionStore.snapshot(id).subscribed_to
      assert entry["reason"] == "blocker:auto"

      :ok = SubscriptionStore.remove_subscription(id, "ticket.42.branch.push", "blocker:auto")
      assert SubscriptionStore.snapshot(id).subscribed_to == []
    end
  end

  describe "SubscriptionStore.remove_subscription/3 (reason filter)" do
    setup do
      identifier = unique_identifier("test-rsa")
      :ok = SubscriptionStore.attach(identifier)
      on_exit(fn -> :ok = SubscriptionStore.stop(identifier) end)
      %{identifier: identifier}
    end

    test "only removes when reason matches", %{identifier: id} do
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.branch.push", "manual:agent")

      :ok = SubscriptionStore.remove_subscription(id, "ticket.42.branch.push", "blocker:auto")
      assert_subscribed?(id, "ticket.42.branch.push", true)

      :ok = SubscriptionStore.remove_subscription(id, "ticket.42.branch.push", "manual:agent")
      assert_subscribed?(id, "ticket.42.branch.push", false)
    end

    test "no-op when topic not subscribed", %{identifier: id} do
      :ok = SubscriptionStore.remove_subscription(id, "ticket.404.branch.push", "blocker:auto")
      assert SubscriptionStore.snapshot(id).subscribed_to == []
    end

    test "leaves other-topic subscriptions intact", %{identifier: id} do
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.branch.push", "blocker:auto")
      :ok = SubscriptionStore.add_subscription(id, "ticket.99.pr.merged", "manual:agent")

      :ok = SubscriptionStore.remove_subscription(id, "ticket.42.branch.push", "blocker:auto")

      topics = id |> SubscriptionStore.snapshot() |> Map.fetch!(:subscribed_to) |> Enum.map(& &1["topic"])
      assert topics == ["ticket.99.pr.merged"]
    end
  end

  defp assert_subscribed?(identifier, topic, expected) do
    topics = identifier |> SubscriptionStore.snapshot() |> Map.fetch!(:subscribed_to) |> Enum.map(& &1["topic"])
    assert topic in topics == expected
  end

  defp unique_identifier(prefix) do
    unique = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{System.system_time(:nanosecond)}-#{unique}"
  end
end
