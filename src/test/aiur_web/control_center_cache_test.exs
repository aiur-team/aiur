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

    assert_receive {:cache_loader_started, loader_pid}, 500
    send(loader_pid, :release_cache_loader)
    results = Task.await_many(tasks)

    assert Enum.uniq(results) == [%{generation: 1}]
    assert :counters.get(counter, 1) == 1

    :sys.replace_state(cache, fn entries ->
      update_in(entries, [:entries, :dashboard, :loaded_at_ms], &(&1 - 60_001))
    end)

    expired_tasks =
      1..12
      |> Enum.map(fn _index ->
        Task.async(fn -> ControlCenterCache.fetch(cache, :dashboard, 60_000, loader) end)
      end)

    assert_receive {:cache_loader_started, loader_pid}, 500
    send(loader_pid, :release_cache_loader)
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

  test "a slow miss does not block a hit on another key" do
    cache = start_supervised!({ControlCenterCache, name: nil})
    assert ControlCenterCache.fetch(cache, :fast, 60_000, fn -> %{value: :fast} end) == %{value: :fast}
    parent = self()

    slow =
      Task.async(fn ->
        ControlCenterCache.fetch(cache, :slow, 60_000, fn ->
          send(parent, {:slow_started, self()})

          receive do
            :release -> %{value: :slow}
          end
        end)
      end)

    assert_receive {:slow_started, loader_pid}, 500
    hit = Task.async(fn -> ControlCenterCache.fetch(cache, :fast, 60_000, fn -> flunk("cached hit reloaded") end) end)
    assert Task.yield(hit, 100) == {:ok, %{value: :fast}}
    send(loader_pid, :release)
    assert Task.await(slow) == %{value: :slow}
  end

  test "same-key callers join an in-flight load" do
    cache = start_supervised!({ControlCenterCache, name: nil})
    parent = self()

    loader = fn ->
      send(parent, {:started, self()})

      receive do
        :release -> %{value: :shared}
      end
    end

    first = Task.async(fn -> ControlCenterCache.fetch(cache, :key, 60_000, loader) end)
    assert_receive {:started, loader_pid}, 500
    second = Task.async(fn -> ControlCenterCache.fetch(cache, :key, 60_000, loader) end)
    # A barrier on the second caller proves its request reached the cache before release.
    assert Task.yield(second, 50) == nil
    assert length(:sys.get_state(cache).loads.key.waiters) == 2
    send(loader_pid, :release)
    assert Task.await_many([first, second]) == [%{value: :shared}, %{value: :shared}]
    refute_received {:started, _pid}
  end

  @tag timeout: 10_000
  test "loader deadlines return stale or unavailable maps without a second load" do
    cache = start_supervised!({ControlCenterCache, name: nil})
    assert ControlCenterCache.fetch(cache, :warm, 0, fn -> %{generation: 1} end) == %{generation: 1}
    counter = :counters.new(1, [])
    parent = self()

    loader = fn ->
      :counters.add(counter, 1, 1)
      send(parent, {:waiting, self()})
      Process.sleep(10_000)
      %{generation: 2}
    end

    started = System.monotonic_time(:millisecond)
    warm = Task.async(fn -> ControlCenterCache.fetch(cache, :warm, 0, loader) end)
    cold = Task.async(fn -> ControlCenterCache.fetch_event(cache, :cold, :event, loader) end)
    assert_receive {:waiting, pid_a}, 500
    assert_receive {:waiting, pid_b}, 500
    # The retained payload carries its real age so a surface can render it (#3937).
    assert %{generation: 1, stale: true, stale_age_ms: age_ms} = Task.await(warm, 5_100)
    assert age_ms in 3_900..5_000
    assert Task.await(cold, 5_100) == %{stale: true, error: {:cache_unavailable, :timeout}}
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert :counters.get(counter, 1) == 2
    refute Process.alive?(pid_a)
    refute Process.alive?(pid_b)
    assert ControlCenterCache.fetch(cache, :warm, 0, fn -> %{generation: 3} end) == %{generation: 3}
  end

  test "loader crashes reply to callers and allow retry" do
    cache = start_supervised!({ControlCenterCache, name: nil})

    assert ControlCenterCache.fetch(cache, :key, 0, fn -> exit(:broken_loader) end) ==
             %{stale: true, error: {:cache_unavailable, :broken_loader}}

    assert Process.alive?(cache)
    assert ControlCenterCache.fetch(cache, :key, 0, fn -> %{value: :recovered} end) == %{value: :recovered}
  end

  test "event and forced reloads read after invalidation and cannot be overwritten by an older load" do
    for mode <- [:event, :fresh] do
      cache = start_supervised!({ControlCenterCache, name: nil}, id: {ControlCenterCache, mode})
      value = :atomics.new(1, [])
      :atomics.put(value, 1, 1)
      parent = self()

      loader = fn ->
        version = :atomics.get(value, 1)
        send(parent, {:version_read, version, self()})

        receive do
          :release -> %{version: version}
        after
          5_000 -> %{version: version}
        end
      end

      old = Task.async(fn -> ControlCenterCache.fetch(cache, :key, 60_000, loader) end)
      assert_receive {:version_read, 1, old_loader}, 500
      :atomics.put(value, 1, 2)

      reload =
        Task.async(fn ->
          case mode do
            :event -> ControlCenterCache.fetch_event(cache, :key, {:decision_changed, "d", 2}, loader)
            :fresh -> ControlCenterCache.fetch(cache, :key, 0, loader)
          end
        end)

      assert_receive {:version_read, 2, new_loader}, 500
      send(new_loader, :release)
      assert Task.await(reload) == %{version: 2}
      send(old_loader, :release)
      assert Task.await(old) == %{version: 1}
      assert ControlCenterCache.fetch(cache, :key, 60_000, fn -> flunk("new payload was not cached") end) == %{version: 2}
    end
  end
end
