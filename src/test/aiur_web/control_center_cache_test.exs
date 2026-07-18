defmodule AiurWeb.ControlCenterCacheTest do
  use ExUnit.Case, async: true

  alias AiurWeb.ControlCenterCache

  test "coalesces concurrent cold and expired dashboard payload reads" do
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

    :sys.replace_state(cache, fn entries ->
      update_in(entries, [:dashboard, :loaded_at_ms], &(&1 - 60_001))
    end)

    expired_tasks =
      1..12
      |> Enum.map(fn _index ->
        Task.async(fn -> ControlCenterCache.fetch(cache, :dashboard, 60_000, loader) end)
      end)

    assert_receive {:cache_loader_started, ^cache}, 500
    send(cache, :release_cache_loader)
    expired_results = Task.await_many(expired_tasks)

    assert Enum.uniq(expired_results) == [%{generation: 2}]
    assert :counters.get(counter, 1) == 2
  end

  test "coalesces a provider event across viewers and refreshes the ordinary TTL entry" do
    cache = start_supervised!({ControlCenterCache, name: nil})
    counter = :counters.new(1, [])

    loader = fn ->
      :counters.add(counter, 1, 1)
      %{generation: :counters.get(counter, 1)}
    end

    initial = ControlCenterCache.fetch(cache, :dashboard, 400, loader)

    results =
      1..2
      |> Enum.map(fn _viewer ->
        Task.async(fn -> ControlCenterCache.fetch_event(cache, :dashboard, {:membership, 2}, loader) end)
      end)
      |> Enum.map(&Task.await/1)

    assert initial == %{generation: 1}
    assert results == [%{generation: 2}, %{generation: 2}]
    assert :counters.get(counter, 1) == 2
    assert ControlCenterCache.fetch(cache, :dashboard, 400, loader) == %{generation: 2}
    assert :counters.get(counter, 1) == 2
  end
end
