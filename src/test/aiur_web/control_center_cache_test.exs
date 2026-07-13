defmodule AiurWeb.ControlCenterCacheTest do
  use ExUnit.Case, async: true

  alias AiurWeb.ControlCenterCache

  test "coalesces concurrent dashboard payload reads across callers" do
    cache = start_supervised!({ControlCenterCache, name: Module.concat(__MODULE__, :SharedCache)})
    counter = :counters.new(1, [])
    test_process = self()

    loader = fn ->
      :counters.add(counter, 1, 1)
      send(test_process, {:cache_loader_started, self()})

      receive do
        :release_cache_loader -> :ok
      end

      %{generation: :counters.get(counter, 1)}
    end

    tasks =
      1..12
      |> Enum.map(fn _index ->
        Task.async(fn -> ControlCenterCache.fetch(cache, :dashboard, 60_000, loader) end)
      end)

    assert_receive {:cache_loader_started, ^cache}, 500
    send(cache, :release_cache_loader)
    results = Task.await_many(tasks)

    assert Enum.uniq(results) == [%{generation: 1}]
    assert :counters.get(counter, 1) == 1

    reload = fn ->
      :counters.add(counter, 1, 1)
      %{generation: :counters.get(counter, 1)}
    end

    assert ControlCenterCache.fetch(cache, :dashboard, 0, reload) == %{generation: 2}
    assert ControlCenterCache.fetch(cache, :other_dashboard, 60_000, reload) == %{generation: 3}
  end
end
