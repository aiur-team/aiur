defmodule Aiur.Regression.SharedPrewarmE2ETest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{AttachPool, Slot, WarmthReport}

  setup do
    {:ok, pool} = AttachPool.start_link(name: :"AttachPool_#{System.unique_integer([:positive])}")
    Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())
    {:ok, pool: pool}
  end

  test "fan-out raises attach_count + flips marker thresholds", %{pool: pool} do
    AttachPool.seed(pool, ["issue-1", "issue-2", "issue-3"])
    Process.sleep(20)

    assert AttachPool.attach_count(pool, "issue-1") == 0

    Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
    assert_receive {:attach_state_changed, "issue-1", 1, nil}, 500

    assert AttachPool.attach_count(pool, "issue-1") == 1
    assert AttachPool.visible_count(pool) == 0

    Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_visible_changed, 1, "issue-1"})
    assert_receive {:attach_state_changed, "issue-1", _, 1}, 500

    assert AttachPool.visible_count(pool) == 1
  end

  test "agent leaving the active set drives detach + :agent_inactive", %{pool: pool} do
    AttachPool.seed(pool, ["issue-1", "issue-2"])
    Process.sleep(20)

    Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
    assert_receive {:attach_state_changed, "issue-1", 1, nil}, 500

    AttachPool.seed(pool, ["issue-2"])

    assert_receive {:agent_inactive, "issue-1"}, 500
  end

  test "find_slot_for prefers an unclaimed attached slot", %{pool: pool} do
    AttachPool.seed(pool, ["issue-1"])

    Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
    Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 2, "issue-1"})

    assert_receive {:attach_state_changed, "issue-1", 2, nil}, 500

    assert {:ok, 1} = AttachPool.find_slot_for(pool, "issue-1")
    assert {:ok, 2} = AttachPool.find_slot_for(pool, "issue-1", prefer: 2)
  end

  test "fully-warmed-slot transitions broadcast", %{pool: pool} do
    AttachPool.seed(pool, ["issue-1", "issue-2"])

    Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
    refute_receive {:slot_fully_warmed, 1}, 100

    Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-2"})
    assert_receive {:slot_fully_warmed, 1}, 500
  end

  test "warmth report computes loose→strict delta from broadcast events", %{pool: pool} do
    events = [
      %{phase: :slot_attach_added, identifier: "issue-1", slot: 1, at_ms: 100},
      %{phase: :slot_visible_changed, identifier: "issue-1", slot: 1, at_ms: 200},
      %{phase: :slot_attach_added, identifier: "issue-2", slot: 1, at_ms: 300},
      %{phase: :slot_attach_added, identifier: "issue-2", slot: 2, at_ms: 600}
    ]

    [_, issue_2] =
      events
      |> WarmthReport.from_events()
      |> Enum.sort_by(& &1.identifier)

    assert issue_2.identifier == "issue-2"
    assert issue_2.loose_to_strict_delta_ms == 300

    _ = pool
  end
end
