defmodule Aiur.CurrentRunMembership.ReadCacheTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.CurrentRunMembership.{Projection, Store}
  alias Aiur.TrackerIdentity

  test "repeated reads sort members once while reconciliation and membership changes stay visible" do
    dir = Aiur.TestSupport.tmp_root!("membership-read-cache")
    on_exit(fn -> File.rm_rf!(dir) end)
    owner = start_supervised!({Store, name: nil, state_dir: dir, run_id: "cache-run"})
    identity = %TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "owner", repository: "repo", provider_id: "I-42", identifier: "42", reason: nil}
    now = ~U[2026-10-09 00:00:00Z]
    assert {:ok, %{generation: 1}} = Store.observe(identity, :queued, server: owner, observed_at: now)

    :erlang.trace_pattern({Projection, :members, 1}, true, [])
    :erlang.trace(owner, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({Projection, :members, 1}, false, []) end)

    for _ <- 1..20 do
      assert Store.snapshot(server: owner).freshness.last_observed_at == now
      assert Store.freshness(owner).last_observed_at == now
    end

    assert sorted_calls(owner) == 1
    assert :ok = Store.mark_reconciled(:fresh, owner)
    assert Store.snapshot(server: owner).freshness.status == :fresh
    assert sorted_calls(owner) == 0
    later = DateTime.add(now, 1, :second)
    assert {:ok, %{generation: 2}} = Store.observe(identity, :completed, server: owner, observed_at: later)
    assert %{members: [%{lifecycle: :completed}], freshness: %{last_observed_at: ^later}} = Store.snapshot(server: owner)
    # Notification also needs freshness, so it may sort before the next read.
    assert sorted_calls(owner) == 2
    for _ <- 1..20, do: assert(Store.freshness(owner).last_observed_at == later)
    assert sorted_calls(owner) == 0
    assert :ok = Store.mark_reconciled(:unavailable, owner)
    assert Store.snapshot(server: owner).freshness.status == :unavailable
  end

  defp sorted_calls(owner) do
    ref = :erlang.trace_delivered(owner)
    receive_barrier({:trace_delivered, ^owner, ^ref})
    count_calls(owner, 0)
  end

  defp count_calls(owner, count) do
    receive do
      {:trace, ^owner, :call, {Projection, :members, [_projection]}} -> count_calls(owner, count + 1)
    after
      0 -> count
    end
  end
end
