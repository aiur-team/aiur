defmodule Aiur.Opencode.AttachPoolTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.AttachPool

  describe "free_slots_for/2 — surplus-slot reclamation (#372)" do
    test "all idle slots are free (boot, nothing painted yet)" do
      slot_vids = [{1, nil}, {2, nil}, {3, nil}]

      assert AttachPool.free_slots_for(slot_vids, ["a"]) == [1, 2, 3]
    end

    test "one distinct active agent per slot leaves no free slots (full capacity)" do
      slot_vids = [{1, "a"}, {2, "b"}, {3, "c"}]

      assert AttachPool.free_slots_for(slot_vids, ["a", "b", "c"]) == []
    end

    test "a duplicate leadoff frees the surplus slots so a post-boot agent can claim one" do
      # The #372 repro: 1 boot agent, N pre-warmed slots. kickoff_fan_out
      # (rotational, n=1) paints "a" as the leadoff on EVERY slot. Without
      # reclamation every slot counts as claimed and the post-boot agent is
      # stranded at ⏳. Each active id needs only ONE slot; the surplus
      # duplicates must be reclaimable.
      slot_vids = [{1, "a"}, {2, "a"}, {3, "a"}]

      assert AttachPool.free_slots_for(slot_vids, ["a"]) == [2, 3]
    end

    test "keeps one primary per active id and frees only the duplicates" do
      slot_vids = [{1, "a"}, {2, "a"}, {3, "b"}]

      # "a" keeps its primary (lowest-index) slot 1; its duplicate slot 2 is
      # free. "b"'s only slot is its primary and stays claimed.
      assert AttachPool.free_slots_for(slot_vids, ["a", "b"]) == [2]
    end

    test "a slot showing a now-inactive identifier is free" do
      slot_vids = [{1, "a"}, {2, "x"}]

      # "x" left the active set; slot 2 is reclaimable. "a" keeps slot 1.
      assert AttachPool.free_slots_for(slot_vids, ["a"]) == [2]
    end

    test "no slots, no free slots" do
      assert AttachPool.free_slots_for([], ["a"]) == []
    end

    test "keeps the LOWEST-index slot as the primary regardless of input order" do
      # Pins the internal sort: the primary an active id retains must be
      # its lowest-index slot, even when slot_vids arrives unordered.
      slot_vids = [{3, "a"}, {1, "a"}, {2, "a"}]

      assert AttachPool.free_slots_for(slot_vids, ["a"]) == [2, 3]
    end
  end
end
