defmodule Aiur.BuildOrder.FeaturesValidationTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Aiur.BuildOrder.Features
  @now ~U[2026-10-08 10:00:00Z]

  setup do
    dir = Aiur.TestSupport.tmp_root!("features-validation")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "V-15 general, reserved and existing feature epic keys cannot be reused", %{dir: dir} do
    pid = start_store(dir)
    m = meta(pid)
    assert {:ok, _} = Features.create("a", %{label: "A"}, m)

    for key <- ["bugs", "unsorted", "f-a"] do
      assert {:error, {:epic_key_taken, ^key}} = Features.create("x", %{label: "X", epics: [%{key: key, label: "Epic"}]}, m)
      assert {:error, {:epic_key_taken, ^key}} = Features.add_epic("a", %{key: key, label: "Epic"}, m)
    end

    GenServer.stop(pid)
  end

  test "V-16 invalid inputs and backfill also-links append nothing", %{dir: dir} do
    pid = start_store(dir)
    m = meta(pid)
    assert {:ok, _} = Features.create("a", %{label: "A"}, m)
    before = File.read!(Path.join(dir, "features.ndjson"))

    for slug <- ["Bad Slug", String.duplicate("a", 43)] do
      assert {:error, :invalid_slug} = Features.create(slug, %{label: "A"}, m)
    end

    assert {:error, :invalid_label} = Features.create("x", %{label: "bad\nlabel"}, m)
    assert {:error, :invalid_hue} = Features.create("x", %{label: "X", hue: 360}, m)
    assert {:error, :invalid_public_ref} = Features.create("x", %{label: "X", public_ref: "X-1"}, m)
    assert {:error, :invalid_meta} = Features.also("a", [1], server: pid, source: "backfill-agent", source: "cli:executor", actor: "executor")
    assert {:error, :invalid_meta} = Features.add("a", [1], %{})
    assert {:error, :invalid_meta} = Features.add("a", [1], [:bad])
    assert {:error, :invalid_source} = Features.add("a", [1], Keyword.put(m, :source, "web"))
    assert {:error, :invalid_number} = Features.add("a", [0], m)
    assert {:error, :batch_too_large} = Features.add("a", Enum.to_list(1..1001), m)
    assert {:error, :at_in_future} = Features.add("a", [1], Keyword.put(m, :at, DateTime.add(@now, 600)))
    assert {:error, :at_in_future} = Features.add("a", [1], Keyword.put(m, :at, DateTime.add(@now, 300_000_001, :microsecond)))
    assert {:error, :backfill_also_refused} = Features.also("a", [1], Keyword.put(m, :source, "backfill-agent"))
    assert {:error, {:unknown_feature, "missing"}} = Features.add("missing", [1], m)
    assert {:error, {:unknown_epic, "missing"}} = Features.add("a", [1], Keyword.put(m, :epic, "missing"))
    assert {:error, {:not_member, [1]}} = Features.remove("a", [1], m)
    assert File.read!(Path.join(dir, "features.ndjson")) == before
    GenServer.stop(pid)
  end

  test "journal decoding rejects unknown fields, nulls, types and non-UTC dates" do
    alias Aiur.BuildOrder.Features.Journal
    event = %{"type" => "member.added", "feature" => "a", "number" => 1, "epic" => "f-a", "at" => "unknown", "at_basis" => "first_observed", "confirmed" => true}
    record = %{"v" => 1, "seq" => 1, "recorded_at" => "2026-10-08T10:00:00Z", "source" => "label:unknown", "actor" => "executor", "events" => [event]}
    assert {:ok, decoded} = Journal.validate(record)
    assert hd(decoded.events).at == :unknown
    assert hd(decoded.events).at_basis == :first_observed

    invalid = [
      Map.put(record, "extra", 1),
      Map.put(record, "actor", nil),
      Map.put(record, "actor", <<255>>),
      Map.put(record, "source", "web"),
      Map.put(record, "seq", "1"),
      Map.put(record, "recorded_at", "2026-10-08T10:00:00+01:00"),
      Map.put(record, "events", [Map.put(event, "type", "invented")]),
      Map.put(record, "events", [Map.put(event, "number", nil)]),
      Map.put(record, "events", [Map.put(event, "confirmed", "true")]),
      Map.put(record, "events", [Map.put(event, "extra", 1)])
    ]

    for bad <- invalid, do: assert({:error, _} = Journal.validate(bad))
    assert {:error, :version_unsupported} = Journal.validate(Map.put(record, "v", 2))
  end

  # Each generated operation crosses real disk barriers and then replays the journal.
  @tag timeout: :infinity
  property "V-12 invariants and replay equality hold after random operation sequences", %{dir: dir} do
    operation = tuple({member_of([:add, :remove, :also, :unalso, :move, :baseline]), member_of(["a", "b", "c"]), integer(1..10)})

    check all(operations <- list_of(operation, min_length: 1, max_length: 40), max_runs: 200) do
      state_dir = Path.join(dir, "run-#{System.unique_integer([:positive])}")
      pid = start_store(state_dir)

      try do
        for slug <- ["a", "b", "c"], do: assert({:ok, _} = Features.create(slug, %{label: slug}, meta(pid)))

        for {operation, slug, number} <- operations do
          apply_operation(operation, slug, number, pid)
          assert {:ok, snapshot} = Features.snapshot(server: pid)
          assert_invariants(snapshot)
          {:ok, replayed} = Features.start_link(store_options(state_dir))

          try do
            assert {:ok, recovered} = Features.snapshot(server: replayed)
            assert Map.drop(recovered, [:health]) == Map.drop(snapshot, [:health])
          after
            GenServer.stop(replayed)
          end
        end
      after
        GenServer.stop(pid)
        File.rm_rf!(state_dir)
      end
    end
  end

  defp assert_invariants(snapshot) do
    keys = for {_slug, feature} <- snapshot.features, epic <- feature.epics, do: epic.key
    assert Enum.uniq(keys) == keys
    refute "unsorted" in keys

    for {number, owner} <- snapshot.owners do
      assert owner.feature in Map.keys(snapshot.features)
      assert owner.epic in Enum.map(snapshot.features[owner.feature].epics, & &1.key)
      refute owner.feature in Map.get(snapshot.also, number, [])
    end

    assert Enum.all?(Map.keys(snapshot.owners), &(&1 in 1..10))
  end

  defp apply_operation(:add, slug, n, pid), do: Features.add(slug, [n], meta(pid))
  defp apply_operation(:remove, slug, n, pid), do: Features.remove(slug, [n], meta(pid))
  defp apply_operation(:also, slug, n, pid), do: Features.also(slug, [n], meta(pid))
  defp apply_operation(:unalso, slug, n, pid), do: Features.also(slug, [n], Keyword.put(meta(pid), :remove, true))
  defp apply_operation(:move, slug, n, pid), do: Features.add(slug, [n], Keyword.put(meta(pid), :move, true))
  defp apply_operation(:baseline, slug, _, pid), do: Features.set_baseline(slug, Keyword.put(meta(pid), :replace, true))
  defp meta(pid), do: [server: pid, source: "cli:executor", actor: "executor"]

  defp start_store(dir) do
    {:ok, pid} = Features.start_link(store_options(dir))
    pid
  end

  defp store_options(dir) do
    [name: nil, state_dir: dir, clock: fn -> @now end, filesystem_sync_fun: fn -> :ok end, general_epics: [%{key: "bugs", hue: 38}], alert_fun: fn _, _, _ -> :ok end]
  end
end
