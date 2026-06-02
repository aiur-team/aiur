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

  test "fully-warmed-slot fires when slot has its leadoff attached", %{pool: pool} do
    # Under the leadoff-only pre-warm model, a slot is "fully warmed"
    # the moment ANY identifier is attached to it (its rotational
    # leadoff). The previous "every active identifier on every slot"
    # criterion produced 36 attaches at boot — replaced by single-
    # leadoff per slot. ⬜ now means "this slot has paint."
    AttachPool.seed(pool, ["issue-1", "issue-2"])

    Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
    assert_receive {:slot_fully_warmed, 1}, 500
  end

  describe "pause/resume → leadoff reassignment" do
    test "reassigns a freed leadoff slot when pause and resume arrive as separate do_seed calls", %{pool: pool} do
      # Seed 3 agents and paint a leadoff per slot (simulating boot).
      AttachPool.seed(pool, ["issue-1", "issue-2", "issue-3"])
      Process.sleep(20)

      for {slot, id} <- [{1, "issue-1"}, {2, "issue-2"}, {3, "issue-3"}] do
        Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, slot, id})
        Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_visible_changed, slot, id})
      end

      assert_receive {:attach_state_changed, "issue-3", _, 3}, 500

      Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Perf.topic())

      # First call: user pauses issue-2 (orchestrator drops it). No
      # added identifier yet — but Slot.detach should clear visible_in,
      # and the slot stays free for the next call.
      AttachPool.seed(pool, ["issue-1", "issue-3"])
      assert_receive {:agent_inactive, "issue-2"}, 500

      # Second call (separate event): user starts issue-4 (the queued
      # ticket). The slot freed by the previous call must now be
      # claimed by issue-4 — that's the user's reported scenario.
      AttachPool.seed(pool, ["issue-1", "issue-3", "issue-4"])

      assert_receive {:aiur_perf,
                      %{
                        phase: :seed_leadoff_reassignment,
                        meta: %{paired: 1, added_ids: ["issue-4"]}
                      }},
                     500
    end

    test "single do_seed with both added and removed still pairs", %{pool: pool} do
      AttachPool.seed(pool, ["issue-1", "issue-2"])
      Process.sleep(20)

      for {slot, id} <- [{1, "issue-1"}, {2, "issue-2"}] do
        Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, slot, id})
        Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_visible_changed, slot, id})
      end

      assert_receive {:attach_state_changed, "issue-2", _, 2}, 500

      Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Perf.topic())

      # Both pause AND resume in the same orchestrator broadcast.
      AttachPool.seed(pool, ["issue-1", "issue-3"])

      assert_receive {:aiur_perf,
                      %{
                        phase: :seed_leadoff_reassignment,
                        meta: %{paired: 1, added_ids: ["issue-3"]}
                      }},
                     500

      assert_receive {:agent_inactive, "issue-2"}, 500
    end

    test "no event when no free slot is available", %{pool: pool} do
      AttachPool.seed(pool, ["issue-1"])
      Process.sleep(20)

      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_attach_added, 1, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_visible_changed, 1, "issue-1"})

      assert_receive {:attach_state_changed, "issue-1", _, 1}, 500

      Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Perf.topic())

      # Adding issue-2 with no slots free (slot 1 is claimed by
      # issue-1). No reassignment event should fire.
      AttachPool.seed(pool, ["issue-1", "issue-2"])

      refute_receive {:aiur_perf, %{phase: :seed_leadoff_reassignment}}, 200
    end
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
