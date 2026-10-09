defmodule Aiur.BuildOrder.EpicOverridesTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Aiur.BuildOrder.EpicOverrides, as: Store
  @p %{actor: "cli:kevin", source: "cli:kevin"}
  @time ~U[2026-10-08 10:00:00Z]

  setup do
    dir = Aiur.TestSupport.tmp_root!("epic-overrides")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    opts = [name: name, state_dir: dir, repository: "acme/app", settings_fun: fn -> settings() end]
    %{dir: dir, path: Path.join(dir, "epic-overrides.json"), opts: opts, read: [server: name], write: [server: name, now: @time]}
  end

  defp settings(keys \\ ["bugs", "infra", "docs", "unsorted"]), do: {:ok, %{build_order: %{general_epics: Enum.map(keys, &%{key: &1, label: String.capitalize(&1)})}}}
  defp start(ctx, extra \\ []), do: start_supervised!({Store, Keyword.merge(ctx.opts, extra)})

  defp raw(ctx, changes) do
    record = Map.merge(%{version: 1, repository: "acme/app", next_seq: 1, entries: []}, changes)
    File.write!(ctx.path, Jason.encode!(record))
  end

  test "V-1 set journals every provenance field and deduplicates ids", c do
    start(c)
    assert Aiur.BuildOrder.ProviderHealth.usable?(Store.health(c.read))
    assert {:ok, %{generation: 1, results: [%{number: 12, status: :changed, previous: nil}]}} = Store.set("bugs", [12, "#12"], @p, c.write)
    assert {:ok, %{12 => o}, h} = Store.get_many([12], c.read)
    assert Map.from_struct(o) == %{number: 12, epic: "bugs", actor: "cli:kevin", source: "cli:kevin", confirmed: true, at: @time, seq: 1}
    assert h.state == :healthy and h.complete?

    assert Jason.decode!(File.read!(c.path))["entries"] == [
             %{"op" => "set", "number" => 12, "epic" => "bugs", "actor" => "cli:kevin", "source" => "cli:kevin", "confirmed" => true, "at" => "2026-10-08T10:00:00Z", "seq" => 1}
           ]

    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
  end

  test "V-2 V-3 V-4 reject unknown, reserved and invalid batch inputs without writes", c do
    start(c)
    assert {:error, {:unknown_epic, "bugz", ["bugs", "infra", "docs", "unsorted"]}} = Store.set("bugz", [12], @p, c.write)
    assert {:error, {:unknown_epic, "unsorted", _}} = Store.set("unsorted", [12], @p, c.write)

    for ids <- [[12, 0], [12, "abc"], [12, -1], [12, 10_000_000_000], []] do
      assert {:error, :invalid_epic_arguments} = Store.set("bugs", ids, @p, c.write)
    end

    assert {:ok, empty, _} = Store.all(c.read)
    assert empty == %{}
    refute File.exists?(c.path)
    assert {:error, :invalid_epic_arguments} = Store.set(nil, [12], @p, c.write)
    assert {:error, :invalid_epic_arguments} = Store.set("bugs", [12], Map.put(@p, :extra, true), c.write)
    assert {:error, :invalid_epic_arguments} = Store.set("bugs", [12], %{actor: "cli:", source: "cli:"}, c.write)
  end

  test "V-5 concurrent writes retain both entries and the later sequence wins", c do
    start(c)
    tasks = for epic <- ["bugs", "infra"], do: Task.async(fn -> Store.set(epic, [12], %{actor: "agent:77", source: "agent:77"}, c.write) end)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.sort(Enum.map(results, fn {:ok, r} -> r.generation end)) == [1, 2]
    assert {:ok, entries} = Store.journal([12], c.read)
    assert length(entries) == 2
    assert {:ok, %{12 => current}, _} = Store.all(c.read)
    assert current.epic == List.last(entries).epic
    assert current.seq == 2
    assert {:ok, %{results: [%{previous: %{seq: 1}}]}} = Enum.find(results, fn {:ok, r} -> r.generation == 2 end)
  end

  test "V-6 V-7 V-8 no-op is not journaled but source change confirms backfill", c do
    start(c)
    p = %{actor: "agent:77", source: "backfill-agent"}
    assert {:ok, %{generation: 1}} = Store.set("bugs", [12], p, c.write)
    assert {:ok, %{12 => %{confirmed: false}}, _} = Store.all(c.read)
    assert {:ok, %{generation: 1, results: [%{status: :unchanged}]}} = Store.set("bugs", [12], p, c.write)
    assert {:ok, %{generation: 2, results: [%{status: :changed, previous: %{confirmed: false}}]}} = Store.set("bugs", [12], @p, c.write)
    assert {:ok, %{12 => %{confirmed: true, source: "cli:kevin"}}, _} = Store.all(c.read)
    assert {:ok, entries} = Store.journal([12], c.read)
    assert length(entries) == 2
  end

  test "V-9 V-10 restart folds clears and preserves journal generation", c do
    start(c)
    Store.set("bugs", [12], @p, c.write)
    Store.set("infra", [13], @p, c.write)
    assert {:ok, %{generation: 3}} = Store.clear([13], @p, c.write)
    bytes = File.read!(c.path)
    assert {:ok, %{generation: 3, results: [%{status: :unchanged}]}} = Store.clear([13], @p, c.write)
    assert File.read!(c.path) == bytes
    stop_supervised!(Store)
    start(c)
    assert {:ok, overrides, %{generation: 3}} = Store.all(c.read)
    assert Map.keys(overrides) == [12]
    assert overrides[12].epic == "bugs"
    assert {:ok, [%{"op" => "set"}, %{"op" => "clear"}]} = Store.journal([13], c.read)
    assert {:ok, %{generation: 4}} = Store.set("docs", [14], @p, c.write)
  end

  test "V-11 corrupt file stays untouched and refuses all reads and writes", c do
    File.write!(c.path, "{bad")
    start(c)
    assert {:error, %{state: :unavailable, failure: :epic_overrides_corrupt}} = Store.get_many([12], c.read)
    assert {:error, %{failure: :epic_overrides_corrupt}} = Store.journal([12], c.read)
    assert {:error, :epic_overrides_unavailable} = Store.set("bugs", [12], @p, c.write)
    assert File.read!(c.path) == "{bad"
  end

  for {label, changes, failure} <- [
        {"V-12 newer version", %{version: 2}, :epic_overrides_version_unsupported},
        {"V-13 foreign repository", %{repository: "other/app"}, :epic_overrides_repository_mismatch},
        {"unknown op", %{next_seq: 2, entries: [%{op: "confirm"}]}, :epic_overrides_version_unsupported},
        {"bad next seq", %{next_seq: 2}, :epic_overrides_corrupt},
        {"malformed entry", %{next_seq: 2, entries: [%{op: "set"}]}, :epic_overrides_corrupt}
      ] do
    test "#{label} refuses load and preserves bytes", c do
      raw(c, unquote(Macro.escape(changes)))
      bytes = File.read!(c.path)
      start(c)
      assert {:error, %{failure: unquote(failure)}} = Store.all(c.read)
      assert {:error, :epic_overrides_unavailable} = Store.clear([12], @p, c.write)
      assert File.read!(c.path) == bytes
    end
  end

  test "V-14 unsafe symlink and oversized input are refused", c do
    target = Path.join(c.dir, "target")
    File.write!(target, "{}")
    File.ln_s!(target, c.path)
    start(c)
    assert Store.health(c.read).failure == :epic_overrides_unsafe_path
    assert File.read!(target) == "{}"
    stop_supervised!(Store)
    File.rm!(c.path)
    File.write!(c.path, String.duplicate(" ", 20))
    start(c, max_bytes: 10)
    assert Store.health(c.read).failure == :epic_overrides_unsafe_path
  end

  test "V-15 absent server is unavailable", c do
    assert {:error, %{failure: :epic_overrides_not_running}} = Store.get_many([1], c.read)
    assert {:error, :epic_overrides_not_running} = Store.set("bugs", [1], @p, c.write)
  end

  test "V-16 failing writer leaves memory and generation unchanged", c do
    start(c,
      writer: fn _path, _bytes, opts ->
        assert opts == [fsync: true, mode: 0o600]
        {:error, :enospc}
      end
    )

    assert {:error, {:write_failed, :enospc}} = Store.set("bugs", [12], @p, c.write)
    assert {:ok, empty, %{generation: 0}} = Store.all(c.read)
    assert empty == %{}
    refute File.exists?(c.path)
  end

  test "V-18 size cap preserves prior bytes and state", c do
    start(c, max_bytes: 300)
    assert {:ok, %{generation: 1}} = Store.set("bugs", [12], @p, c.write)
    bytes = File.read!(c.path)
    assert {:error, :epic_overrides_full} = Store.set("infra", [13], @p, c.write)
    assert File.read!(c.path) == bytes
    assert {:ok, overrides, %{generation: 1}} = Store.all(c.read)
    assert Map.keys(overrides) == [12]
  end

  test "V-19 only committed changes broadcast", c do
    start(c)
    Store.subscribe()
    Store.set("bugs", [12, 13], @p, c.write)
    assert_receive {:epic_overrides_changed, %{generation: 2, changed: [12, 13], health: %{state: :healthy}}}, 1000
    Store.set("bugs", [12, 13], @p, c.write)
    refute_receive {:epic_overrides_changed, _}, 30
  end

  test "V-20 id cap allows 200 and rejects 201 atomically", c do
    start(c)
    assert {:error, {:too_many_ids, 200}} = Store.set("bugs", Enum.to_list(1..201), @p, c.write)
    refute File.exists?(c.path)
    assert {:ok, %{generation: 200}} = Store.set("bugs", Enum.to_list(1..200), @p, c.write)
  end

  test "V-30 V-31 catalog reload is read on every write and errors never fall back", c do
    {:ok, config} = Agent.start_link(fn -> settings(["ops"]) end)
    start(c, settings_fun: fn -> Agent.get(config, & &1) end)
    assert {:ok, _} = Store.set("ops", [12], @p, c.write)
    assert {:error, {:unknown_epic, "bugs", ["ops"]}} = Store.set("bugs", [12], @p, c.write)
    bytes = File.read!(c.path)
    Agent.update(config, fn _ -> {:error, :boom} end)
    assert {:error, :epic_config_unavailable} = Store.set("ops", [12], @p, c.write)
    assert {:error, :epic_config_unavailable} = Store.catalog(c.read)
    assert File.read!(c.path) == bytes
    Agent.update(config, fn _ -> settings(["bugs"]) end)
    assert {:ok, _} = Store.set("bugs", [12], @p, c.write)
  end

  test "V-32 init survives bad state directory and unsupported tracker", c do
    file = Path.join(c.dir, "file")
    File.write!(file, "keep")
    start(c, state_dir: file)
    assert Store.health(c.read).failure == :epic_overrides_state_dir_unavailable
    stop_supervised!(Store)
    start(c, repository: nil)
    assert Store.health(c.read).failure == :epic_overrides_unsupported_tracker
  end
end
