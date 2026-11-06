defmodule Aiur.BuildOrder.EpicsTest do
  @moduledoc """
  Epic records: the second journal beside `features.ndjson`, its projection and
  the read-time migration that turns an imported Build Order root into an epic.
  """
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.Features
  alias Aiur.Journal, as: AppendJournal

  @now ~U[2026-11-04 09:00:00Z]
  @limits [max_record_bytes: 1_048_576, max_file_bytes: 16_777_216]

  setup do
    dir = Aiur.TestSupport.tmp_root!("epics")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir, pid: start_store(dir)}
  end

  test "epic writes land in epics.ndjson and leave features.ndjson byte-identical", c do
    meta = meta(c.pid)
    assert {:ok, _} = Features.create("combat", %{label: "Combat"}, meta)
    features_path = Path.join(c.dir, "features.ndjson")
    epic_path = Path.join(c.dir, "epics.ndjson")
    features_before = File.read!(features_path)
    assert File.read!(epic_path) == ""

    assert {:ok, %{changed: ["epic.created"], epic: "combat-pack"}} = Features.epic_create("combat-pack", %{label: "Combat pack", hue: 120}, meta)
    assert {:ok, %{changed: ["epic.feature_added"]}} = Features.epic_add("combat-pack", ["combat"], meta)
    assert {:ok, %{changed: []}} = Features.epic_add("combat-pack", ["combat"], meta)
    assert {:ok, %{changed: []}} = Features.epic_create("combat-pack", %{label: "Combat pack", hue: 120}, meta)

    assert File.read!(features_path) == features_before
    assert length(records(epic_path)) == 2

    assert {:ok, %{epics: epics}} = Features.epics(server: c.pid)
    epic = Enum.find(epics, &(&1.slug == "combat-pack"))
    assert epic.label == "Combat pack"
    assert epic.hue == 120
    assert epic.features == ["combat"]
    assert epic.root == nil
  end

  test "a feature belongs to one epic and the refusal names the first owner", c do
    meta = meta(c.pid)
    assert {:ok, _} = Features.create("khala-srv", %{label: "Khala"}, meta)
    assert {:ok, _} = Features.epic_create("combat", %{label: "Combat"}, meta)
    assert {:ok, _} = Features.epic_create("infra", %{label: "Infra"}, meta)
    assert {:ok, _} = Features.epic_add("combat", ["khala-srv"], meta)
    assert {:error, {:feature_in_epic, "khala-srv", "combat"}} = Features.epic_add("infra", ["khala-srv"], meta)
    assert {:ok, %{features: []}} = Features.epic("infra", server: c.pid)
  end

  test "an older build replaying only features.ndjson keeps every feature and member", c do
    meta = meta(c.pid)
    assert {:ok, _} = Features.create("combat", %{label: "Combat"}, meta)
    assert {:ok, _} = Features.add("combat", [1, 2], meta)
    assert {:ok, _} = Features.epic_create("combat-pack", %{label: "Combat pack"}, meta)
    assert {:ok, _} = Features.epic_add("combat-pack", ["combat"], meta)
    assert {:ok, snapshot} = Features.snapshot(server: c.pid)

    # The pre-epic read path: the v1 journal alone, as the previous build boots.
    path = Path.join(c.dir, "features.ndjson")
    assert {:ok, records, nil} = AppendJournal.replay(path, &Features.Journal.validate/1, @limits)
    projection = Enum.reduce(records, Features.Journal.empty(), fn record, acc -> elem(Features.Journal.fold(acc, record), 1) end)
    assert projection.features == snapshot.features
    assert projection.owners == snapshot.owners
  end

  test "a journal with an imported root feature projects as an epic with lane assignments", c do
    import_meta = [server: c.pid, source: "import:build-order", actor: "import"]
    lanes = [%{key: "f-bo-12-combat", label: "Combat", icon: "bug-ant"}]
    assert {:ok, _} = Features.create("bo-12", %{label: "Combat pack", epics: lanes}, import_meta)
    assert {:ok, _} = Features.add("bo-12", [40, 41], import_meta ++ [epic: "f-bo-12-combat"])

    path = Path.join(c.dir, "features.ndjson")
    before = File.read!(path)
    GenServer.stop(c.pid)
    pid = start_store(c.dir)

    assert File.read!(path) == before
    assert {:ok, %{epics: epics}} = Features.epics(server: pid)
    epic = Enum.find(epics, &(&1.slug == "bo-12"))
    assert epic.root == 12
    assert epic.label == "Combat pack"
    assert [%{key: "f-bo-12-combat", lane: "combat", label: "Combat", icon: "bug-ant", members: [40, 41]}] = epic.lanes
  end

  test "epic reads report an unavailable epic file without hiding the features", c do
    meta = meta(c.pid)
    assert {:ok, _} = Features.create("combat", %{label: "Combat"}, meta)
    File.write!(Path.join(c.dir, "epics.ndjson"), "{bad\n")
    pid = start_store(c.dir)

    assert {:error, health} = Features.epics(server: pid)
    assert health.failure == :epics_corrupt
    assert {:ok, snapshot} = Features.snapshot(server: pid)
    assert Map.has_key?(snapshot.features, "combat")
    assert snapshot.epic_health.failure == :epics_corrupt
  end

  defp meta(pid), do: [server: pid, source: "cli:executor", actor: "executor"]

  defp records(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp start_store(dir) do
    start_supervised!(
      {Features,
       name: nil, state_dir: dir, clock: fn -> @now end, filesystem_sync_fun: fn -> :ok end, general_epics: [%{key: "bugs", hue: 38}, %{key: "ideas", hue: 312}], alert_fun: fn _, _, _ -> :ok end},
      id: make_ref(),
      restart: :temporary
    )
  end
end
