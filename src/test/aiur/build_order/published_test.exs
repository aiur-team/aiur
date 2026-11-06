defmodule Aiur.BuildOrder.PublishedTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.Published
  alias Aiur.BuildOrder.PublishedReference

  @edge_kinds ~w(depends_on serializes_with suggested_after contains gates)

  test "selected root publishes one epic, its workstreams, lanes and every typed edge" do
    document = Published.encode(PublishedReference.selected_snapshot(), PublishedReference.encode_opts())

    assert document["contract"] == "aiur.build_order"
    assert document["contract_version"] == 1
    assert document["build_order_id"] == PublishedReference.build_order_id()
    assert document["repository"] == "aiur-team/aiur"
    assert document["root"]["id"] == "7490"
    assert document["root"]["number"] == 7490
    assert document["root"]["epic"] == "build-order-package"
    assert document["root"]["plan_version"] == 1

    assert [epic] = document["epics"]
    assert epic["key"] == "build-order-package"
    assert Enum.sort(epic["features"]) == ["bo-adoption", "bo-contract", "bo-package", "bo-research"]

    features = Enum.map(document["features"], & &1["key"]) |> Enum.sort()
    assert features == ["bo-adoption", "bo-contract", "bo-package", "bo-research"]
    assert Enum.all?(document["features"], &(&1["epic"] == "build-order-package"))

    assert Enum.map(document["lanes"], & &1["key"]) == ["plan-graph", "dashboard-ui", "docs"]
    assert Enum.map(document["lanes"], & &1["order"]) == [0, 1, 2]

    assert Enum.map(document["tickets"], & &1["id"]) == ["BO-001", "BO-002", "BO-003", "BO-004", "BO-005", "BO-006"]
    draft = Enum.find(document["tickets"], &(&1["id"] == "BO-006"))
    assert draft["number"] == nil
    assert draft["status"] == "planned"
    assert draft["lane"] == "docs"
  end

  test "every typed edge kind appears with its source and a known endpoint" do
    document = Published.encode(PublishedReference.selected_snapshot(), PublishedReference.encode_opts())
    edges = document["edges"]

    kinds = edges |> Enum.map(& &1["kind"]) |> Enum.uniq() |> Enum.sort()
    assert kinds == Enum.sort(@edge_kinds)

    known = MapSet.new(Enum.map(document["tickets"], & &1["id"]) ++ Enum.map(document["gates"], & &1["key"]))

    for edge <- edges do
      assert MapSet.member?(known, edge["from"]), "unknown edge source #{edge["from"]}"
      assert MapSet.member?(known, edge["to"]), "unknown edge target #{edge["to"]}"
      assert edge["source"] in ["pack", "tracker"]

      if edge["kind"] == "depends_on" do
        assert edge["state"] in ["cleared", "blocking", "terminal_unsatisfied", "unknown"]
      else
        assert edge["state"] == nil
      end
    end

    assert Enum.any?(edges, &(&1["kind"] == "depends_on" and &1["source"] == "tracker"))
    assert Enum.any?(edges, &(&1["kind"] == "depends_on" and &1["source"] == "pack"))

    assert %{
             "from" => "BO-005",
             "to" => "BO-004",
             "kind" => "depends_on",
             "state" => "terminal_unsatisfied"
           } = Enum.find(edges, &(&1["from"] == "BO-005" and &1["kind"] == "depends_on"))

    assert [%{"key" => "GATE-001", "status" => "open", "owner" => "Product operator"}] = document["gates"]
    assert Enum.any?(edges, &(&1["kind"] == "gates" and &1["to"] == "GATE-001"))
  end

  test "waves cover every ticket once and the critical path follows dependency edges" do
    document = Published.encode(PublishedReference.selected_snapshot(), PublishedReference.encode_opts())

    waved = document["waves"] |> Enum.flat_map(& &1["tickets"]) |> Enum.sort()
    assert waved == document["tickets"] |> Enum.map(& &1["id"]) |> Enum.sort()

    wave_by_id = for wave <- document["waves"], id <- wave["tickets"], into: %{}, do: {id, wave["index"]}
    assert wave_by_id["BO-001"] == 1
    assert wave_by_id["BO-002"] == 2
    assert wave_by_id["BO-005"] == 4
    assert Enum.all?(document["tickets"], &(&1["wave"] == wave_by_id[&1["id"]]))

    critical = document["critical_path"]
    assert critical["status"] == "known"
    assert critical["tickets"] == ["BO-001", "BO-002", "BO-004", "BO-005"]
    assert critical["hours"] == 31
  end

  test "an unavailable tracker publishes unknown sources with the known tickets intact" do
    document = Published.encode(PublishedReference.unavailable_snapshot(), PublishedReference.encode_opts())

    for source <- ["tracker", "progress"] do
      assert document["sources"][source]["status"] == "unknown"
      assert document["sources"][source]["reason"] == "provider_unavailable"
    end

    assert document["sources"]["pack"]["status"] == "known"
    assert document["progress"]["status"] == "unknown"
    assert document["progress"]["reason"] == "provider_unavailable"
    assert document["progress"]["percent"] == nil
    assert document["critical_path"]["status"] == "unknown"
    assert document["critical_path"]["hours"] == nil
    assert document["critical_path"]["tickets"] == []
    assert document["critical_path"]["reason"] == "provider_unavailable"

    assert [epic] = document["epics"]
    assert epic["progress"]["status"] == "unknown"
    assert Enum.all?(document["features"], &(&1["progress"]["status"] == "unknown"))
    assert Enum.all?(document["lanes"], &(&1["progress"]["status"] == "unknown"))

    assert length(document["tickets"]) == 6

    for ticket <- document["tickets"], ticket["id"] != "BO-006" do
      assert ticket["status"] == "unknown"
      assert ticket["progress_percent"] == nil
    end

    assert Enum.find(document["tickets"], &(&1["id"] == "BO-006"))["status"] == "planned"
    assert Enum.all?(document["edges"], &(&1["kind"] != "depends_on" or &1["state"] == "unknown"))
  end

  test "catalog publishes one epic per imported root" do
    document = Published.encode(PublishedReference.catalog_snapshot(), PublishedReference.encode_opts())

    assert document["contract"] == "aiur.build_order"
    assert document["root"]["id"] == "catalog"
    assert document["build_order_id"] == "aiur-team/aiur:catalog"
    assert Enum.map(document["epics"], & &1["key"]) == ["aiur-team/aiur#7490", "aiur-team/aiur#7510"]
    assert Enum.map(document["tickets"], & &1["number"]) == [7490, 7510]
    assert Enum.all?(document["tickets"], &(&1["kind"] == "umbrella"))
    assert document["sources"]["tracker"]["status"] == "known"
    assert document["sources"]["pack"]["status"] == "unknown"
    assert document["progress"]["total"] == 2
    assert document["progress"]["done"] == 1
  end

  test "a projection with no data publishes an explicit unknown document" do
    snapshot = %{PublishedReference.selected_snapshot() | data: nil, health: PublishedReference.unavailable_health()}
    document = Published.encode(snapshot, PublishedReference.encode_opts())

    assert document["root"]["id"] == "7490"
    assert document["tickets"] == []
    assert document["sources"]["tracker"]["status"] == "unknown"
    assert document["progress"]["status"] == "unknown"
    assert document["critical_path"]["status"] == "unknown"
  end
end
