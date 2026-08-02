defmodule Aiur.GitHub.BlockerCacheTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.BlockerCache

  setup do
    BlockerCache.clear()
    :ok
  end

  test "rotates a bounded refresh budget so deferred blockers are eventually selected" do
    ids = Enum.map(1..5, &Integer.to_string/1)

    assert MapSet.new(["1", "2"]) == BlockerCache.scheduled_refreshes(ids, 2)
    assert MapSet.new(["3", "4"]) == BlockerCache.scheduled_refreshes(ids, 2)
    assert MapSet.new(["5", "1"]) == BlockerCache.scheduled_refreshes(ids, 2)
  end

  test "invalidates cached dependents when a blocker receives new untestable evidence" do
    assert :ok = BlockerCache.put("dependent", [%{"number" => 1342}], now_ms: 0)
    assert {:fresh, _} = BlockerCache.cached("dependent", now_ms: 1)

    assert :ok = BlockerCache.invalidate_blocker("1342")
    assert :missing = BlockerCache.cached("dependent", now_ms: 1)
  end
end
