defmodule Aiur.Events.EventDeliveryTest do
  @moduledoc """
  End-to-end: SubscriptionStore receives an event via Exchange, hands
  it off to the enqueue function, which (in production) lands the event
  in the AgentRunner's coordination_event queue.

  Verifies the round-trip Inbox-equivalent path without requiring the
  full orchestrator + agent runner be up.
  """

  use ExUnit.Case, async: false

  alias Aiur.Events.{Publisher, SubscriptionStore}

  setup do
    tmp_dir = Aiur.TestSupport.tmp_root!("aiur_delivery_test")
    File.mkdir_p!(tmp_dir)
    original = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))

    Publisher.set_tracked_fn(fn _ -> true end)

    identifier = "delivery-#{System.unique_integer([:positive])}"

    test_pid = self()

    SubscriptionStore.set_enqueue_fn(fn id, event ->
      send(test_pid, {:enqueued, id, event})
      :ok
    end)

    on_exit(fn ->
      SubscriptionStore.set_enqueue_fn(nil)
      SubscriptionStore.stop(identifier)
      Publisher.set_tracked_fn(fn _ -> true end)

      if original do
        Application.put_env(:aiur, :log_file, original)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf!(tmp_dir)
    end)

    %{identifier: identifier}
  end

  describe "SubscriptionStore receives + enqueues" do
    test "event published to a subscribed pattern reaches enqueue_fn", %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.42.#", "test")

      Process.sleep(50)

      Publisher.publish(
        "ticket.42.branch.push",
        %{sha: "abc", ref: "refs/heads/aiur/42"},
        issue_number: 42
      )

      assert_receive {:enqueued, ^id, %{topic: "ticket.42.branch.push", sha: "abc"}}, 1_000
    end

    test "event published to a non-matching pattern does NOT reach enqueue_fn",
         %{identifier: id} do
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.999.#", "test")

      Process.sleep(50)

      Publisher.publish("ticket.42.branch.push", %{sha: "abc"})

      refute_receive {:enqueued, _, _}, 200
    end
  end
end
