defmodule Aiur.Opencode.Slot.EventsTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.Slot.Events
  alias Aiur.Opencode.SlotRegistry

  setup do
    Phoenix.PubSub.subscribe(Aiur.PubSub, Events.slots_topic())
    :ok
  end

  test "session_changed broadcasts {:slot_session_changed, index, id}" do
    Events.session_changed(11, "issue-11")
    assert_receive {:slot_session_changed, 11, "issue-11"}
  end

  test "attach_added broadcasts {:slot_attach_added, index, id}" do
    Events.attach_added(22, "issue-22")
    assert_receive {:slot_attach_added, 22, "issue-22"}
  end

  test "attach_removed broadcasts {:slot_attach_removed, index, id}" do
    Events.attach_removed(33, "issue-33")
    assert_receive {:slot_attach_removed, 33, "issue-33"}
  end

  test "slot_ready broadcasts {:slot_ready, index, pid}" do
    Events.slot_ready(44, self())
    assert_receive {:slot_ready, 44, pid} when pid == self()
  end

  test "visible_changed broadcasts and mirrors to SlotRegistry" do
    # Use an unused high index so we don't conflict with running slots
    slot_index = 97
    SlotRegistry.register_self(slot_index)
    Events.visible_changed(slot_index, "issue-x", "%5")
    assert_receive {:slot_visible_changed, ^slot_index, "issue-x"}
    assert {:ok, %{visible_identifier: "issue-x", pane_id: "%5"}} = SlotRegistry.pane_state(slot_index)
  end
end
