defmodule Aiur.BuildOrder.FeaturesPersistenceTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Features, ProviderHealth}
  @now ~U[2026-10-08 10:00:00Z]

  setup do
    dir = Aiur.TestSupport.tmp_root!("features-persistence")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "V-7 corrupt complete lines refuse prefix reads and writes", %{dir: dir} do
    pid = seeded(dir)
    GenServer.stop(pid)
    path = Path.join(dir, "features.ndjson")
    File.write!(path, "{\"v\":1,\"seq\":3,\"bogus\":1}\n", [:append])
    before = File.read!(path)
    parent = self()
    replayed = start_store(dir, alert_fun: fn name, message, opts -> send(parent, {:alert, name, message, opts}) end)
    assert {:error, %ProviderHealth{state: :structurally_invalid, failure: :features_corrupt}} = Features.snapshot(server: replayed)
    assert {:error, %ProviderHealth{failure: :features_corrupt}} = Features.owner(1, server: replayed)
    assert {:error, :features_corrupt} = Features.add("a", [2], meta(replayed))
    assert File.read!(path) == before
    # barrier: start_link completes replay and its alert before returning.
    assert_received {:alert, "build_features.corrupted", _, _}
    refute_received {:alert, _, _, _}
  end

  test "V-8 newer newline-terminated journal versions remain untouched", %{dir: dir} do
    pid = seeded(dir)
    GenServer.stop(pid)
    path = Path.join(dir, "features.ndjson")
    [first, second] = records(path)
    File.write!(path, Jason.encode!(first) <> "\n" <> Jason.encode!(Map.put(second, "v", 2)) <> "\n")
    before = File.read!(path)
    replayed = start_store(dir)
    assert {:error, %ProviderHealth{state: :unavailable, failure: :version_unsupported}} = Features.snapshot(server: replayed)
    assert {:error, :version_unsupported} = Features.add("a", [2], meta(replayed))
    GenServer.stop(replayed)
    assert File.read!(path) == before
  end

  test "V-9 a torn tail is truncated while acknowledged earlier records survive", %{dir: dir} do
    pid = seeded(dir)
    assert {:ok, before} = Features.snapshot(server: pid)
    GenServer.stop(pid)
    path = Path.join(dir, "features.ndjson")
    intact = File.read!(path)
    File.write!(path, "{\"v\":1,\"seq\":3", [:append])
    replayed = start_store(dir)
    assert {:ok, after_restart} = Features.snapshot(server: replayed)
    assert Map.drop(before, [:health]) == Map.drop(after_restart, [:health])
    assert ProviderHealth.usable?(after_restart.health)
    assert File.read!(path) == intact
  end

  test "V-10 append failure preserves acknowledged state and stops retries", %{dir: dir} do
    pid = seeded(dir)
    GenServer.stop(pid)
    parent = self()

    broken =
      start_store(dir,
        append_fun: fn _, _ ->
          send(parent, :append_attempt)
          {:error, :enospc}
        end
      )

    assert {:error, {:journal_append_failed, :enospc}} = Features.add("a", [2], meta(broken))
    # barrier: add returns only after append_fun completed.
    assert_received :append_attempt
    assert :none = Features.owner(2, server: broken)
    assert {:ok, %{feature: "a"}} = Features.owner(1, server: broken)
    assert %ProviderHealth{state: :stale, failure: :journal_append_failed} = Features.health(server: broken)
    assert {:error, :journal_append_failed} = Features.add("a", [2], meta(broken))
    refute_received :append_attempt
    GenServer.stop(broken)
    replayed = start_store(dir)
    assert ProviderHealth.usable?(Features.health(server: replayed))
    assert :none = Features.owner(2, server: replayed)
  end

  test "V-11 symlinked journal and directory are refused without changing targets", %{dir: dir} do
    target = Path.join(dir, "target.ndjson")
    File.write!(target, "original")
    state = Path.join(dir, "state")
    File.mkdir_p!(state)
    File.ln_s!(target, Path.join(state, "features.ndjson"))
    pid = start_store(state)
    assert {:error, %ProviderHealth{failure: :unsafe_path}} = Features.snapshot(server: pid)
    assert {:error, :unsafe_path} = Features.create("a", %{label: "A"}, meta(pid))
    assert File.read!(target) == "original"
    target_dir = Path.join(dir, "target-dir")
    File.mkdir_p!(target_dir)
    symlink = Path.join(dir, "symlink-dir")
    File.ln_s!(target_dir, symlink)
    other = start_store(symlink)
    assert {:error, %ProviderHealth{failure: :unsafe_path}} = Features.snapshot(server: other)
    assert {:error, :unsafe_path} = Features.create("a", %{label: "A"}, meta(other))
    assert File.ls!(target_dir) == []
  end

  test "V-20 pre-append size checks keep the next boot replayable", %{dir: dir} do
    pid = start_store(dir, max_record_bytes: 2_000)
    epics = for n <- 1..30, do: %{key: "f-large-#{n}", label: String.duplicate("L", 80)}
    path = Path.join(dir, "features.ndjson")
    before = File.read!(path)
    assert {:error, :record_too_large} = Features.create("large", %{label: "Large", epics: epics}, meta(pid))
    assert File.read!(path) == before
    assert {:ok, _} = Features.create("a", %{label: "A"}, meta(pid))
    GenServer.stop(pid)
    current = File.read!(path)
    limited = start_store(dir, max_file_bytes: byte_size(current) + 10)
    assert {:error, :features_too_large} = Features.add("a", [1], meta(limited))
    assert File.read!(path) == current
    GenServer.stop(limited)
    replayed = start_store(dir)
    assert ProviderHealth.usable?(Features.health(server: replayed))
  end

  test "V-25 later general epic collisions do not corrupt existing history", %{dir: dir} do
    pid = start_store(dir)
    assert {:ok, _} = Features.create("a", %{label: "A", epics: [%{key: "f-api", label: "API"}]}, meta(pid))
    GenServer.stop(pid)
    replayed = start_store(dir, general_epics: [%{key: "f-api", hue: 10}])
    assert ProviderHealth.usable?(Features.health(server: replayed))
    assert {:ok, snapshot} = Features.snapshot(server: replayed)
    assert snapshot.features["a"].epics == [%{key: "f-api", label: "API"}]
    assert {:error, {:epic_key_taken, "f-api"}} = Features.create("b", %{label: "B", epics: [%{key: "f-api", label: "API"}]}, meta(replayed))
  end

  test "V-26 a fresh store is usable and empty; unreadable epic config refuses writes", %{dir: dir} do
    pid = start_store(dir, general_epics: fn -> {:error, :invalid} end)
    assert %ProviderHealth{generation: 1} = health = Features.health(server: pid)
    assert ProviderHealth.usable?(health)
    assert {:ok, %{features: features, owners: owners}} = Features.snapshot(server: pid)
    assert features == %{}
    assert owners == %{}
    path = Path.join(dir, "features.ndjson")
    before = File.read!(path)
    assert {:error, :epic_config_unavailable} = Features.create("a", %{label: "A"}, meta(pid))
    assert File.read!(path) == before
  end

  test "strict replay refuses sequence gaps, repeats and unknown record fields", %{dir: dir} do
    for {name, modify} <- [
          {"gap", fn record -> Map.put(record, "seq", 4) end},
          {"repeat", fn record -> Map.put(record, "seq", 1) end},
          {"extra", fn record -> Map.put(record, "unexpected", true) end}
        ] do
      state_dir = Path.join(dir, name)
      pid = seeded(state_dir)
      GenServer.stop(pid)
      path = Path.join(state_dir, "features.ndjson")
      [first, second] = records(path)
      bytes = Jason.encode!(first) <> "\n" <> Jason.encode!(modify.(second)) <> "\n"
      File.write!(path, bytes)
      replayed = start_store(state_dir)
      assert {:error, %ProviderHealth{failure: :features_corrupt}} = Features.snapshot(server: replayed)
      assert File.read!(path) == bytes
    end
  end

  test "schema-valid journal events must obey fold invariants", %{dir: dir} do
    for {name, events} <- [
          {"owner-epic", [%{"type" => "member.added", "feature" => "a", "number" => 2, "epic" => "f-missing", "at" => DateTime.to_iso8601(@now), "confirmed" => true}]},
          {"downgrade", [%{"type" => "member.added", "feature" => "a", "number" => 1, "epic" => "f-a", "at" => DateTime.to_iso8601(@now), "confirmed" => false}]},
          {"baseline", [%{"type" => "baseline.set", "feature" => "a", "at" => DateTime.to_iso8601(@now), "members" => [999]}]}
        ] do
      state_dir = Path.join(dir, name)
      pid = seeded(state_dir)
      GenServer.stop(pid)
      path = Path.join(state_dir, "features.ndjson")
      record = %{v: 1, seq: 3, recorded_at: DateTime.to_iso8601(@now), source: "cli:executor", actor: "executor", events: events}
      File.write!(path, Jason.encode!(record) <> "\n", [:append])
      assert {:error, %ProviderHealth{failure: :features_corrupt}} = Features.snapshot(server: start_store(state_dir))
    end
  end

  defp records(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp meta(pid), do: [server: pid, source: "cli:executor", actor: "executor"]

  defp seeded(dir) do
    pid = start_store(dir)
    assert {:ok, _} = Features.create("a", %{label: "A"}, meta(pid))
    assert {:ok, _} = Features.add("a", [1], meta(pid))
    pid
  end

  defp start_store(dir, extra \\ []) do
    {:ok, pid} =
      Features.start_link(
        Keyword.merge(
          [name: nil, state_dir: dir, clock: fn -> @now end, filesystem_sync_fun: fn -> :ok end, general_epics: [%{key: "bugs", hue: 38}], alert_fun: fn _, _, _ -> :ok end],
          extra
        )
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end
end
