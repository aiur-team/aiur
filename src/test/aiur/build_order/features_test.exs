defmodule Aiur.BuildOrder.FeaturesTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Features, ProviderHealth}

  @now ~U[2026-10-08 10:00:00Z]
  @hues [175, 55, 285, 128, 232, 18, 330, 80, 250, 150, 272]

  setup do
    dir = Aiur.TestSupport.tmp_root!("features")
    on_exit(fn -> File.rm_rf!(dir) end)
    pid = start_store(dir)
    %{dir: dir, pid: pid, meta: meta(pid)}
  end

  test "V-1 state survives a restart", %{pid: pid, dir: dir, meta: m} do
    create("a", m)
    create("b", m)
    assert {:ok, _} = Features.add("a", [1, 2, 3], m)
    assert {:ok, _} = Features.add("b", [4, 5], m)
    assert {:ok, _} = Features.also("b", [1], m)
    assert {:ok, _} = Features.set_baseline("a", m)
    assert {:ok, before} = Features.snapshot(server: pid)
    GenServer.stop(pid)
    replayed = start_store(dir)
    assert {:ok, after_restart} = Features.snapshot(server: replayed)
    assert Map.drop(after_restart, [:health]) == Map.drop(before, [:health])
    assert ProviderHealth.usable?(after_restart.health)
    assert Bitwise.band(File.stat!(Path.join(dir, "features.ndjson")).mode, 0o777) == 0o600
  end

  test "V-2 auto hue is stable, from the design palette, and avoids open features", %{pid: pid, dir: dir, meta: m} do
    create("a", m)
    assert {:ok, first} = Features.snapshot(server: pid)
    hue = first.features["a"].hue
    assert hue in @hues
    other = start_store(Path.join(dir, "other"))
    create("a", meta(other))
    assert {:ok, second} = Features.snapshot(server: other)
    assert second.features["a"].hue == hue
    for n <- 1..10, do: create("f#{n}", m)
    assert {:ok, filled} = Features.snapshot(server: pid)
    assert filled.features |> Map.values() |> Enum.map(& &1.hue) |> Enum.sort() == Enum.sort(@hues)
    create("overflow", m)
    assert {:ok, overflow} = Features.snapshot(server: pid)
    index = :binary.decode_unsigned(binary_part(:crypto.hash(:sha256, "overflow"), 0, 4)) |> rem(length(@hues))
    assert overflow.features["overflow"].hue == Enum.at(@hues, index)
    assert {:ok, _} = Features.create("explicit", %{label: "Explicit", hue: 7}, m)
    assert {:ok, explicit} = Features.snapshot(server: pid)
    assert explicit.features["explicit"].hue == 7
    assert explicit.features["explicit"].hue_source == :explicit
  end

  test "V-2 custom general hues exclude nearby palette hues; exhausted palette falls back", %{dir: dir} do
    pid = start_store(Path.join(dir, "custom-general"), general_epics: [%{key: "tech_debt", hue: 175}, %{key: String.duplicate("long", 20), hue: 175}])
    for n <- 1..11, do: create("custom-#{n}", meta(pid))
    assert {:ok, snapshot} = Features.snapshot(server: pid)

    for feature <- Map.values(snapshot.features) do
      distance = abs(feature.hue - 175)
      assert min(distance, 360 - distance) > 15
      assert feature.hue in @hues
    end

    assert {:ok, _} = Features.add_epic("custom-1", %{key: "f-extra", label: "Extra"}, meta(pid))
    all_blocked = Enum.map(@hues, &%{key: "general-#{&1}", hue: &1})
    fallback = start_store(Path.join(dir, "all-blocked"), general_epics: all_blocked)
    create("fallback", meta(fallback))
    assert {:ok, fallback_snapshot} = Features.snapshot(server: fallback)
    assert fallback_snapshot.features["fallback"].hue in @hues
  end

  test "V-3 added scope uses baseline membership, including a later rejoin", %{pid: pid, meta: m} do
    create("a", m)
    create("b", m)
    assert {:ok, _} = Features.add("a", [1, 2], m)
    assert {:ok, _} = Features.set_baseline("a", m)
    later = Keyword.put(m, :at, DateTime.add(@now, 60))
    assert {:ok, _} = Features.add("a", [3], later)
    assert {:ok, %{added?: true}} = Features.owner(3, server: pid)
    assert {:ok, %{added?: false}} = Features.owner(1, server: pid)
    assert {:ok, _} = Features.remove("a", [1], later)
    assert {:ok, _} = Features.add("a", [1], later)
    assert {:ok, %{added?: false}} = Features.owner(1, server: pid)
    assert {:ok, _} = Features.add("b", [4], m)
    assert {:ok, %{added?: false}} = Features.owner(4, server: pid)
    assert {:ok, snapshot} = Features.snapshot(server: pid)
    assert snapshot.features["b"].baseline == :none
  end

  test "V-4 a conflicting owner rejects the entire batch", %{pid: pid, dir: dir, meta: m} do
    create("a", m)
    create("b", m)
    assert {:ok, _} = Features.add("a", [5], m)
    before = File.read!(Path.join(dir, "features.ndjson"))
    assert {:error, {:owned_elsewhere, [{5, "a"}]}} = Features.add("b", [4, 5], m)
    assert :none = Features.owner(4, server: pid)
    assert File.read!(Path.join(dir, "features.ndjson")) == before
  end

  test "V-5 move journals both sides with provenance; V-6 no-op appends and signals nothing", %{pid: pid, dir: dir, meta: m} do
    create("a", m)
    create("b", m)
    assert {:ok, _} = Features.add("a", [5], m)
    assert :ok = Features.subscribe()
    move = Keyword.merge(m, move: true, source: "agent:2750", actor: "its-applekid")
    assert {:ok, %{generation: generation}} = Features.add("b", [5], move)
    # barrier: the synchronous write broadcasts before replying.
    assert_received {:build_order_features_changed, %{generation: ^generation}}
    assert {:ok, %{feature: "b"}} = Features.owner(5, server: pid)
    assert {:ok, a_events} = Features.journal("a", server: pid)
    assert {:ok, b_events} = Features.journal("b", server: pid)
    assert List.last(a_events).type == "member.removed"
    assert List.last(a_events).reason == "move"
    assert List.last(b_events).type == "member.added"

    for event <- [List.last(a_events), List.last(b_events)] do
      assert event.source == "agent:2750"
      assert event.actor == "its-applekid"
      assert event.recorded_at == @now
      assert is_integer(event.seq) and event.seq > 0
    end

    before = File.read!(Path.join(dir, "features.ndjson"))
    assert {:ok, %{changed: [], generation: ^generation}} = Features.add("b", [5], move)
    assert File.read!(Path.join(dir, "features.ndjson")) == before
    refute_received {:build_order_features_changed, _}
  end

  test "V-13 rename keeps immutable slug and membership", %{pid: pid, meta: m} do
    create("a", m)
    assert {:ok, _} = Features.add("a", [1], m)
    assert {:ok, owner} = Features.owner(1, server: pid)
    assert {:ok, _} = Features.update_feature("a", %{label: "Auth v3"}, m)
    assert {:ok, snapshot} = Features.snapshot(server: pid)
    assert snapshot.features["a"].slug == "a"
    assert snapshot.features["a"].label == "Auth v3"
    assert {:ok, ^owner} = Features.owner(1, server: pid)
    assert {:ok, events} = Features.journal("a", server: pid)
    assert List.last(events).type == "feature.updated"
  end

  test "V-14 also-only features and dropping an also-link on ownership", %{pid: pid, meta: m} do
    create("a", m)
    create("c", m)
    assert {:ok, _} = Features.also("c", [7, 8], m)
    assert {:ok, snapshot} = Features.snapshot(server: pid)
    assert snapshot.also[7] == ["c"]
    assert :none = Features.owner(7, server: pid)
    assert {:ok, _} = Features.add("a", [1], m)
    assert {:error, {:owner_cannot_also, [1]}} = Features.also("a", [1], m)
    assert {:ok, _} = Features.add("c", [7], m)
    assert {:ok, after_add} = Features.snapshot(server: pid)
    assert Map.get(after_add.also, 7, []) == []
    assert {:ok, _} = Features.also("c", [8], Keyword.put(m, :remove, true))
    assert {:ok, after_remove} = Features.snapshot(server: pid)
    assert Map.get(after_remove.also, 8, []) == []
  end

  test "V-17 backfill defaults unconfirmed and cannot downgrade or move a confirmed owner", %{pid: pid, dir: dir, meta: m} do
    create("a", m)
    create("b", m)
    backfill = Keyword.merge(m, source: "backfill-agent", at: DateTime.add(@now, -3600), at_basis: :first_observed)
    assert {:ok, _} = Features.add("a", [1], backfill)
    assert {:ok, original} = Features.owner(1, server: pid)
    refute original.confirmed
    assert {:ok, _} = Features.add("a", [1], Keyword.put(m, :confirmed, true))
    assert {:ok, confirmed} = Features.owner(1, server: pid)
    assert confirmed.confirmed
    assert confirmed.joined_at == DateTime.add(@now, -3600)
    assert confirmed.at_basis == :first_observed
    assert confirmed.joined_at == original.joined_at
    before = File.read!(Path.join(dir, "features.ndjson"))
    assert {:ok, %{changed: []}} = Features.add("a", [1], backfill)
    assert {:ok, ^confirmed} = Features.owner(1, server: pid)
    assert File.read!(Path.join(dir, "features.ndjson")) == before
    assert {:error, {:owned_elsewhere, [{1, "a"}]}} = Features.add("b", [1], Keyword.put(backfill, :move, true))
  end

  test "V-18 unavailable reads never claim no owner" do
    assert {:error, %ProviderHealth{failure: :features_not_running}} = Features.owner(1, server: :features_test_missing)
  end

  test "V-19 broadcasts the changed membership pairs and new generation", %{pid: pid, meta: m} do
    create("a", m)
    assert :ok = Features.subscribe()
    previous = Features.health(server: pid).generation
    assert {:ok, %{generation: generation}} = Features.add("a", [3, 9], m)
    assert generation == previous + 1
    # barrier: the synchronous write broadcasts before replying.
    assert_received {:build_order_features_changed, %{changed: [3, 9], slugs: ["a"], pairs: [{"a", 3}, {"a", 9}], generation: ^generation}}
  end

  test "V-21 imported unknown times remain unknown through replay", %{pid: pid, dir: dir, meta: m} do
    assert {:ok, _} = Features.create("bo-1", %{label: "R", from: :unknown, to: :unknown}, m)
    assert {:ok, _} = Features.add("bo-1", [4], Keyword.merge(m, at: :unknown, source: "import:build-order", actor: "import"))
    assert File.read!(Path.join(dir, "features.ndjson")) =~ "\"unknown\""
    GenServer.stop(pid)
    replayed = start_store(dir)
    assert {:ok, snapshot} = Features.snapshot(server: replayed)
    assert snapshot.features["bo-1"].from == :unknown
    assert snapshot.features["bo-1"].to == :unknown
    assert snapshot.owners[4].joined_at == :unknown
  end

  test "V-22 memberships contain current owners only and epic updates keep joined_at", %{pid: pid, dir: dir, meta: m} do
    create("a", m)
    assert {:ok, _} = Features.add_epic("a", %{key: "f-a2", label: "Second"}, m)
    assert {:ok, _} = Features.add("a", [6, 7], m)
    assert {:ok, _} = Features.remove("a", [6], m)
    GenServer.stop(pid)
    replayed = start_store(dir)
    assert {:ok, [member]} = Features.memberships(server: replayed)
    assert member.slug == "a"
    assert member.number == 7
    assert member.joined_at == @now
    assert member.source == "cli:executor"
    assert member.confirmed
    assert {:ok, _} = Features.add("a", [7], Keyword.merge(meta(replayed), epic: "f-a2", at: DateTime.add(@now, 60)))
    assert {:ok, owner} = Features.owner(7, server: replayed)
    assert owner.epic == "f-a2"
    assert owner.joined_at == member.joined_at
  end

  test "V-23 epic relabel preserves keys and owners and rejects unknown keys", %{pid: pid, meta: m} do
    create("a", m)
    assert {:ok, _} = Features.add("a", [1], m)
    assert {:ok, owner} = Features.owner(1, server: pid)
    assert {:ok, _} = Features.update_feature("a", %{epics: [%{key: "f-a", label: "A · core"}]}, m)
    assert {:ok, snapshot} = Features.snapshot(server: pid)
    assert snapshot.features["a"].epics == [%{key: "f-a", label: "A · core"}]
    assert {:ok, ^owner} = Features.owner(1, server: pid)
    assert {:error, {:unknown_epic, "f-x"}} = Features.update_feature("a", %{epics: [%{key: "f-x", label: "X"}]}, m)
  end

  test "V-24 baseline replacement requires explicit consent", %{pid: pid, meta: m} do
    create("a", m)
    assert {:ok, _} = Features.add("a", [1], m)
    assert {:ok, _} = Features.set_baseline("a", m)
    assert {:error, {:baseline_exists, @now}} = Features.set_baseline("a", m)
    assert {:ok, _} = Features.add("a", [2], m)
    assert {:ok, _} = Features.set_baseline("a", Keyword.put(m, :replace, true))
    assert {:ok, snapshot} = Features.snapshot(server: pid)
    assert snapshot.features["a"].baseline.members == MapSet.new([1, 2])
    assert {:ok, events} = Features.journal("a", server: pid)
    assert Enum.count(events, &(&1.type == "baseline.set")) == 2
  end

  defp create(slug, m), do: assert({:ok, _} = Features.create(slug, %{label: String.upcase(slug)}, m))
  defp meta(pid), do: [server: pid, source: "cli:executor", actor: "executor"]

  defp start_store(dir, extra \\ []) do
    start_supervised!(
      {Features,
       Keyword.merge(
         [
           name: nil,
           state_dir: dir,
           clock: fn -> @now end,
           filesystem_sync_fun: fn -> :ok end,
           general_epics: [%{key: "bugs", hue: 38}, %{key: "ideas", hue: 312}, %{key: "engineering", hue: 200}, %{key: "ops", hue: 100}],
           alert_fun: fn _, _, _ -> :ok end
         ],
         extra
       )},
      id: make_ref(),
      restart: :temporary
    )
  end
end
