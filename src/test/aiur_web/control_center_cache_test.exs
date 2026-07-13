defmodule AiurWeb.ControlCenterCacheTest do
  use ExUnit.Case, async: true

  alias AiurWeb.ControlCenterCache

  test "coalesces concurrent dashboard payload reads across callers" do
    cache = start_supervised!({ControlCenterCache, name: Module.concat(__MODULE__, :SharedCache)})
    counter = :counters.new(1, [])

    loader = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(20)
      %{generation: :counters.get(counter, 1)}
    end

    results =
      1..12
      |> Enum.map(fn _index -> Task.async(fn -> ControlCenterCache.fetch(cache, :dashboard, 100, loader) end) end)
      |> Task.await_many()

    assert Enum.uniq(results) == [%{generation: 1}]
    assert :counters.get(counter, 1) == 1

    Process.sleep(110)
    assert ControlCenterCache.fetch(cache, :dashboard, 100, loader) == %{generation: 2}

    assert ControlCenterCache.fetch(cache, :other_dashboard, 100, loader) == %{generation: 3}
  end
end
