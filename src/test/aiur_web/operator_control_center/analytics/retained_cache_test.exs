defmodule AiurWeb.OperatorControlCenter.Analytics.RetainedCacheTest do
  use ExUnit.Case, async: false
  alias AiurWeb.OperatorControlCenter.Analytics.LatestRun
  alias Aiur.RunTelemetry.RetainedCache

  test "concurrent latest cold loads survive the first requester exiting" do
    parent = self()
    key = make_ref()
    dataset = %{tickets: %{1 => %{}}, provenance: %{time_range: %{end: "2026-10-09T00:00:00Z"}}}

    loader = fn ->
      send(parent, {:started, self()})
      receive do: (:release -> {[dataset], false})
    end

    opts = [cache_identity: key, prior_loader: loader]
    file = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.ndjson")
    first = spawn(fn -> LatestRun.load(file, "current", &analyzable?/1, opts) end)
    assert_receive {:started, worker}, 1_000
    spawn(fn -> send(parent, {:result, LatestRun.load(file, "current", &analyzable?/1, opts)}) end)
    await_waiters({LatestRun, {key, nil}}, 2)
    owner = :ets.info(LatestRun, :owner)
    assert owner != first
    Process.exit(first, :kill)
    assert Process.alive?(worker)
    assert Process.alive?(owner)
    send(worker, :release)
    assert_receive {:result, {:ok, ^dataset}}, 1_000
    refute_receive {:started, _worker}, 50
    assert {:ok, ^dataset} = LatestRun.load(file, "current", &analyzable?/1, Keyword.put(opts, :prior_loader, fn -> flunk("warm request rescanned") end))
  end

  test "coalesced failures reach every waiter and a later request retries" do
    parent = self()
    key = make_ref()

    loader = fn ->
      send(parent, {:started, self()})
      receive do: (:release -> {:error, :retained_unreadable})
    end

    for _ <- 1..2, do: spawn(fn -> send(parent, {:result, RetainedCache.fetch(__MODULE__, key, loader)}) end)
    assert_receive {:started, worker}, 1_000
    await_waiters({__MODULE__, key}, 2)
    send(worker, :release)
    assert_receive {:result, {:error, :retained_unreadable}}, 1_000
    assert_receive {:result, {:error, :retained_unreadable}}, 1_000
    refute_receive {:started, _pid}, 50
    assert :recovered = RetainedCache.fetch(__MODULE__, key, fn -> :recovered end)
  end

  test "future regression guard: raised loader failures propagate without poisoning retries" do
    key = make_ref()
    assert_raise ArgumentError, "broken summary", fn -> RetainedCache.fetch(__MODULE__, key, fn -> raise ArgumentError, "broken summary" end) end
    assert :recovered = RetainedCache.fetch(__MODULE__, key, fn -> :recovered end)
  end

  test "bounds both cumulative cached bytes and entry count" do
    table = Module.concat(__MODULE__, ByteLimit)
    value = :binary.copy("x", 12 * 1024 * 1024 - 16)
    for key <- 1..3, do: assert(value == RetainedCache.fetch(table, key, fn -> value end, max_value_bytes: 12 * 1024 * 1024))
    assert :ets.info(table, :size) == 1
    assert [{3, ^value}] = :ets.tab2list(table)
    for key <- 4..15, do: assert(key == RetainedCache.fetch(table, key, fn -> key end))
    assert :ets.info(table, :size) <= 8
    assert :oversized = RetainedCache.fetch(table, :oversized, fn -> :oversized end, max_value_bytes: 0)
    assert :ets.lookup(table, :oversized) == []
  end

  defp analyzable?(dataset), do: map_size(dataset.tickets) > 0

  defp await_waiters(id, count, attempts \\ 100) do
    if length(:sys.get_state(RetainedCache).pending[id].waiters) < count do
      assert attempts > 0
      Process.sleep(10)
      await_waiters(id, count, attempts - 1)
    end
  end
end
