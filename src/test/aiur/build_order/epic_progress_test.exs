defmodule Aiur.BuildOrder.EpicProgressTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.{Index, Lifecycle}
  alias Aiur.Heroicons

  test "epic progress counts every matching label regardless of feature ownership" do
    ui = %Aiur.Config.Schema.GeneralEpic{key: "ui", label: "UI", labels: [" AREA:UI "], hue: 120, icon: "pen"}
    docs = %Aiur.Config.Schema.GeneralEpic{key: "docs", label: "Docs", labels: ["area:docs"], hue: 240, icon: "docs"}
    p = parts([row(1, %{labels: [" Area:Ui "], lifecycle: %Lifecycle{state: :open}}), row(2, %{labels: ["area:ui", "area:docs"]}), row(3)])
    feature = %{slug: "pag", label: "Pagination", hue: 175, epics: [%{key: "f-pag", label: "Page"}], from: now(), to: :none, baseline: :none}

    settings = p.settings |> elem(1) |> put_in([:build_order, :general_epics], [ui, docs])

    p =
      p
      |> Map.put(:settings, {:ok, settings})
      |> put_in([:now, :rows], %{"1" => now_row(1)})
      |> put_in(
        [:features],
        {:ok, %{features: %{"pag" => feature}, owners: %{1 => %{feature: "pag", epic: "f-pag", joined_at: DateTime.from_unix!(now(), :millisecond)}}, also: %{}, health: health()}}
      )

    older = now() - 3_600_000
    p = put_in(p, [:not_queued], %{rows: [], state: :ok, reasons: [], observed_at: DateTime.from_unix!(older, :millisecond), truncated?: false})

    assert {:ok, index} = assemble(p)
    observed_at = older
    assert index.epic_progress["ui"] == %{closed: 1, open: 1, total: 2, observed_at: observed_at, reason: nil}
    assert index.epic_progress["docs"] == %{closed: 1, open: 0, total: 1, observed_at: observed_at, reason: nil}
    assert index.epic_progress_meta == %{unmatched: 1, observed_at: observed_at, reason: nil}
  end

  test "legacy label snapshots preserve epic counts while explicitly incomplete labels stay unknown" do
    epic = %Aiur.Config.Schema.GeneralEpic{key: "ui", label: "UI", labels: ["area:ui"], hue: 120, icon: "pen"}
    p = parts([row(1, %{labels: ["area:ui"], labels_complete: :unknown})])
    settings = p.settings |> elem(1) |> put_in([:build_order, :general_epics], [epic])
    p = Map.put(p, :settings, {:ok, settings})

    assert {:ok, index} = assemble(p)
    assert index.epic_progress["ui"] == %{closed: 1, open: 0, total: 1, observed_at: now(), reason: nil}
    assert index.epic_progress_meta == %{unmatched: 0, observed_at: now(), reason: nil}

    {:ok, history} = p.history
    rows = Map.update!(history.rows, 1, &%{&1 | labels_complete: false})
    incomplete = put_in(p, [:history], {:ok, %{history | rows: rows}})
    assert {:ok, unknown} = assemble(incomplete)
    assert unknown.epic_progress["ui"].reason == "Some ticket labels are incomplete"
    assert unknown.epic_progress["ui"].total == nil
    assert unknown.epic_progress_meta.reason == "Some ticket labels are incomplete"
  end

  test "epic progress excludes unpublished planned rows without label records" do
    epic = %Aiur.Config.Schema.GeneralEpic{key: "ui", label: "UI", labels: ["area:ui"], hue: 120, icon: "pen"}
    p = parts([row(1, %{labels: ["area:ui"]})])
    settings = p.settings |> elem(1) |> put_in([:build_order, :general_epics], [epic])
    p = p |> Map.put(:settings, {:ok, settings}) |> put_in([:planned, :rows], [plan_row(99)])

    assert {:ok, index} = assemble(p)
    assert index.epic_progress["ui"] == %{closed: 1, open: 0, total: 1, observed_at: now(), reason: nil}
    assert index.epic_progress_meta == %{unmatched: 0, observed_at: now(), reason: nil}
  end

  test "epic progress changes are published in live index diffs" do
    old = %{all: %{}, sources: %{}, epic_progress: %{"ui" => %{closed: 1, open: 2, total: 3}}, epic_progress_meta: %{unmatched: 1}}
    new = %{old | epic_progress: %{"ui" => %{closed: 1, open: 1, total: 2}}}

    assert Index.diff(old, new).set == %{epic_progress: new.epic_progress}
  end

  test "feature without a pack icon uses the generic Heroicon" do
    p = parts([row(70)])
    feature = %{slug: "plain", label: "Plain", hue: 42, epics: [%{key: "f-plain", label: "Plain"}], from: now(), to: :none, baseline: :none}
    p = put_in(p, [:features], {:ok, %{features: %{"plain" => feature}, owners: %{}, also: %{}, health: health()}})

    assert {:ok, index} = assemble(p)
    assert index.features["plain"].icon == Heroicons.generic_name()
    assert index.features["plain"].svg == Heroicons.svg(Heroicons.generic_name())
    assert index.epics["f-plain"].icon == Heroicons.generic_name()
  end

  test "root-imported lane features receive default workstream metadata" do
    root_feature = %{
      slug: "bo-3042",
      label: "Platform program",
      hue: 42,
      epics: [%{key: "f-bo-3042-home", label: "Platform program · Home"}],
      from: now(),
      to: :none,
      baseline: :none
    }

    p =
      parts([row(3043)])
      |> put_in(
        [:features],
        {:ok,
         %{
           features: %{"bo-3042" => root_feature},
           owners: %{},
           also: %{},
           health: health()
         }}
      )
      |> Map.put(:pack_metadata, %{"workstreams" => [%{"id" => "home", "root_number" => 3042}]})

    assert {:ok, index} = assemble(p)
    assert index.features["bo-3042"].icon == "home"
    assert index.features["bo-3042"].summary == "Show the platform program and its Build Order work clearly."
    assert index.features["bo-3042"].wave == "0"
    assert index.epics["f-bo-3042-home"].icon == "home"
  end

  test "feature progress counts indexed rows and planned members by local epic" do
    feature = %{slug: "bo-99", label: "Pagination", hue: 175, epics: [%{key: "f-bo-99-core", label: "Core"}, %{key: "f-bo-99-ui", label: "UI"}], from: now(), to: :none, baseline: :none}
    registry = %{features: %{"bo-99" => feature}, owners: %{}, also: %{}, health: health()}

    p =
      parts([row(1)])
      |> put_in(
        [:features],
        {:ok,
         %{
           registry
           | owners: %{
               1 => %{feature: "bo-99", epic: "f-bo-99-core", joined_at: DateTime.from_unix!(now(), :millisecond)},
               2 => %{feature: "bo-99", epic: "f-bo-99-core", joined_at: DateTime.from_unix!(now(), :millisecond)},
               4 => %{feature: "bo-99", epic: "f-bo-99-core", joined_at: DateTime.from_unix!(now(), :millisecond)},
               5 => %{feature: "bo-99", epic: "f-bo-99-ui", joined_at: DateTime.from_unix!(now(), :millisecond)}
             },
             also: %{},
             health: health()
         }}
      )
      |> put_in([:now, :rows], %{"2" => %{id: "2", num: 2, sec: "now", status: "open", ord: 2, agent: %{state: "ci_wait"}}})
      |> put_in([:planned, :rows], [Map.put(plan_row(3), :epic, "f-bo-99-core")])
      |> put_in([:not_queued, :rows], [
        %{num: 4, sec: "nq", status: "open", ord: 4, epic: "f-bo-99-core"},
        %{num: 5, sec: "nq", status: "open", ord: 5, epic: "f-bo-99-ui"}
      ])

    packs = [
      %{
        root_number: 99,
        build_order_id: "program",
        title: "Program plan",
        content_hash: <<0::256>>,
        status: %{},
        metadata: %{
          "workstreams" => [
            %{"id" => "core", "lane" => "core", "wave" => 0, "summary" => "Core work"},
            %{"id" => "ui", "lane" => "ui", "wave" => "0b", "summary" => "UI work"}
          ]
        },
        tickets: [
          %{id: "MP-E8-C11-T01", lane: "core", number: 1},
          %{id: "MP-E8-C11-T02", lane: "core", number: 2},
          %{id: "MP-E8-C11-T03", lane: "core", number: 3},
          %{id: "MP-E8-C11-T04", lane: "core", number: nil},
          %{id: "MP-E8-C12-T01", lane: "ui", number: 5}
        ]
      }
    ]

    p = Map.put(p, :packs, packs)
    assert {:ok, index} = Index.assemble(p, now: now())
    assert Map.take(index.feature_progress.features["f-bo-99-core"], [:closed, :open, :ci_wait, :unpublished, :total]) == %{closed: 1, open: 2, ci_wait: 1, unpublished: 1, total: 5}
    assert index.feature_progress.features["f-bo-99-core"].extras == 1
    assert index.feature_progress.features["f-bo-99-core"].reason == nil
    assert index.feature_progress.features["f-bo-99-core"].wave == "0"
    assert index.feature_progress.features["f-bo-99-core"].summary == "Core work"
    assert Map.take(index.feature_progress.features["f-bo-99-ui"], [:closed, :open, :ci_wait, :unpublished, :total]) == %{closed: 0, open: 1, ci_wait: 0, unpublished: 0, total: 1}
    assert index.feature_progress.features["f-bo-99-ui"].wave == "0b"
    active = put_in(p, [:now, :rows, "2", :agent, :state], "active")
    assert {:ok, changed} = Index.assemble(Map.put(active, :packs, packs), now: now())
    assert Index.diff(index, changed).set.feature_progress.features["f-bo-99-core"].ci_wait == 0
  end

  test "incomplete history keeps feature state unknown" do
    feature = %{slug: "pag", label: "Pagination", hue: 175, epics: [%{key: "f-bo-99-core", label: "Core"}], from: now(), to: :none, baseline: :none}
    p = put_in(parts([row(1)]), [:features], {:ok, %{features: %{"pag" => feature}, owners: %{}, also: %{}, health: health()}})
    incomplete = %{health() | complete?: false, failure: :backfill_pending}
    p = %{p | health: incomplete, history: {:ok, %{rows: %{1 => row(1)}, health: incomplete}}}
    packs = [%{root: 99, feature: "pag", complete?: true, status: %{}, version: "v1", manifest: %{"tickets" => []}}]
    assert {:ok, index} = Index.assemble(Map.put(p, :packs, packs), now: now())
    assert index.feature_progress.features["f-bo-99-core"].closed == nil
    assert index.feature_progress.features["f-bo-99-core"].reason == "states unavailable · CI state unknown · planned count unavailable"
  end

  test "pack loader failure keeps planned count unavailable" do
    feature = %{slug: "pag", label: "Pagination", hue: 175, epics: [%{key: "f-bo-99-core", label: "Core"}], from: now(), to: :none, baseline: :none}
    p = put_in(parts([row(1)]), [:features], {:ok, %{features: %{"pag" => feature}, owners: %{}, also: %{}, health: health()}})
    assert {:ok, index} = Index.assemble(Map.put(p, :packs, {:error, :read_failed}), now: now())
    progress = index.feature_progress.features["f-bo-99-core"]
    assert progress.unpublished == nil
    assert progress.total == nil
    assert progress.reason == "planned count unavailable"
  end

  test "GitHub root progress counts its sub-issue membership across ticket states" do
    ref = fn n -> %{owner: "acme", repository: "widgets", number: n} end
    root = row(99, %{labels: ["build-order"], timeline_complete: true, sub_issues_added: Enum.map(100..104, &%{ref: ref.(&1), at: DateTime.from_unix!(now(), :millisecond)})})
    parent = %{owner: "acme", repository: "widgets", number: 99}
    closed = row(100, %{parent: parent, labels: ["build-lane:core", "phase:2"]})
    ci_wait = row(101, %{parent: parent, lifecycle: %Lifecycle{state: :open}, labels: ["build-lane:core", "phase:2", "agent:human-review"], agent_model: "codex"})
    rework = row(102, %{parent: parent, lifecycle: %Lifecycle{state: :open}, labels: ["build-lane:ui", "phase:3", "agent:rework"]})
    parked = row(103, %{parent: parent, lifecycle: %Lifecycle{state: :open}, labels: ["build-lane:ui", "phase:3", "nuc:parked"]})
    unowned = row(104, %{parent: parent, labels: ["build-lane:core", "phase:2"]})
    feature = %{slug: "bo-99", label: "Build order", hue: 175, epics: [%{key: "f-bo-99-core", label: "Core"}, %{key: "f-bo-99-ui", label: "UI"}], from: now(), to: :none, baseline: :none}
    registry = %{features: %{"bo-99" => feature}, owners: %{}, also: %{}, health: health()}
    p = parts([root, closed, ci_wait, rework, parked, unowned])
    owner = fn epic -> %{feature: "bo-99", epic: epic, source: "import:build-order", joined_at: DateTime.from_unix!(now(), :millisecond)} end
    registry = put_in(registry, [:owners], %{100 => owner.("f-bo-99-core"), 101 => owner.("f-bo-99-core"), 102 => owner.("f-bo-99-ui"), 103 => owner.("f-bo-99-ui")})

    p =
      put_in(p, [:features], {:ok, registry})
      |> put_in([:history, Access.elem(1), :repository], "acme/widgets")
      |> put_in([:now, :source], source())
      |> put_in([:now, :rows, "101"], %{id: "101", num: 101, sec: "now", status: "running", ord: 101, agent: %{state: "ci_wait"}})
      |> put_in([:not_queued, :rows], [%{num: 102, sec: "nq", status: "open", ord: 102}, %{num: 103, sec: "nq", status: "open", ord: 103}])

    assert {:ok, index} = assemble(p)
    assert Map.take(index.feature_progress.features["f-bo-99-core"], [:closed, :open, :ci_wait, :total]) == %{closed: 2, open: 0, ci_wait: 1, total: 3}
    assert index.feature_progress.features["f-bo-99-core"].wave == "2"
    assert Map.take(index.feature_progress.features["f-bo-99-ui"], [:closed, :open, :ci_wait, :total]) == %{closed: 0, open: 2, ci_wait: 0, total: 2}
    assert index.feature_progress.features["f-bo-99-ui"].wave == "3"
  end

  test "root progress counts history members missing from index rows" do
    ref = fn n -> %{owner: "acme", repository: "widgets", number: n} end
    root = row(99, %{labels: ["build-order"], timeline_complete: true, sub_issues_added: Enum.map(100..102, &%{ref: ref.(&1), at: DateTime.from_unix!(now(), :millisecond)})})
    parent = %{owner: "acme", repository: "widgets", number: 99}
    closed_member = row(100, %{parent: parent, labels: ["build-lane:core"]})
    missing_index_member = row(101, %{parent: parent, labels: ["build-lane:core"], end: :unknown})
    indexed_member = row(102, %{parent: parent, labels: ["build-lane:core"], lifecycle: %Lifecycle{state: :open}})
    feature = %{slug: "bo-99", label: "Build order", hue: 175, epics: [%{key: "f-bo-99-core", label: "Core"}], from: nil, to: :none, baseline: :none}
    registry = %{features: %{"bo-99" => feature}, owners: %{}, also: %{}, health: health()}

    p =
      put_in(parts([root, closed_member, missing_index_member, indexed_member]), [:features], {:ok, registry})
      |> put_in([:history, Access.elem(1), :repository], "acme/widgets")
      |> put_in([:now, :rows], %{"102" => now_row(102)})

    assert {:ok, index} = assemble(p)
    assert Map.has_key?(index.all, "101") == false
    assert Map.take(index.feature_progress.features["f-bo-99-core"], [:closed, :open, :ci_wait, :total]) == %{closed: 2, open: 1, ci_wait: 0, total: 3}
    refute index.feature_progress.features["f-bo-99-core"].reason =~ "CI state unknown"
    assert index.feature_progress.features["f-bo-99-core"].root_number == 99
    assert index.feature_progress.features["f-bo-99-core"].start_date == Date.to_iso8601(DateTime.to_date(root.created_at))
  end

  test "root progress stays unknown when a member lifecycle is unknown" do
    ref = fn n -> %{owner: "acme", repository: "widgets", number: n} end
    root = row(99, %{labels: ["build-order"], timeline_complete: true, sub_issues_added: Enum.map(100..102, &%{ref: ref.(&1), at: DateTime.from_unix!(now(), :millisecond)})})
    parent = %{owner: "acme", repository: "widgets", number: 99}
    closed_member = row(100, %{parent: parent, labels: ["build-lane:core"]})
    unknown_member = row(101, %{parent: parent, labels: ["build-lane:core"], lifecycle: %Lifecycle{state: :unknown}})
    open_member = row(102, %{parent: parent, labels: ["build-lane:core"], lifecycle: %Lifecycle{state: :open}})
    feature = %{slug: "bo-99", label: "Build order", hue: 175, epics: [%{key: "f-bo-99-core", label: "Core"}], from: now(), to: :none, baseline: :none}
    registry = %{features: %{"bo-99" => feature}, owners: %{}, also: %{}, health: health()}

    p =
      put_in(parts([root, closed_member, unknown_member, open_member]), [:features], {:ok, registry})
      |> put_in([:history, Access.elem(1), :repository], "acme/widgets")

    assert {:ok, index} = assemble(p)
    progress = index.feature_progress.features["f-bo-99-core"]
    assert progress.closed == nil
    assert progress.open == nil
    assert progress.total == 3
    assert progress.reason == "states unavailable · planned count unavailable"
  end

  test "root epic matches all local pack lanes when its epic key has no lane suffix" do
    ref = fn n -> %{owner: "acme", repository: "widgets", number: n} end
    members = Enum.map(100..134, &row(&1, %{parent: %{owner: "acme", repository: "widgets", number: 1363}, labels: ["build-lane:core"]}))
    root = row(1363, %{labels: ["build-order"], timeline_complete: true, sub_issues_added: Enum.map(100..134, &%{ref: ref.(&1), at: DateTime.from_unix!(now(), :millisecond)})})
    feature = %{slug: "bo-1363", label: "Feature 1363", hue: 175, epics: [%{key: "f-bo-1363", label: "Feature 1363"}], from: now(), to: :none, baseline: :none}
    registry = %{features: %{"bo-1363" => feature}, owners: %{}, also: %{}, health: health()}

    pack = %{
      root: 1363,
      feature: "bo-1363",
      complete?: true,
      status: %{},
      version: "v1",
      manifest: %{"workstreams" => [%{"id" => "core"}]},
      tickets: Enum.map(100..134, &%{id: "MP-E8-C1-T#{&1}", lane: "core", number: &1})
    }

    p =
      parts([root | members])
      |> put_in([:features], {:ok, registry})
      |> put_in([:history, Access.elem(1), :repository], "acme/widgets")
      |> Map.put(:packs, [pack])

    assert {:ok, index} = Index.assemble(p, now: now())
    assert Map.take(index.feature_progress.features["f-bo-1363"], [:closed, :total, :plan_version]) == %{closed: 35, total: 35, plan_version: "v1"}
  end

  test "platform program build-queue lane receives its default icon" do
    feature = %{
      slug: "bo-3042",
      label: "Platform program",
      hue: 42,
      epics: [%{key: "f-bo-3042-build-queue", label: "Platform program · Build queue"}],
      from: now(),
      to: :none,
      baseline: :none
    }

    parts =
      parts([row(3043)])
      |> put_in([:features], {:ok, %{features: %{"bo-3042" => feature}, owners: %{}, also: %{}, health: health()}})
      |> Map.put(:pack_metadata, %{"workstreams" => [%{"id" => "build-queue", "root_number" => 3042}]})

    assert {:ok, index} = assemble(parts)
    assert index.features["bo-3042"].icon == "queue-list"
    assert index.epics["f-bo-3042-build-queue"].icon == "queue-list"
  end

  test "platform program kernel lane receives its default icon" do
    feature = %{
      slug: "bo-3042",
      label: "Platform program",
      hue: 42,
      epics: [%{key: "f-bo-3042-kernel", label: "Platform program · Kernel"}],
      from: now(),
      to: :none,
      baseline: :none
    }

    parts =
      parts([row(3043)])
      |> put_in([:features], {:ok, %{features: %{"bo-3042" => feature}, owners: %{}, also: %{}, health: health()}})
      |> Map.put(:pack_metadata, %{"workstreams" => [%{"id" => "kernel", "root_number" => 3042}]})

    assert {:ok, index} = assemble(parts)
    assert index.features["bo-3042"].icon == "cpu-chip"
    assert index.epics["f-bo-3042-kernel"].icon == "cpu-chip"
  end
end
