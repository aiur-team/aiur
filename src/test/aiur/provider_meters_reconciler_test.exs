defmodule Aiur.ProviderMetersReconcilerTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Aiur.ProviderMeters.Reconciler

  @now ~U[2026-07-15 19:00:00Z]

  property "arbitrary limit IDs preserve full, sparse, tombstone, and out-of-order semantics" do
    check all(
            ids <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 20),
                min_length: 2,
                max_length: 12
              ),
            max_runs: 25
          ) do
      full = reconciliation_update(:snapshot, ids, @now, 1)
      {:updated, snapshot} = Reconciler.apply(nil, full, @now)

      patch = reconciliation_update(:patch, [hd(ids)], DateTime.add(@now, 1, :second), 2)
      {:updated, patched} = Reconciler.apply(snapshot, patch, @now)

      assert Map.keys(patched.windows) |> MapSet.new() == MapSet.new(ids)
      assert patched.windows[hd(ids)].used_percent == 50

      retained_ids = tl(ids)
      replacement = reconciliation_update(:snapshot, retained_ids, DateTime.add(@now, 2, :second), 3)
      {:updated, compacted} = Reconciler.apply(patched, replacement, @now)
      assert Map.keys(compacted.windows) |> MapSet.new() == MapSet.new(retained_ids)

      removed_id = hd(retained_ids)
      tombstone = reconciliation_tombstone(removed_id, DateTime.add(@now, 3, :second), 4)
      {:updated, tombstoned} = Reconciler.apply(compacted, tombstone, @now)
      refute Map.has_key?(tombstoned.windows, removed_id)

      stale_patch =
        reconciliation_update(:patch, [removed_id], DateTime.add(@now, 4, :second), 5)
        |> update_in([:windows, removed_id], &Map.put(&1, :observed_at, @now))

      {_outcome, preserved} = Reconciler.apply(tombstoned, stale_patch, @now)
      refute Map.has_key?(preserved.windows, removed_id)
    end
  end

  property "only a full snapshot recovers LKG while delayed failures cannot regress health" do
    check all(id <- string(:alphanumeric, min_length: 1, max_length: 20), max_runs: 25) do
      initial = reconciliation_update(:snapshot, [id], @now, 1)
      {:updated, snapshot} = Reconciler.apply(nil, initial, @now)

      failure = reconciliation_failure(DateTime.add(@now, 2, :second), :transport)
      {:updated, stale} = Reconciler.failure(snapshot, failure, @now)
      assert stale.health.state == :stale
      assert stale.windows[id].used_percent == 25

      sparse_patch = reconciliation_update(:patch, [id], DateTime.add(@now, 4, :second), 2)
      {:updated, patched} = Reconciler.apply(stale, sparse_patch, @now)
      assert patched.health.state == :stale
      assert patched.health.failure == :transport
      assert patched.health.last_observed_at == DateTime.add(@now, 4, :second)
      assert patched.windows[id].used_percent == 50

      out_of_order_full = reconciliation_update(:snapshot, [id], DateTime.add(@now, 3, :second), 3)
      assert {:ignored, ^patched} = Reconciler.apply(patched, out_of_order_full, @now)

      recovery = reconciliation_update(:snapshot, [id], DateTime.add(@now, 5, :second), 4)
      {:updated, recovered} = Reconciler.apply(patched, recovery, @now)
      assert recovered.health.state == :healthy
      assert recovered.health.failure == nil

      delayed = reconciliation_failure(DateTime.add(@now, 1, :second), :timeout)
      assert {:ignored, ^recovered} = Reconciler.failure(recovered, delayed, @now)
    end
  end

  property "window freshness stays independent for arbitrary future expiries" do
    check all(future_seconds <- integer(1..600), max_runs: 25) do
      update =
        reconciliation_update(:snapshot, ["expired", "current"], @now, 1)
        |> update_in([:windows, "expired"], &Map.put(&1, :expires_at, DateTime.add(@now, -1, :second)))
        |> update_in([:windows, "current"], &Map.put(&1, :expires_at, DateTime.add(@now, future_seconds, :second)))

      {:updated, snapshot} = Reconciler.apply(nil, update, @now)

      assert snapshot.windows["expired"].freshness == :stale
      assert snapshot.windows["current"].freshness == :fresh
      assert snapshot.health.state == :partial
    end
  end

  test "duplicates and out-of-order updates do not replace newer observations" do
    initial = reconciliation_update(:snapshot, ["rolling"], @now, 2)
    {:updated, snapshot} = Reconciler.apply(nil, initial, @now)

    assert {:ignored, ^snapshot} = Reconciler.apply(snapshot, initial, DateTime.add(@now, 1, :second))

    older = reconciliation_update(:snapshot, ["older"], DateTime.add(@now, -1, :second), 1)
    assert {:ignored, ^snapshot} = Reconciler.apply(snapshot, older, @now)
  end

  test "reconciliation never merges an identical generation from another provider" do
    codex = reconciliation_update(:snapshot, ["rolling"], @now, 1)
    claude = %{codex | provider: :claude}
    {:updated, snapshot} = Reconciler.apply(nil, codex, @now)

    assert {:ignored, ^snapshot} = Reconciler.apply(snapshot, claude, DateTime.add(@now, 1, :second))
  end

  defp window(limit_id, overrides) do
    Map.merge(
      %{
        limit_id: limit_id,
        kind: :rate_limit,
        name: :primary,
        used_percent: 25,
        duration_minutes: 300,
        source: :synthetic,
        observed_at: @now,
        coverage: :supported
      },
      Map.new(overrides)
    )
  end

  defp reconciliation_update(kind, ids, observed_at, source_version) do
    %{
      update_kind: kind,
      provider: :codex,
      backend: :app_server,
      provider_account_generation: "opaque-generation",
      auth_mode: :subscription,
      plan: nil,
      observed_at: observed_at,
      source: :synthetic,
      source_version: source_version,
      windows:
        Map.new(ids, fn id ->
          window(id, used_percent: if(kind == :patch, do: 50, else: 25))
          |> Map.delete(:limit_id)
          |> Map.put(:source_version, source_version)
          |> then(&{id, &1})
        end),
      limit_id: nil
    }
  end

  defp reconciliation_tombstone(limit_id, observed_at, source_version) do
    %{
      update_kind: :tombstone,
      provider: :codex,
      backend: :app_server,
      provider_account_generation: "opaque-generation",
      observed_at: observed_at,
      source: :synthetic,
      source_version: source_version,
      limit_id: limit_id
    }
  end

  defp reconciliation_failure(observed_at, reason) do
    %{
      provider: :codex,
      backend: :app_server,
      provider_account_generation: "opaque-generation",
      observed_at: observed_at,
      reason: reason
    }
  end
end
