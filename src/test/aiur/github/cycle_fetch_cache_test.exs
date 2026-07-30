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
end
