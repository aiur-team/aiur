defmodule Aiur.Opencode.SlotPolicyTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.{Slot, SlotPolicy}

  # SlotPolicy interacts with SlotSupervisor and the real PubSub. The
  # unit-test goal here is to verify the lazy-expansion + bump logic
  # via PubSub messages and the public API without spinning up real
  # Slot workers (which would require opencode-serve + tmux).
  #
  # We bypass SlotSupervisor.start_slot by setting target_count=0 to
  # prove the skip path; for real chain advance behavior, integration
  # coverage happens in U11 e2e + manual CLI verification.

  describe "init/1 with target_count=0" do
    test "skips starting any slot" do
      {:ok, pid} = SlotPolicy.start_link(target_count: 0)
      Process.sleep(50)
      assert Process.alive?(pid)
      assert SlotPolicy.highest_started(pid) == 0
      assert SlotPolicy.target_count(pid) == 0
      GenServer.stop(pid)
    end
  end

  describe "PubSub topic subscription" do
    test "subscribes to the Slot slots_topic and tolerates noise" do
      {:ok, pid} = SlotPolicy.start_link(target_count: 0)
      Process.sleep(20)

      topic = Slot.slots_topic()
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:slot_ready, 99})
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:slot_session_changed, 1, "issue-42"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:slot_attach_added, 1, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:slot_attach_removed, 1, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:slot_visible_changed, 1, nil})

      Process.sleep(20)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "bump/0 with target_count=0" do
    test "is a safe no-op" do
      {:ok, pid} = SlotPolicy.start_link(target_count: 0)
      Process.sleep(20)
      assert :ok = SlotPolicy.bump(pid)
      Process.sleep(20)
      assert SlotPolicy.highest_started(pid) == 0
      GenServer.stop(pid)
    end

    test "tolerates a dead server pid" do
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(dead)

      assert :ok = SlotPolicy.bump(dead)
    end
  end

  describe "highest_started/0 + target_count/0 introspection" do
    test "report the configured target and starting highest of 0" do
      {:ok, pid} = SlotPolicy.start_link(target_count: 0)
      Process.sleep(20)
      assert SlotPolicy.target_count(pid) == 0
      assert SlotPolicy.highest_started(pid) == 0
      GenServer.stop(pid)
    end

    test "return safe defaults on a dead pid" do
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      assert SlotPolicy.highest_started(dead) == 0
      assert SlotPolicy.target_count(dead) == 0
    end
  end

  describe "max_slots/0 decoupling from target_count" do
    test "warm-pool target and the hard cap are independent" do
      {:ok, pid} = SlotPolicy.start_link(target_count: 0, max_slots: 5)
      Process.sleep(20)
      # pre_warmed_sessions = 0 boots no warm panes...
      assert SlotPolicy.target_count(pid) == 0
      # ...but the pool may still grow on demand up to the hard cap.
      assert SlotPolicy.max_slots(pid) == 5
      GenServer.stop(pid)
    end

    test "returns a safe default on a dead pid" do
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      assert SlotPolicy.max_slots(dead) == 0
    end
  end

  describe "grow_slot/1 ceiling" do
    test "refuses to grow past max_slots" do
      # target_count == max_slots == 0: the pool is already at its cap,
      # so no on-demand slot may start.
      {:ok, pid} = SlotPolicy.start_link(target_count: 0, max_slots: 0)
      Process.sleep(20)
      assert SlotPolicy.grow_slot(pid) == {:error, :at_capacity}
      assert SlotPolicy.highest_started(pid) == 0
      GenServer.stop(pid)
    end

    test "tolerates a dead server pid" do
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(dead)
      assert SlotPolicy.grow_slot(dead) == {:error, :unavailable}
    end
  end
end
