defmodule Aiur.Opencode.SlotPolicyTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{Slot, SlotPolicy}

  # SlotPolicy interacts with SlotSupervisor and the real PubSub. The
  # unit-test goal here is to verify the chain-advancement logic via
  # PubSub messages without spinning up real Slot workers (which would
  # require opencode-serve + tmux).
  #
  # We bypass SlotSupervisor.start_slot by setting target_count=0 to
  # prove the skip path; for chain-advance behavior, integration
  # coverage happens in U14 manual CLI verification (real slots).

  describe "init/1 with target_count=0" do
    test "skips chain entirely" do
      {:ok, pid} = SlotPolicy.start_link(target_count: 0)
      # Give the :start_first_slot self-message time to be processed.
      Process.sleep(50)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "PubSub topic subscription" do
    test "subscribes to the Slot slots_topic" do
      # The policy subscribes at init. Verify by sending a message via
      # the same topic and confirming the policy handles it without
      # crashing.
      {:ok, pid} = SlotPolicy.start_link(target_count: 0)
      Process.sleep(20)

      # Broadcast a stale {:slot_ready, 99} — should be a no-op (above
      # target_count of 0) and not crash.
      Phoenix.PubSub.broadcast(Aiur.PubSub, Slot.slots_topic(), {:slot_ready, 99})
      Process.sleep(20)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "ignores :slot_session_changed events without crashing" do
      {:ok, pid} = SlotPolicy.start_link(target_count: 0)
      Process.sleep(20)

      Phoenix.PubSub.broadcast(
        Aiur.PubSub,
        Slot.slots_topic(),
        {:slot_session_changed, 1, "issue-42"}
      )

      Process.sleep(20)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
