defmodule AiurWeb.Build.PackFeatureProgressTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.IndexReader

  test "raw feature manifests and deferred pack rows retain aliases without counting unpublished work twice" do
    epic = "f-bo-99-core"
    feature = %{slug: "bo-99", label: "Program", hue: 40, epics: [%{key: epic, label: "Core"}], from: now(), to: :none, baseline: :none}
    registry = %{features: %{"bo-99" => feature}, owners: %{1 => %{feature: "bo-99", epic: epic, joined_at: DateTime.from_unix!(now(), :millisecond)}}, also: %{}, health: health()}
    input = parts([row(1)]) |> Map.put(:features, {:ok, registry})
    raw = pack("core")
    # The two public read seams may provide different lane catalogues. The
    # unfiled producer must also be safe when its lane resolves to this epic.
    unfiled = %{configured: 1, failed: [], packs: [pack(epic)]}

    read = IndexReader.read(MapSet.new([:packs]), input, pack_loader: fn -> [raw] end, packs_opts: [loader: fn -> unfiled end], clock: &now/0)
    assert read.feature_packs == [raw]
    assert {:ok, index} = assemble(read)
    assert index.all["1"].was == "pack:program/FILED"
    assert index.all["pack:program/UNFILED"].epic == epic
    assert index.all["pack:program/UNFILED"].num == nil
    assert index.sources.packs == %{state: "ok", observed_at: now(), reason: nil}
    assert Map.take(index.feature_progress.features[epic], [:closed, :open, :ci_wait, :unpublished, :total]) == %{closed: 1, open: 0, ci_wait: 0, unpublished: 1, total: 2}

    cached = IndexReader.read(MapSet.new(), read, pack_loader: fn -> flunk("unchanged feature manifests must stay cached") end, packs_opts: [loader: fn -> unfiled end], clock: &now/0)
    assert {:ok, repeated} = assemble(cached)
    assert repeated.feature_progress.features[epic].total == 2
    assert repeated.all["1"].was == "pack:program/FILED"
  end

  defp pack(lane) do
    %{
      completed: false,
      root_number: 99,
      build_order_id: "acme/widgets:program",
      build_order_id_explicit?: true,
      path: "/fixture/program.json",
      source: :configured,
      metadata: %{},
      content_hash: <<0::256>>,
      title: "Program",
      tickets: [ticket("FILED", 1, lane), ticket("UNFILED", nil, lane)]
    }
  end

  defp ticket(id, number, lane), do: %{id: id, number: number, title: id, phase: 0, lane: lane, complexity: 1, depends_on: []}
end
