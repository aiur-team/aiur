defmodule Aiur.ProviderMeters.Reconciler do
  @moduledoc false

  alias Aiur.ProviderMeterSnapshot

  @spec apply(ProviderMeterSnapshot.t() | nil, map(), DateTime.t()) ::
          {:updated | :ignored, ProviderMeterSnapshot.t()}
  def apply(existing, update, now) do
    snapshot =
      existing ||
        ProviderMeterSnapshot.empty(
          update.provider,
          update.backend,
          update.provider_account_generation
        )

    cond do
      different_identity?(snapshot, update) ->
        {:ignored, refresh(snapshot, now)}

      older_or_duplicate_success?(snapshot, update) ->
        {:ignored, refresh(snapshot, now)}

      true ->
        candidate = snapshot |> update_snapshot(update, now) |> refresh(now)
        if candidate == snapshot, do: {:ignored, snapshot}, else: {:updated, candidate}
    end
  end

  @spec failure(ProviderMeterSnapshot.t() | nil, map(), DateTime.t()) ::
          {:updated | :ignored, ProviderMeterSnapshot.t()}
  def failure(nil, failure, now) do
    snapshot =
      ProviderMeterSnapshot.empty(failure.provider, failure.backend, failure.provider_account_generation)
      |> put_failure(failure, now)
      |> refresh(now)

    {:updated, snapshot}
  end

  def failure(snapshot, failure, now) do
    if older_or_duplicate_failure?(snapshot, failure) do
      {:ignored, refresh(snapshot, now)}
    else
      {:updated, snapshot |> put_failure(failure, now) |> refresh(now)}
    end
  end

  @spec refresh(ProviderMeterSnapshot.t(), DateTime.t()) :: ProviderMeterSnapshot.t()
  def refresh(snapshot, now) do
    windows =
      Map.new(snapshot.windows, fn {limit_id, window} ->
        {limit_id, Map.put(window, :freshness, freshness(window, now))}
      end)

    plan = refresh_plan(snapshot.plan, now)
    freshness = projection_freshness(windows, plan, snapshot.observed_at)
    health = snapshot.health

    state =
      cond do
        is_nil(snapshot.observed_at) -> :unavailable
        not is_nil(health.failure) -> :stale
        freshness == :fresh -> :healthy
        freshness == :partial -> :partial
        freshness == :stale -> :stale
        true -> :unavailable
      end

    %{snapshot | windows: windows, plan: plan, freshness: freshness, health: %{health | state: state}}
  end

  defp update_snapshot(snapshot, %{update_kind: :snapshot} = update, now) do
    %{
      snapshot
      | auth_mode: update.auth_mode,
        plan: update.plan,
        update_kind: :snapshot,
        observed_at: update.observed_at,
        ingested_at: now,
        source: update.source,
        source_version: update.source_version,
        full_snapshot_observed_at: update.observed_at,
        window_tombstones: %{},
        windows: update.windows,
        health: healthy(update)
    }
  end

  defp update_snapshot(snapshot, %{update_kind: :patch} = update, now) do
    {windows, tombstones} = merge_windows(snapshot, update)

    %{
      snapshot
      | auth_mode: update.auth_mode || snapshot.auth_mode,
        plan: (newer_fact?(update.plan, snapshot.plan) && update.plan) || snapshot.plan,
        update_kind: :patch,
        observed_at: update.observed_at,
        ingested_at: now,
        source: update.source,
        source_version: update.source_version,
        window_tombstones: tombstones,
        windows: windows,
        health: patch_health(snapshot.health, update)
    }
  end

  defp update_snapshot(snapshot, %{update_kind: :tombstone} = update, now) do
    {windows, tombstones} = tombstone(snapshot, update)

    %{
      snapshot
      | update_kind: :tombstone,
        observed_at: update.observed_at,
        ingested_at: now,
        source: update.source,
        source_version: update.source_version,
        window_tombstones: tombstones,
        windows: windows,
        health: healthy(update)
    }
  end

  defp merge_windows(snapshot, update) do
    Enum.reduce(
      update.windows,
      {snapshot.windows, snapshot.window_tombstones},
      fn {limit_id, incoming}, {windows, tombstones} ->
        current = Map.get(windows, limit_id)
        tombstone = Map.get(tombstones, limit_id)

        newer? =
          newer_than_existing?(incoming, current) and
            newer_than_tombstone?(incoming, tombstone, snapshot.full_snapshot_observed_at)

        if newer? do
          {Map.put(windows, limit_id, incoming), Map.delete(tombstones, limit_id)}
        else
          {windows, tombstones}
        end
      end
    )
  end

  defp tombstone(snapshot, update) do
    case Map.get(snapshot.windows, update.limit_id) do
      current when is_map(current) ->
        tombstone = tombstone_fact(update)

        if newer_fact?(tombstone, current) do
          tombstones = Map.put(snapshot.window_tombstones, update.limit_id, tombstone)
          {Map.delete(snapshot.windows, update.limit_id), tombstones}
        else
          {snapshot.windows, snapshot.window_tombstones}
        end

      _ ->
        {snapshot.windows, snapshot.window_tombstones}
    end
  end

  defp put_failure(snapshot, failure, now) do
    %{
      snapshot
      | ingested_at: now,
        health: %{
          state: :stale,
          failure: failure.reason,
          last_observed_at: failure.observed_at,
          last_source_version: nil,
          last_attempt_at: nil,
          consecutive_failures: 0
        }
    }
  end

  defp healthy(update) do
    %{
      state: :healthy,
      failure: nil,
      last_observed_at: update.observed_at,
      last_source_version: update.source_version,
      last_attempt_at: nil,
      consecutive_failures: 0
    }
  end

  # A sparse provider update may refresh individual facts, but it cannot prove
  # the generation has recovered from a prior adapter failure. Only a valid
  # full snapshot (or a new account generation) clears that same-generation
  # LKG failure state.
  defp patch_health(%{failure: nil}, update), do: healthy(update)

  defp patch_health(health, update) do
    %{health | last_observed_at: update.observed_at, last_source_version: update.source_version}
  end

  defp different_identity?(snapshot, update) do
    snapshot.provider != update.provider or
      snapshot.backend != update.backend or
      snapshot.provider_account_generation != update.provider_account_generation
  end

  defp older_or_duplicate_success?(%{health: %{last_observed_at: nil}}, _update), do: false

  defp older_or_duplicate_success?(snapshot, update) do
    case DateTime.compare(update.observed_at, snapshot.health.last_observed_at) do
      :lt -> true
      :gt -> false
      :eq -> is_nil(snapshot.health.last_source_version) or update.source_version <= snapshot.health.last_source_version
    end
  end

  defp older_or_duplicate_failure?(%{health: %{last_observed_at: nil}}, _failure), do: false

  defp older_or_duplicate_failure?(snapshot, failure) do
    DateTime.compare(failure.observed_at, snapshot.health.last_observed_at) != :gt
  end

  defp newer_than_existing?(_incoming, nil), do: true
  defp newer_than_existing?(incoming, current), do: newer_fact?(incoming, current)

  defp newer_than_tombstone?(incoming, tombstone, full_snapshot_at) do
    newer_fact?(incoming, tombstone) and newer_than_full_snapshot?(incoming, full_snapshot_at)
  end

  defp newer_than_full_snapshot?(_incoming, nil), do: true

  defp newer_than_full_snapshot?(incoming, full_snapshot_at) do
    DateTime.compare(incoming.observed_at, full_snapshot_at) != :lt
  end

  defp newer_fact?(nil, _current), do: false
  defp newer_fact?(_incoming, nil), do: true

  defp newer_fact?(incoming, current) do
    case DateTime.compare(incoming.observed_at, current.observed_at) do
      :gt -> true
      :lt -> false
      :eq -> Map.get(incoming, :source_version, 0) > Map.get(current, :source_version, 0)
    end
  end

  defp tombstone_fact(update), do: %{observed_at: update.observed_at, source_version: update.source_version}
  defp refresh_plan(nil, _now), do: nil
  defp refresh_plan(plan, now), do: Map.put(plan, :freshness, freshness(plan, now))

  defp projection_freshness(windows, plan, observed_at) do
    states = Enum.map(windows, fn {_id, window} -> window.freshness end) ++ if(plan, do: [plan.freshness], else: [])

    cond do
      is_nil(observed_at) -> :unknown
      states == [] -> :fresh
      Enum.all?(states, &(&1 == :fresh)) -> :fresh
      Enum.all?(states, &(&1 == :stale)) -> :stale
      true -> :partial
    end
  end

  defp freshness(fact, now) do
    case Map.get(fact, :expires_at) do
      nil -> :fresh
      expires_at -> if(DateTime.compare(expires_at, now) == :gt, do: :fresh, else: :stale)
    end
  end
end
