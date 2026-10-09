defmodule Aiur.BuildOrder.Features.RootImportTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.{Features, History, Metadata}
  alias Aiur.BuildOrder.Features.{RootImport, RootImportWrites}
  alias AiurWeb.OperatorControlCenter.BuildOrderEpicIcon
  @at ~U[2026-09-01 10:00:00Z]
  @later ~U[2026-09-03 10:00:00Z]
  @empty %{features: %{}, owners: %{}, also: %{}}

  test "roots map to stable features, ordered namespaced epics and latest repository join times" do
    plan = RootImport.plan(history(), @empty, %{})
    assert RootImport.slug(2573) == "bo-2573"
    root = Enum.find(plan.creates, &(&1.slug == "bo-2573"))
    assert root.label == "Paseo pack"
    assert root.from == @at
    assert root.to == :none
    assert root.hue == nil
    assert root.epics == [%{key: "f-bo-2573-runtime", label: "Paseo pack · Runtime"}, %{key: "f-bo-2573-dashboard-ui", label: "Paseo pack · Dashboard UI"}, %{key: "f-bo-2573", label: "Paseo pack"}]
    closed = Enum.find(plan.creates, &(&1.slug == "bo-2000"))
    assert closed.to == @later
    assert closed.epics == [%{key: "f-bo-2000-runtime", label: "Closed · Runtime"}]
    assert {"bo-2573", [10], "f-bo-2573-runtime", @at} in plan.adds
    assert {"bo-2573", [11], "f-bo-2573-dashboard-ui", @later} in plan.adds
    assert {"bo-2573", [12], "f-bo-2573", :unknown} in plan.adds
    assert plan.skipped_cross_repo == 1
  end

  test "unknown dates stay unknown and blank titles state only the root number" do
    for title <- [:unknown, " \n "] do
      h = put_in(history(), [:rows, 2573], %{root(2573) | title: title, created_at: :unknown, closed_at: :unknown, sub_issues_added: :unknown})
      p = RootImport.plan(h, @empty, %{})
      r = Enum.find(p.creates, &(&1.slug == "bo-2573"))
      assert r.label == "Build Order #2573"
      assert r.from == :unknown
      assert r.to == :unknown
      assert Enum.filter(p.adds, &(elem(&1, 0) == "bo-2573")) |> Enum.all?(&(elem(&1, 3) == :unknown))
    end
  end

  test "unassigned, ambiguous and oversized lanes use the catch-all; titles fit registry bounds" do
    long = String.duplicate("x", 200) <> "\t title"

    h =
      history()
      |> put_in([:rows, 2573, :title], long)
      |> put_in([:rows, 11, :labels], ["build-lane:" <> String.duplicate("a", 60)])
      |> put_in([:rows, 12, :labels], ["build-lane:runtime", "build-lane:platform"])

    p = RootImport.plan(h, @empty, %{})
    r = Enum.find(p.creates, &(&1.slug == "bo-2573"))
    assert String.length(r.label) == 80
    assert String.ends_with?(r.label, "…")
    refute r.label =~ "\t"
    assert Enum.all?(r.epics, &(String.length(&1.label) <= 80))
    assert hd(r.epics).label |> String.ends_with?(" · Runtime")
    assert {"bo-2573", [11], "f-bo-2573", @later} in p.adds
    assert p.skipped_lanes == 1
    assert RootImport.clean("<script>") == "<script>"
    assert RootImport.clean("a\t\n b") == "a b"
    {_, writer} = store()
    assert :ok = RootImportWrites.apply(p, writer)
  end

  test "complete history removes departures and moves imported owners once between roots" do
    f = imported()
    h = put_in(history(), [:rows, 12, :parent], :none)
    assert RootImport.plan(h, f, journals()).removes == [{"bo-2573", [12]}]
    h = put_in(h, [:rows, 12, :parent], ref(2000))
    p = RootImport.plan(h, f, journals())
    assert p.moves == [{"bo-2000", [12], "f-bo-2000", :unknown}]
    assert p.removes == []
    p = RootImport.plan(put_in(h, [:health, :complete?], false), f, journals())
    assert p.moves == []
    assert p.removes == []
    assert p.deferred == [12]
    p = RootImport.plan(put_in(h, [:rows, 12, :parent], :unknown), f, journals())
    assert p.removes == []
    p = RootImport.plan(put_in(history(), [:health, :complete?], false), @empty, %{})
    assert length(p.adds) == 4
  end

  test "explicit ownership is linked and reported, never moved or removed" do
    f = %{imported() | owners: %{10 => %{feature: "auth", epic: "f-auth", source: "label:kev"}}, also: %{12 => ["bo-2573"]}}
    p = RootImport.plan(history(), f, journals())
    assert p.also == [{"bo-2573", [10]}]
    assert p.conflicts == [%{number: 10, owner: "auth", feature: "bo-2573"}]
    refute Enum.any?(p.adds ++ p.moves, &(10 in elem(&1, 1)))
    f = put_in(f, [:also, 10], ["bo-2573"])
    assert RootImport.plan(history(), f, journals()).also == []
    h = put_in(history(), [:rows, 12, :parent], :none)
    assert RootImport.plan(h, f, journals()).also_removes == [{"bo-2573", [12]}]
    f = put_in(imported(), [:owners, 12, :source], "cli:kev")
    assert RootImport.plan(h, f, journals()).removes == []
  end

  test "operator member and also removals win; a subsequent re-add clears the skip" do
    for type <- ["member.removed", "also.removed"] do
      j = %{"bo-2573" => [%{type: type, number: 11, source: "cli:kev"}]}
      p = RootImport.plan(history(), @empty, j)
      refute Enum.any?(p.adds, &(11 in elem(&1, 1)))
      assert p.also == []
      f = put_in(@empty, [:owners, 11], %{feature: "auth", epic: "auth", source: "cli:kev"})
      assert RootImport.plan(history(), f, j).also == []
      j = Map.update!(j, "bo-2573", &(&1 ++ [%{type: "member.added", number: 11, source: "cli:kev"}]))
      assert Enum.any?(RootImport.plan(history(), @empty, j).adds, &(11 in elem(&1, 1)))
    end
  end

  test "slug collisions and removed root labels leave the feature untouched" do
    f = imported()
    p = RootImport.plan(history(), f, %{"bo-2573" => [%{type: "feature.created", source: "cli:kev"}]})
    assert %{slug: "bo-2573", reason: :slug_taken} in p.conflicts
    refute Enum.any?(p.updates, &(&1.slug == "bo-2573"))
    refute Enum.any?(p.adds, &(elem(&1, 0) == "bo-2573"))
    p = RootImport.plan(put_in(history(), [:rows, 2573, :labels], []), f, journals())
    assert p.removes == []
    refute Enum.any?(p.updates, &(&1.slug == "bo-2573"))
  end

  test "real journal re-runs are idempotent; rename and lane updates keep original join times" do
    {pid, writer} = store()
    assert :ok = RootImportWrites.apply(RootImport.plan(history(), @empty, %{}), writer)
    assert {:ok, _} = Features.add_epic("bo-2573", %{key: "custom", label: "Operator epic"}, server: pid, source: "cli:kev", actor: "kev")
    assert {:ok, snapshot} = Features.snapshot(server: pid)
    assert snapshot.features["bo-2573"].baseline == :none
    assert snapshot.owners[11].source == "import:build-order"
    assert snapshot.owners[11].actor == "import"
    j = read_journals(pid, snapshot)
    p = RootImport.plan(history(), snapshot, j)
    for k <- [:creates, :updates, :new_epics, :adds, :moves, :removes, :also, :also_removes], do: assert(p[k] == [])
    assert :ok = RootImportWrites.apply(p, writer)
    assert read_journals(pid, snapshot) == j
    h = history() |> put_in([:rows, 2573, :title], "Renamed") |> put_in([:rows, 10, :labels], ["build-lane:platform"])
    p = RootImport.plan(h, snapshot, j)
    update = Enum.find(p.updates, &(&1.slug == "bo-2573"))
    assert update.label == "Renamed"
    assert %{key: "f-bo-2573-runtime", label: "Renamed · Runtime"} in update.epics
    assert %{key: "custom", label: "Operator epic"} in update.epics
    assert {"bo-2573", %{key: "f-bo-2573-platform", label: "Renamed · Platform"}} in p.new_epics
    assert :ok = RootImportWrites.apply(p, writer)
    assert {:ok, owner} = Features.owner(10, server: pid)
    assert owner.epic == "f-bo-2573-platform"
    assert owner.joined_at == @at
    assert {:ok, s} = Features.snapshot(server: pid)
    assert RootImport.plan(h, s, read_journals(pid, s)).updates == []
  end

  test "lane display delegation preserves existing labels (future regression guard)" do
    for {lane, label} <- [{"dashboard-ui", "Dashboard UI"}, {"my-lane", "My Lane"}, {:unassigned, "Unassigned"}] do
      assert Metadata.lane_label(lane) == label
      assert BuildOrderEpicIcon.label(lane) == label
    end
  end

  test "history snapshot carries the repository used to reject foreign parents" do
    dir = Aiur.TestSupport.tmp_root!("root-import-history")
    on_exit(fn -> File.rm_rf!(dir) end)
    pid = start_supervised!({History, name: :root_import_history_repository, repository: "aiur-team/aiur", state_dir: dir})
    assert {:ok, snapshot} = History.snapshot(server: pid)
    assert snapshot.repository == "aiur-team/aiur"
    h = put_in(history(), [:rows, 10, :parent], %{ref(2573) | repository: "other"})
    refute Enum.any?(RootImport.plan(h, @empty, %{}).adds, &(10 in elem(&1, 1)))
  end

  defp store do
    dir = Aiur.TestSupport.tmp_root!("root-import-features")
    on_exit(fn -> File.rm_rf!(dir) end)
    pid = start_supervised!({Features, name: nil, state_dir: dir, general_epics: [], filesystem_sync_fun: fn -> :ok end, alert_fun: fn _, _, _ -> :ok end})
    {pid, fn op, args -> apply(Features, op, List.update_at(args, -1, &Keyword.put(&1, :server, pid))) end}
  end

  defp read_journals(pid, s),
    do:
      Map.new(s.features, fn {slug, _} ->
        {:ok, events} = Features.journal(slug, server: pid)
        {slug, events}
      end)

  defp ref(n), do: %{owner: "aiur-team", repository: "aiur", number: n}
  defp root(n), do: %{number: n, labels: ["build-order"], title: "Paseo pack", created_at: @at, closed_at: :none, parent: :none, sub_issues_added: [], timeline_complete: true}
  defp member(n, root, labels), do: %{number: n, labels: labels, parent: ref(root)}

  defp history do
    r = %{root(2573) | sub_issues_added: [%{ref: ref(10), at: @at}, %{ref: ref(11), at: @at}, %{ref: ref(11), at: @later}, %{ref: %{ref(13) | repository: "other"}, at: @at}]}

    %{
      repository: "aiur-team/aiur",
      health: %{complete?: true, failure: nil},
      rows: %{
        2573 => r,
        2000 => %{root(2000) | title: "Closed", closed_at: @later},
        10 => member(10, 2573, ["build-lane:runtime"]),
        11 => member(11, 2573, ["build-lane:dashboard-ui"]),
        12 => member(12, 2573, []),
        20 => member(20, 2000, ["build-lane:runtime"])
      }
    }
  end

  defp imported do
    features = Map.new(RootImport.plan(history(), @empty, %{}).creates, &{&1.slug, &1})
    %{features: features, owners: %{12 => %{feature: "bo-2573", epic: "f-bo-2573", source: "import:build-order"}}, also: %{}}
  end

  defp journals, do: Map.new(["bo-2573", "bo-2000"], &{&1, [%{type: "feature.created", source: "import:build-order"}]})
end
