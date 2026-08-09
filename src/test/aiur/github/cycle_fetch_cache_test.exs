defmodule Aiur.GitHub.CycleFetchCacheTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.CycleFetchCache

  setup do
    CycleFetchCache.end_cycle()
    on_exit(&CycleFetchCache.end_cycle/0)
  end

  test "shares successful fetches for a cycle" do
    assert :ok = CycleFetchCache.start_cycle()

    fetcher = fn ->
      send(self(), :fetched)
      {:ok, :value}
    end

    assert {:ok, :value} = CycleFetchCache.fetch(:key, fetcher)
    assert {:ok, :value} = CycleFetchCache.fetch(:key, fetcher)
    assert_received :fetched
    refute_received :fetched
  end

  test "does not retain values after the cycle" do
    assert :ok = CycleFetchCache.start_cycle()
    assert {:ok, :first} = CycleFetchCache.fetch(:key, fn -> {:ok, :first} end)
    assert :ok = CycleFetchCache.end_cycle()
    assert {:ok, :second} = CycleFetchCache.fetch(:key, fn -> {:ok, :second} end)
  end

  test "does not cache failures" do
    assert :ok = CycleFetchCache.start_cycle()
    assert {:error, :temporary} = CycleFetchCache.fetch(:key, fn -> {:error, :temporary} end)
    assert {:ok, :recovered} = CycleFetchCache.fetch(:key, fn -> {:ok, :recovered} end)
  end

  test "shares conditional not-modified responses" do
    assert :ok = CycleFetchCache.start_cycle()

    fetcher = fn ->
      send(self(), :fetched)
      {:not_modified, "etag"}
    end

    assert {:not_modified, "etag"} = CycleFetchCache.fetch(:key, fetcher)
    assert {:not_modified, "etag"} = CycleFetchCache.fetch(:key, fetcher)
    assert_received :fetched
    refute_received :fetched
  end

  test "isolates cycles across processes during teardown" do
    assert :ok = CycleFetchCache.start_cycle()

    parent = self()

    fetch_task =
      Task.async(fn ->
        assert {:ok, :value} =
                 CycleFetchCache.fetch(:key, fn ->
                   send(parent, :fetch_started)
                   assert_receive :release
                   {:ok, :value}
                 end)
      end)

    assert_receive :fetch_started
    assert :ok = Task.await(Task.async(fn -> CycleFetchCache.end_cycle() end))
    send(fetch_task.pid, :release)
    assert {:ok, :value} = Task.await(fetch_task)
  end
end
