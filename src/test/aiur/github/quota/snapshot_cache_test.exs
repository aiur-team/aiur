defmodule Aiur.GitHub.Quota.SnapshotCacheTest do
  use Aiur.TestSupport
  import Aiur.GitHub.QuotaTestSupport

  alias Aiur.GitHub.Quota
  alias Aiur.GitHub.Quota.SnapshotCache

  test "repeated snapshot reads refresh the ETS cached value" do
    server = start_quota()

    snapshot = Enum.reduce(1..25, nil, fn _, _latest -> Quota.snapshot!(server) end)

    assert [{^server, ^snapshot, cached_at_ms, observed_at_ms}] = :ets.lookup(SnapshotCache, server)
    assert is_integer(cached_at_ms)
    assert is_integer(observed_at_ms)
    assert {:ok, ^snapshot, age_ms, ^observed_at_ms} = Quota.cached_snapshot(server)
    assert age_ms >= 0
    assert {:ok, ^snapshot, 60_000, ^observed_at_ms} = Quota.cached_snapshot_at(server, 60_000, cached_at_ms + 60_000)
    assert :miss = Quota.cached_snapshot_at(server, 60_000, cached_at_ms + 60_001)
  end
end
