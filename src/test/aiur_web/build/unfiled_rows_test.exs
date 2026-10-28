defmodule AiurWeb.Build.UnfiledRowsTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Build.UnfiledRows

  defp context, do: %{filed_numbers: MapSet.new([9, 10]), done_numbers: MapSet.new([9]), max_wave: 4, max_ord: 3, epics: MapSet.new(["bugs"]), now: 123}
  defp item(id, overrides \\ %{}), do: Map.merge(%{id: id, number: nil, phase: 0, complexity: 3, title: id, lane: "bugs", depends_on: []}, overrides)

  defp pack(items, overrides \\ %{}),
    do: Map.merge(%{tickets: items, completed: false, path: "/private/demo.json", source: :configured, build_order_id: "repo:demo", build_order_id_explicit?: true}, overrides)

  defp build(packs, overrides \\ %{}, failed \\ []),
    do: UnfiledRows.build(Map.merge(context(), overrides), loader: fn -> %{configured: length(packs) + length(failed), packs: packs, failed: failed} end)

  test "disabled, unreadable and partial sources retain observation and safe paths" do
    assert %{rows: [], source: %{state: "disabled", reason: "no_pack_configured", observed_at: 123}} = build([])
    assert %{rows: [row], source: %{state: "unavailable", reason: reason}} = build([pack([item("A")])], %{}, [%{source: :configured, path: "/private/bad.json"}])
    assert row.id == "pack:demo/A"
    assert reason == "1 of 2 planning packs could not be read: bad.json"
    assert %{source: %{reason: "planning packs could not be read", state: "unavailable"}} = UnfiledRows.build(context(), loader: fn -> raise "secret path" end)
  end

  test "all filed and completed packs produce no rows and completed packs produce no aliases" do
    assert %{rows: [], aliases: %{77 => "pack:demo/A"}, source: %{state: "ok"}} = build([pack([item("A", %{number: 77})])])
    assert %{rows: [], aliases: aliases} = build([pack([item("A"), item("B", %{number: 77})], %{completed: true})])
    assert aliases == %{}
  end

  test "dense phases preserve zero and unknowns, and offset filed waves and ordinals" do
    %{rows: rows} = build([pack(Enum.map([5, "x", 0, 2], &item(to_string(&1), %{phase: &1})))])
    assert Enum.map(rows, &{&1.src.wave, &1.wave, &1.ord}) == [{0, 5, 4}, {2, 6, 5}, {5, 7, 6}, {nil, 8, 7}]
    %{rows: [row]} = build([pack([item("A")])], %{max_wave: 0, max_ord: -1})
    assert {row.wave, row.ord, row.num, row.qpos, row.est} == {1, 0, nil, nil, nil}
    assert {row.epic, row.cx, row.pts, row.src, row.pct, row.status} == {"bugs", 3, 3, %{kind: "pack", path: "demo.json", wave: 0}, 0, "queued"}
  end

  test "cycles, missing dependencies and filed dependency health preserve exact causes" do
    tickets = [
      item("A", %{depends_on: ["B", "done", "open", "absent", "nope"]}),
      item("B", %{depends_on: ["A"]}),
      item("done", %{number: 9}),
      item("open", %{number: 10}),
      item("absent", %{number: 11}),
      item("C", %{depends_on: ["done"]})
    ]

    %{rows: [a, b, c]} = build([pack(tickets)])
    assert a.deps == ["pack:demo/B", "9", "10"]
    assert a.dep_states == %{"pack:demo/B" => "blocking", "9" => "cleared", "10" => "blocking"}
    assert a.deps_missing == 2
    assert a.children == [b.id]
    assert b.children == [a.id]
    assert a.cue.waitAny
    refute c.cue.waitAny
  end

  test "invalid ids and colliding suffixes are counted instead of overwritten" do
    %{rows: [row], source: %{state: "unavailable", reason: reason}} =
      build([pack([item("A"), item("../x"), item(".."), item("."), item("B\n")]), pack([item("A")], %{build_order_id: "repo:x:demo", path: "/private/second.json"})])

    assert row.id == "pack:demo/A"
    assert reason == "5 planning-pack items could not be read: demo.json, second.json"
  end

  test "idless packs remain distinct and source paths reveal no host paths" do
    %{rows: [a, b]} =
      build([
        pack([item("A")], %{build_order_id_explicit?: false, source: :workspace}),
        pack([item("A", %{lane: "unknown", complexity: 8})], %{build_order_id_explicit?: false, source: :state, path: "/private/builds/x/build-order.json"})
      ])

    refute a.id == b.id
    assert a.src.path == ".aiur/build_orders/demo.json"
    assert b.src.path == "builds/x/build-order.json"
    assert {b.epic, b.cx, b.pts} == {nil, nil, nil}
    refute Jason.encode!([a, b]) =~ "/private"
  end

  test "future regression guard: census-sized packs are never capped" do
    %{rows: rows} = build([pack(Enum.map(1..650, &item("T-#{&1}")))])
    assert length(rows) == 650
  end
end
