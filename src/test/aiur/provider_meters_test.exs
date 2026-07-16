defmodule Aiur.ProviderMetersTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Aiur.{ProviderAccountGeneration, ProviderMeterSnapshot}
  alias Aiur.ProviderMeters.{Events, Input, Reconciler, Store}

  @now ~U[2026-07-15 19:00:00Z]

  setup do
    ensure_pubsub()
    {:ok, owner} = ProviderAccountGeneration.start_link(name: nil, mint: sequence_mint())
    {:ok, store} = Store.start_link(name: nil, account_generation_owner: owner, clock: fn -> @now end)

    on_exit(fn ->
      if Process.alive?(owner), do: GenServer.stop(owner)
      if Process.alive?(store), do: GenServer.stop(store)
    end)

    %{owner: owner, store: store}
  end

  test "full snapshots remove omitted windows while patches and tombstones stay sparse", %{owner: owner, store: store} do
    binding = bound_binding(owner)

    assert {:ok, first} =
             Store.ingest(store, update(binding, windows: [window("session"), window("weekly")]))

    assert Map.keys(first.windows) |> Enum.sort() == ["session", "weekly"]

    assert {:ok, patched} =
             Store.ingest(
               store,
               update(binding,
                 update_kind: :patch,
                 observed_at: DateTime.add(@now, 1, :second),
                 source_version: 2,
                 windows: [window("session", used_percent: 50)]
               )
             )

    assert patched.windows["session"].used_percent == 50
    assert Map.has_key?(patched.windows, "weekly")

    assert {:ok, compacted} =
             Store.ingest(
               store,
               update(binding,
                 observed_at: DateTime.add(@now, 2, :second),
                 source_version: 3,
                 windows: [window("weekly", used_percent: 10)]
               )
             )

    assert Map.keys(compacted.windows) == ["weekly"]

    assert {:ok, tombstoned} =
             Store.ingest(
               store,
               tombstone(binding, "weekly", DateTime.add(@now, 3, :second), 4)
             )

    assert tombstoned.windows == %{}
  end

  property "arbitrary limit IDs preserve full, sparse, tombstone, and out-of-order semantics" do
    check all(ids <- uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 20), min_length: 2, max_length: 12), max_runs: 25) do
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

  property "newer success recovers LKG while delayed failures cannot regress health" do
    check all(id <- string(:alphanumeric, min_length: 1, max_length: 20), max_runs: 25) do
      initial = reconciliation_update(:snapshot, [id], @now, 1)
      {:updated, snapshot} = Reconciler.apply(nil, initial, @now)

      failure = reconciliation_failure(DateTime.add(@now, 2, :second), :transport)
      {:updated, stale} = Reconciler.failure(snapshot, failure, @now)
      assert stale.health.state == :stale
      assert stale.windows[id].used_percent == 25

      recovery = reconciliation_update(:patch, [id], DateTime.add(@now, 3, :second), 2)
      {:updated, recovered} = Reconciler.apply(stale, recovery, @now)
      assert recovered.health.state == :healthy
      assert recovered.windows[id].used_percent == 50

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

  test "freshness expires per window and failures retain same-generation LKG", %{owner: owner, store: store} do
    binding = bound_binding(owner)

    assert {:ok, first} =
             Store.ingest(
               store,
               update(binding,
                 windows: [
                   window("expired", expires_at: DateTime.add(@now, -1, :second)),
                   window("current", expires_at: DateTime.add(@now, 60, :second))
                 ]
               )
             )

    assert first.windows["expired"].freshness == :stale
    assert first.windows["current"].freshness == :fresh
    assert first.health.state == :partial

    assert {:ok, failed} =
             Store.record_failure(
               store,
               %{schema_version: 1, provider: :codex, backend: :app_server, account_generation_binding: binding, reason: :transport, observed_at: DateTime.add(@now, 1, :second)}
             )

    assert failed.health.state == :stale
    assert failed.health.failure == :transport
    assert failed.observed_at == first.observed_at
    assert failed.windows["current"].used_percent == first.windows["current"].used_percent

    assert {:ok, recovered} =
             Store.ingest(
               store,
               update(binding,
                 observed_at: DateTime.add(@now, 2, :second),
                 source_version: 2,
                 windows: [window("current", used_percent: 20)]
               )
             )

    assert recovered.health.state == :healthy
    assert recovered.health.failure == nil
    assert recovered.windows["current"].used_percent == 20
  end

  test "unknown and replacement generations cannot inherit another account's facts", %{owner: owner, store: store} do
    first_binding = bound_binding(owner)
    assert {:ok, first} = Store.ingest(store, update(first_binding, windows: [window("rolling")]))
    assert Store.snapshot(store, :codex, :app_server, make_ref()).provider_account_generation == nil
    assert Store.snapshot(store, :codex, :app_server, make_ref()).windows == %{}

    assert {:ok, %{generation: replacement_generation}} =
             ProviderAccountGeneration.replace(owner, :codex, :app_server, first_binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert replacement_generation != first.provider_account_generation

    replacement = Store.snapshot(store, :codex, :app_server, first_binding)

    assert replacement.windows == %{}
    assert replacement.health.state == :unavailable

    assert {:ok, new_failure} =
             Store.record_failure(
               store,
               %{schema_version: 1, provider: :codex, backend: :app_server, account_generation_binding: first_binding, reason: :timeout, observed_at: @now}
             )

    assert new_failure.windows == %{}
    assert new_failure.health.state == :unavailable
    assert new_failure.health.failure == :timeout
  end

  test "reconciliation never merges an identical generation from another provider" do
    codex = reconciliation_update(:snapshot, ["rolling"], @now, 1)
    claude = %{codex | provider: :claude}
    {:updated, snapshot} = Reconciler.apply(nil, codex, @now)

    assert {:ignored, ^snapshot} = Reconciler.apply(snapshot, claude, DateTime.add(@now, 1, :second))
  end

  test "adapter boundary rejects identity, credential, raw, capability, and content fields before state or PubSub", %{owner: owner, store: store} do
    binding = bound_binding(owner)
    input = update(binding, windows: [window("rolling")])
    assert {:ok, generation} = Store.subscription_generation(store, :codex, :app_server, binding)
    :ok = Events.subscribe(:codex, :app_server, generation)
    before = :sys.get_state(store)

    for field <- [:account, :email, :organization, :org, :project, :credential, :raw_response, :headers, :capability, :content] do
      assert {:error, :invalid_provider_meter_update} = Store.ingest(store, Map.put(input, field, "secret@example.test"))
    end

    assert {:error, :invalid_provider_meter_update} = Store.ingest(store, %{input | windows: [Map.put(window("rolling"), :raw_payload, %{token: "secret"})]})

    assert :sys.get_state(store) == before
    refute_receive {:provider_meter_changed, _snapshot}, 100
  end

  test "subscription and API-key modes reject fabricated unsupported facts", %{owner: owner, store: store} do
    binding = bound_binding(owner)

    for auth_mode <- [:subscription, :api_key] do
      unsupported = update(binding, auth_mode: auth_mode, windows: [coverage_window("unavailable", :unsupported)])
      assert {:ok, normalized} = Input.normalize(unsupported)
      assert normalized.windows["unavailable"].coverage == :unsupported

      fabricated = update(binding, auth_mode: auth_mode, windows: [window("unavailable", coverage: :unsupported)])
      assert {:error, :invalid_provider_meter_update} = Store.ingest(store, fabricated)
    end

    bad_control =
      update(binding,
        windows: [window("credit", credits: %{status: :unsupported, amount: 0})]
      )

    assert {:error, :invalid_provider_meter_update} = Store.ingest(store, bad_control)
  end

  test "supported-empty and unsupported facts remain distinct and change notifications are bounded", %{owner: owner, store: store} do
    binding = bound_binding(owner)
    assert {:ok, generation} = Store.subscription_generation(store, :codex, :app_server, binding)
    :ok = Events.subscribe(:codex, :app_server, generation)

    assert {:ok, snapshot} =
             Store.ingest(
               store,
               update(binding,
                 windows: [
                   coverage_window("subscription", :empty_supported),
                   coverage_window("api-credit", :unsupported, kind: :credit, name: :credits)
                 ]
               )
             )

    assert snapshot.windows["subscription"].coverage == :empty_supported
    assert snapshot.windows["api-credit"].coverage == :unsupported
    refute Map.has_key?(snapshot.windows["api-credit"], :limit)
    refute Map.has_key?(snapshot.windows["api-credit"], :used)
    assert_receive {:provider_meter_changed, %ProviderMeterSnapshot{windows: windows}}, 2_000
    assert map_size(windows) == 2

    other_binding = bound_binding(owner)
    assert {:ok, other_snapshot} = Store.ingest(store, update(other_binding, windows: [window("other")]))
    refute_receive {:provider_meter_changed, ^other_snapshot}, 100

    oversized = Enum.map(1..33, &window("limit-#{&1}"))
    assert {:error, :invalid_provider_meter_update} = Input.normalize(update(binding, windows: oversized))
  end

  defp update(binding, overrides) do
    Map.merge(
      %{
        schema_version: 1,
        update_kind: :snapshot,
        provider: :codex,
        backend: :app_server,
        account_generation_binding: binding,
        auth_mode: :subscription,
        observed_at: @now,
        source: :synthetic,
        source_version: 1,
        windows: []
      },
      Map.new(overrides)
    )
  end

  defp tombstone(binding, limit_id, observed_at, source_version) do
    %{
      schema_version: 1,
      update_kind: :tombstone,
      provider: :codex,
      backend: :app_server,
      account_generation_binding: binding,
      observed_at: observed_at,
      source: :synthetic,
      source_version: source_version,
      limit_id: limit_id
    }
  end

  defp window(limit_id, overrides \\ []) do
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

  defp coverage_window(limit_id, coverage, overrides \\ []) do
    window(limit_id, coverage: coverage)
    |> Map.delete(:used_percent)
    |> Map.merge(Map.new(overrides))
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

  defp bound_binding(owner) do
    assert {:ok, binding} = ProviderAccountGeneration.issue_binding(owner, :codex, :app_server)

    assert {:ok, %{generation: generation}} =
             ProviderAccountGeneration.bind(owner, :codex, :app_server, binding,
               source: :codex_app_server,
               auth_mode: "chatgpt"
             )

    assert is_binary(generation)
    binding
  end

  defp ensure_pubsub do
    unless Process.whereis(Aiur.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end
  end

  defp sequence_mint do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      "generation-#{:counters.get(counter, 1)}"
    end
  end
end
