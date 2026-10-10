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
    Aiur.TestSupport.put_runtime_state_dir!(Path.join(tmp_dir, "runtime-state"))

    Publisher.set_tracked_fn(fn _ -> true end)

    identifier = "delivery-#{System.unique_integer([:positive])}"

    test_pid = self()

    SubscriptionStore.set_enqueue_fn(fn id, event ->
      # The hook is global; unrelated stores can outlive their originating test.
      if id == identifier, do: send(test_pid, {:enqueued, id, event})
      :ok
    end)

    on_exit(fn ->
      SubscriptionStore.stop(identifier)
      SubscriptionStore.set_enqueue_fn(nil)
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
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.#"
      ticket_topic1 = "ticket.#{ticket}.branch.push"
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, ticket_topic, "test")

      Publisher.publish(
        ticket_topic1,
        %{sha: "abc", ref: "refs/heads/aiur/#{ticket}"},
        issue_number: String.to_integer(ticket)
      )

      SubscriptionStore.snapshot(id)
      assert_received {:enqueued, ^id, %{topic: ^ticket_topic1, sha: "abc"}}
    end

    test "event published to a non-matching pattern does NOT reach enqueue_fn",
         %{identifier: id} do
      ticket = System.unique_integer([:positive])
      :ok = SubscriptionStore.attach(id)
      :ok = SubscriptionStore.add_subscription(id, "ticket.#{ticket}.agent.#", "test")

      assert {:ok, _, _} = Publisher.publish("ticket.#{ticket}.branch.push", %{sha: "abc"})

      assert %{last_seen_event_id: nil} = SubscriptionStore.snapshot(id)
      refute_received {:enqueued, ^id, _}
    end

    test "enqueue observations exclude base-branch alerts delivered to other stores",
         %{identifier: id} do
      other_id = "#{id}-other"
      on_exit(fn -> SubscriptionStore.stop(other_id) end)
      :ok = SubscriptionStore.attach(other_id)
      :ok = SubscriptionStore.add_subscription(other_id, "system.config.base_branch.changed", "test")

      {:ok, event_id, _} =
        Publisher.publish("system.config.base_branch.changed", %{old_base: "integration", new_base: "main"})

      assert %{last_seen_event_id: ^event_id} = SubscriptionStore.snapshot(other_id)
      refute_received {:enqueued, ^other_id, _}
    end
  end
end
