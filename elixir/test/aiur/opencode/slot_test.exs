defmodule Aiur.Opencode.SlotTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.Slot

  describe "slots_topic/0" do
    test "returns a stable string suitable for PubSub" do
      assert is_binary(Slot.slots_topic())
      assert Slot.slots_topic() != ""
    end
  end

  describe "snapshot/1" do
    test "returns :unavailable when the server is not running" do
      # Use a fresh process not registered as a slot.
      fake = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(fake)

      assert Slot.snapshot(fake) == %{status: :unavailable}
    end
  end

  describe "select/2 + deselect/1 against a dead pid" do
    test "select returns {:error, :no_slot} when the slot worker is gone" do
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(dead)

      assert {:error, :no_slot} = Slot.select(dead, "issue-42", 100)
    end

    test "deselect tolerates a dead pid" do
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      assert :ok = Slot.deselect(dead)
    end
  end
end
