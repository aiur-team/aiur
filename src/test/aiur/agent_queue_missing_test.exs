defmodule Aiur.AgentQueueMissingTest do
  use ExUnit.Case, async: true
  @moduletag :r7_characterization

  alias Aiur.AgentQueueStore

  test "returns empty or nil for missing targets and item ids" do
    store = AgentQueueStore.new()

    assert {^store, nil} = AgentQueueStore.claim_next_deliverable(store, "MT-404")

    assert {^store, nil} =
             AgentQueueStore.claim_next_deliverable_matching(
               store,
               "MT-404",
               &match?(%{category: :operator_message}, &1)
             )

    assert AgentQueueStore.list_pending(store, "MT-404") == []
    assert AgentQueueStore.get(store, 999_999) == nil
    assert {^store, nil} = AgentQueueStore.mark_consumed(store, 999_999)
    assert {^store, nil} = AgentQueueStore.mark_failed(store, 999_999, :missing)
    assert {^store, nil} = AgentQueueStore.mark_superseded(store, 999_999)
  end
end
