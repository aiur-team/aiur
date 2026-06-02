defmodule Aiur.Regression.DoneAgentDetachTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Source-level guards: when an active agent leaves the orchestrator's
  active set, every slot's attach is dropped and any visible chat pane
  showing that agent is closed.
  """

  @attach_pool_source Path.expand("../../../lib/aiur/opencode/attach_pool.ex", __DIR__)
  @pane_manager_source Path.expand("../../../lib/aiur/pane_manager.ex", __DIR__)

  test "AttachPool broadcasts :agent_inactive when seed drops an identifier" do
    source = File.read!(@attach_pool_source)

    assert source =~ ~r/broadcast_event\(\{:agent_inactive,/,
           """
           AttachPool MUST broadcast {:agent_inactive, id} on its
           topic when an identifier is removed from the active set.
           Subscribers (PaneManager) need this signal to close the
           chat pane currently showing the agent.
           """

    assert source =~ ~r/Slot\.detach\(/,
           """
           AttachPool MUST call Slot.detach for every slot the
           identifier was attached to. Otherwise stale attached
           sessions linger in slot serves.
           """
  end

  test "PaneManager subscribes to AttachPool topic + handles :agent_inactive" do
    source = File.read!(@pane_manager_source)

    assert source =~ ~r/Phoenix\.PubSub\.subscribe\(.*AttachPool\.topic/,
           "PaneManager MUST subscribe to AttachPool's topic"

    assert source =~ ~r/handle_info\(\{:agent_inactive,/,
           """
           PaneManager MUST handle {:agent_inactive, id} by closing
           the chat pane currently showing the agent.
           """

    assert source =~ ~r/close_opencode_or_generic\(state, identifier, pane_id\)/,
           """
           The :agent_inactive handler MUST route through
           close_opencode_or_generic so the slot's session is
           deselected and the pane moves to the hidden window.
           """
  end
end
