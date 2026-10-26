defmodule Aiur.BuildOrder.IndexTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.{Epic, Index, Lifecycle, ProviderHealth}
  alias AiurWeb.Build.Payload

  test "joins history facts, resolved membership, timing, edges and merged PR" do
    r = row(7, %{labels: ["bug", "complexity:2"], merged_at: ~U[2026-10-07 14:20:00Z], pr_number: 233, agent_model: "codex", agent_effort: "high"})
    p = parts([r])
    feature = %{slug: "pag", label: "Pagination", hue: 175, epics: [%{key: "f-pag", label: "Page"}], from: r.created_at, to: :none, baseline: :none}
    p = put_in(p, [:features], {:ok, %{features: %{"pag" => feature}, owners: %{7 => %{feature: "pag", epic: "f-pag", joined_at: r.created_at}}, also: %{}, health: health()}})
    assert {:ok, index} = assemble(p)
    t = index.all["7"]

    assert Map.take(t, [:sec, :status, :pct, :type, :cx, :pts, :feature, :epic, :pr]) ==
             %{sec: "hist", status: "done", pct: 100, type: "bug", cx: 2, pts: 2, feature: "pag", epic: "f-pag", pr: %{num: 233, state: "merged"}}

    assert t.start == now() and t.end == now() and t.start_src == "label"
    assert t.agent == %{model: "codex", name: nil, effort: "high", state: nil}
    assert t.deps_missing == 0
    assert index.features["pag"].stats["done"] == 1
    assert index.features["pag"].stats["pct"] == 100
    assert {:ok, ^t} = Payload.row(t)
    p = put_in(p, [:history], {:ok, %{rows: %{7 => %{r | end: :unknown}}, health: health()}})
    assert {:ok, undated} = assemble(p)
    assert undated.hist == [] and undated.history_meta.undated == 1
    assert undated.features["pag"].stats["done"] == 1
    assert undated.features["pag"].stats["pct"] == 100
  end

  test "now wins over history and plan; every resolver result survives unknown inputs" do
    p = parts([row(12), row(13), row(14)]) |> Map.put(:features, {:error, :down}) |> Map.put(:overrides, {:error, :down})
    p = p |> put_in([:now, :rows], %{"12" => now_row(12)}) |> put_in([:planned, :rows], [plan_row(12)])
    assert {:ok, index} = assemble(p)
    assert map_size(index.all) == 3
    assert index.sources.features.state == "unavailable"
    assert index.feature_progress.reason == "states unavailable · planned count unavailable"
    assert index.all["12"].sec == "now"

    for {_id, row} <- index.all do
      assert row.epic == "unsorted"
      assert row.feature == nil and row.also == []
    end

    context = Index.resolver_context(p, 13)
    assert context.owning_feature == :unknown and context.override == :unknown
    assert Epic.resolve(context, %{general: general(), features: :unknown}).source == "unknown"
  end

  test "planning context keeps an open ticket read timeout unavailable without raising" do
    parts = parts() |> Map.put(:open, {:error, :timeout})

    context = Index.planning_context(parts, MapSet.new())

    assert context.not_queued == %{
             state: :unavailable,
             reasons: [:open_tickets_timeout],
             observed_at: nil,
             truncated?: false,
             skipped: 0,
             rows: []
           }
  end

  test "preserves closure causes and unknown title, model and complexity" do
    p =
      parts([
        row(1, %{lifecycle: %Lifecycle{state: :closed, state_reason: :not_planned}}),
        row(2, %{title: :unknown, lifecycle: %Lifecycle{state: :closed, state_reason: :duplicate}}),
        row(3, %{lifecycle: %Lifecycle{state: :closed, state_reason: :unknown}})
      ])

    assert {:ok, index} = assemble(p)
    assert index.all["1"].status == "not_planned"
    for id <- ~w(2 3), do: assert(index.all[id].status == "closed")
    for {_id, t} <- index.all, do: assert(t.pct == nil and t.agent == nil and t.cx == nil and t.pts == nil)
    assert index.all["2"].title == ""
  end

  test "catalogue follows general config then feature start date then unsorted; counts cover all rows" do
    p = parts([row(1)]) |> put_in([:now, :rows], %{"2" => now_row(2)}) |> put_in([:planned, :rows], [plan_row(3)])
    p = put_in(p, [:not_queued, :rows], [%{num: 4, sec: "nq", status: "open", ord: 4, cx: 3, pts: 3}])
    feature = fn slug, date -> %{slug: slug, label: slug, hue: 42, epics: [%{key: "f-#{slug}", label: slug}], from: date, to: :none, baseline: :none} end
    p = put_in(p, [:features], {:ok, %{features: %{"aaa" => feature.("aaa", ~U[2026-10-01 00:00:00Z]), "zzz" => feature.("zzz", ~U[2026-09-01 00:00:00Z])}, owners: %{}, also: %{}, health: health()}})
    assert {:ok, index} = assemble(p)
    assert index.order == ~w(bugs design infra docs f-zzz f-aaa unsorted)
    design = __DIR__ |> Path.join("../../fixtures/build_home/live.json") |> File.read!() |> Jason.decode!()
    # E1: actual schema defaults must retain the frozen design catalogue.
    for key <- ~w(bugs design infra docs), do: assert(Payload.scrub(index.epics[key]) == design["epics"][key])
    assert index.epics["f-aaa"] == %{key: "f-aaa", label: "aaa", hue: 42, icon: "layers", feature: "aaa", temp: true}
    assert index.counts == Map.new(index.order, &{&1, if(&1 == "unsorted", do: 4, else: 0)})
    assert index.all["4"].cx == 3 and index.all["4"].pts == 3
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
    feature = %{slug: "bo-99", label: "Build order", hue: 175, epics: [%{key: "f-bo-99-core", label: "Core"}], from: now(), to: :none, baseline: :none}
    registry = %{features: %{"bo-99" => feature}, owners: %{}, also: %{}, health: health()}

    p =
      put_in(parts([root, closed_member, missing_index_member, indexed_member]), [:features], {:ok, registry})
      |> put_in([:history, Access.elem(1), :repository], "acme/widgets")
      |> put_in([:now, :rows], %{"102" => now_row(102)})

    assert {:ok, index} = assemble(p)
    assert Map.has_key?(index.all, "101") == false
    assert Map.take(index.feature_progress.features["f-bo-99-core"], [:closed, :open, :ci_wait, :total]) == %{closed: 2, open: 1, ci_wait: nil, total: 3}
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

  test "producer fields win over older history fields" do
    p = parts([row(4, %{labels: ["complexity:2"], lifecycle: %Lifecycle{state: :open}})])
    p = put_in(p, [:not_queued, :rows], [%{num: 4, sec: "nq", status: "open", ord: 4, title: "Fresher", created: 123, cx: 3, pts: 3}])
    assert {:ok, %{all: %{"4" => t}}} = assemble(p)
    assert t.cx == 3 and t.pts == 3 and t.title == "Fresher" and t.created == 123
  end

  test "history failure keeps other sections and unknown totals; incomplete history has no exact counts" do
    p = parts([row(1)]) |> put_in([:now, :rows], %{"2" => now_row(2)})
    bad = %{p | history: {:error, %ProviderHealth{state: :unavailable, failure: :history_corrupt}}}
    assert {:ok, failed} = assemble(bad)
    assert failed.hist == [] and failed.history_meta == %{total: nil, undated: nil} and failed.counts == nil
    assert failed.sources.history.state == "unavailable" and failed.sources.history.reason == "history_corrupt"
    assert failed.all["2"].sec == "now"
    assert {:ok, page} = Index.earlier(failed, now(), "Etc/UTC", 1)
    assert page.history.from == nil and page.history.total == nil
    assert {:ok, stopped} = assemble(%{p | health: %ProviderHealth{failure: :history_not_running}})
    assert stopped.hist == [] and stopped.history_meta.total == nil and stopped.counts == nil
    assert stopped.sources.history.reason == "history_not_running"
    incomplete = %{health() | complete?: false, failure: :backfill_pending}
    assert {:ok, partial} = assemble(%{p | health: incomplete, history: {:ok, %{rows: %{1 => row(1)}, health: incomplete}}})
    assert length(partial.hist) == 1 and partial.counts == nil
    assert partial.sources.history == %{state: "incomplete", reason: "backfill_pending", observed_at: now()}
  end

  test "catch-up preserves the older observation and open-ticket failures preserve every cause" do
    p = %{parts([row(1)]) | catch_up: %{status: :held, at: ~U[2026-10-06 14:20:00Z]}}
    p = put_in(p, [:not_queued], %{rows: [], state: :stale, reasons: [:open_tickets_stale, :queue_stale], observed_at: ~U[2026-10-05 14:20:00Z], truncated?: true})
    assert {:ok, i} = assemble(p)
    assert i.sources.history == %{state: "stale", reason: "catch_up_held", observed_at: now() - 86_400_000}
    assert i.counts["unsorted"] == 1
    assert i.sources.open_tickets == %{state: "stale", reason: "open_tickets_stale,queue_stale", observed_at: now() - 2 * 86_400_000, truncated: true}
    assert {:ok, stopped} = assemble(%{p | catch_up: {:error, :not_running}})
    assert stopped.sources.history.reason == "catch_up_not_running"
    unsupported = put_in(p, [:not_queued], %{rows: [], state: :unsupported, reasons: [:tracker_unsupported], observed_at: nil, truncated?: false})
    assert {:ok, i} = assemble(unsupported)
    assert i.sources.open_tickets.state == "unsupported"
    assert i.sources.open_tickets.reason == "tracker_unsupported"
  end

  test "epic config failure never supplies defaults" do
    assert {:error, :epic_config_unavailable} = assemble(%{parts() | settings: {:error, :down}})
  end

  test "workflow settings still loading is distinct from an invalid or failed config" do
    assert {:error, :settings_loading} = assemble(%{parts() | settings: {:error, :workflow_not_loaded}})
    assert {:error, :epic_config_unavailable} = assemble(%{parts() | settings: {:error, :invalid_config}})
  end

  test "missing and timed out settings stay in the startup loading state" do
    assert {:error, :settings_loading} = assemble(%{read_stale: %{settings: :timeout}})
    assert {:error, :settings_loading} = assemble(%{})
  end

  test "all open tickets appear exactly once including active labels absent from history" do
    p = parts() |> put_in([:open, Access.key(:tickets)], [open(50, ["agent:todo"]), open(51, ["agent:human-review"]), open(52), open(53, ["bug"])])
    p = p |> put_in([:now, :rows], %{"51" => now_row(51)}) |> put_in([:planned, :rows], [plan_row(50), plan_row(52)])
    assert {:ok, index} = assemble(p)
    assert Enum.sort(Map.keys(index.all)) == ~w(50 51 52 53)
    assert Enum.map(~w(50 51 52 53), &index.all[&1].sec) == ~w(plan now plan nq)
    assert index.all["53"].title == "Open 53"
    assert index.all["53"].epic == "bugs"
  end

  test "moves upsert once, removal and arrival share one diff, no-op emits no blocks" do
    assert {:ok, old} = assemble(parts() |> put_in([:planned, :rows], [plan_row(12), plan_row(41)]))
    p = parts() |> put_in([:now, :rows], %{"12" => now_row(12)}) |> put_in([:planned, :rows], [plan_row(640)])
    assert {:ok, new} = assemble(p)
    diff = Index.diff(old, new)
    assert Enum.map(diff.upsert, & &1.id) == ~w(12 640)
    assert diff.remove == ["41"]
    assert diff.set == %{}
    assert Index.diff(new, new) == %{upsert: [], remove: [], set: %{}}
  end
end
