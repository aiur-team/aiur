defmodule Aiur.Opencode.SlotTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.Slot

  describe "terminate_pane_command/1" do
    test "returns a kill-pane command when the slot owns a pane" do
      assert Slot.terminate_pane_command(%{pane_id: "%9"}) == "kill-pane -t %9"
    end

    test "returns nil when there is no pane to reap" do
      assert Slot.terminate_pane_command(%{pane_id: nil}) == nil
    end
  end

  describe "writers_for_base_url/2 — reap selection (#372)" do
    test "selects only the entries bound to the given base_url" do
      entries = [
        %{base_url: "http://h:1", identifier: "a"},
        %{base_url: "http://h:2", identifier: "b"},
        %{base_url: "http://h:1", identifier: "c"}
      ]

      # A serve rebuild reaps writers for the OLD base_url only. Matching
      # on base_url must never sweep up a sibling slot's writers (each
      # slot's serve owns a unique base_url), or the rebuild would kill a
      # live agent's session on another slot.
      selected = Slot.writers_for_base_url(entries, "http://h:1")

      assert Enum.map(selected, & &1.identifier) == ["a", "c"]
    end

    test "returns [] when no entry matches" do
      entries = [%{base_url: "http://h:2", identifier: "b"}]

      assert Slot.writers_for_base_url(entries, "http://h:1") == []
    end
  end

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

  describe "new lifecycle API against a dead pid" do
    setup do
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(dead)
      {:ok, dead: dead}
    end

    test "attach/3 returns {:error, :no_slot} on a dead pid", %{dead: dead} do
      assert {:error, :no_slot} = Slot.attach(dead, "issue-1", 100)
    end

    test "attach_many/3 returns a list of {:error, :no_slot} for each id", %{dead: dead} do
      assert [
               {:error, :no_slot},
               {:error, :no_slot}
             ] = Slot.attach_many(dead, ["issue-1", "issue-2"], 100)
    end

    test "set_visible/3 returns {:error, :no_slot} on a dead pid", %{dead: dead} do
      assert {:error, :no_slot} = Slot.set_visible(dead, "issue-1", 100)
    end

    test "clear_visible/1 tolerates a dead pid", %{dead: dead} do
      assert :ok = Slot.clear_visible(dead)
    end

    test "detach/2 tolerates a dead pid", %{dead: dead} do
      assert :ok = Slot.detach(dead, "issue-1")
    end
  end

  describe "PubSub event topology" do
    test "all attach/visible events broadcast on slots_topic/0" do
      # Broadcasts to the shared `Aiur.PubSub` registry, an app child a sibling
      # test can terminate; subscribing to a missing registry raises
      # `unknown registry: Aiur.PubSub` rather than failing the broadcast
      # assertions this test is actually about (#2397).
      :ok = Aiur.TestSupport.ensure_pubsub_running()

      topic = Slot.slots_topic()
      Phoenix.PubSub.subscribe(Aiur.PubSub, topic)

      # We broadcast directly to assert the topic is the single source
      # of truth for slot state. Real slots send these via the
      # internal helpers in slot.ex; here we just confirm a subscriber
      # on the topic sees each event shape.
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:slot_attach_added, 1, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:slot_attach_removed, 1, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:slot_visible_changed, 1, "issue-1"})
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:slot_visible_changed, 1, nil})

      assert_receive {:slot_attach_added, 1, "issue-1"}, 500
      assert_receive {:slot_attach_removed, 1, "issue-1"}, 500
      assert_receive {:slot_visible_changed, 1, "issue-1"}, 500
      assert_receive {:slot_visible_changed, 1, nil}, 500
    end
  end
end
