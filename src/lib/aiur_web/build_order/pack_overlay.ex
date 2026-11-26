defmodule AiurWeb.BuildOrder.PackOverlay do
  @moduledoc "Read-only union of local planning structure and supervised GitHub snapshots."

  alias Aiur.BuildOrder.{Catalog, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.PlanningSource

  @spec catalog(term()) :: term()
  def catalog(%Snapshot{} = live) do
    merge_catalog(live, PlanningSource.catalog())
  end

  def catalog(live), do: live

  @spec selected(term(), term()) :: term()
  def selected(%TrackerIdentity{} = identity, live) do
    {:ok, planning} = PlanningSource.selected(identity)
    merge_selected(live, planning)
  end

  def selected(_identity, live), do: live

  @spec snapshot(Snapshot.t()) :: Snapshot.t()
  def snapshot(%Snapshot{scope: :catalog} = live), do: catalog(live)
  def snapshot(%Snapshot{scope: {:selected, identity}} = live), do: selected(identity, {:ok, live}) |> elem(1)

  defp merge_catalog(%Snapshot{} = live, %Snapshot{data: %Catalog{entries: []}} = planning),
    do: %{live | generation: generation(live) + generation(planning), pack_overlay?: true}

  defp merge_catalog(%Snapshot{data: %Catalog{} = catalog} = live, %Snapshot{data: %Catalog{entries: roots}} = planning) do
    packs = Enum.group_by(roots, &locator(&1.identity))
    merged = Enum.flat_map(catalog.entries, fn root -> Enum.map(Map.get(packs, locator(root.identity), [root]), &merge_root(&1, root)) end)
    known = MapSet.new(catalog.entries, &locator(&1.identity))
    merged = merged ++ Enum.reject(roots, &MapSet.member?(known, locator(&1.identity)))
    %{live | data: %{catalog | entries: merged, diagnostics: Enum.uniq(catalog.diagnostics ++ planning.data.diagnostics)}, pack_overlay?: true, generation: generation(live) + generation(planning)}
  end

  defp merge_catalog(%Snapshot{} = live, planning),
    do: %{planning | pack_overlay?: true, authority_epoch: live.authority_epoch, generation: generation(live) + generation(planning)}

  defp merge_selected({:ok, %Snapshot{} = live}, %Snapshot{data: nil} = planning),
    do: {:ok, %{live | generation: generation(live) + generation(planning), pack_overlay?: true}}

  defp merge_selected(live, %Snapshot{data: nil}), do: live

  defp merge_selected({:ok, %Snapshot{} = live}, %Snapshot{data: %SelectedRoot{} = pack} = planning) do
    data = merge_members(pack, live.data, live.health)
    {:ok, %{planning | data: data, pack_overlay?: true, github_health: live.health, authority_epoch: live.authority_epoch, generation: generation(live) + generation(planning)}}
  end

  defp merge_selected(_live, planning), do: {:ok, planning}

  defp merge_members(pack, %SelectedRoot{} = live, health) do
    by_locator = Map.new(live.members, &{locator(&1.identity), &1})

    identities =
      Map.new(pack.members, fn member ->
        current = Map.get(by_locator, locator(member.identity), member)
        {locator(member.identity), current.identity}
      end)

    members = Enum.map(pack.members, &merge_member(&1, by_locator, identities, health))
    known = MapSet.new(pack.members, &locator(&1.identity))
    extras = if health.state == :healthy and health.complete?, do: Enum.reject(live.members, &MapSet.member?(known, locator(&1.identity))), else: []
    members = members ++ extras
    %{pack | root: merge_root(pack.root, live.root), members: members}
  end

  defp merge_members(pack, _missing, _health), do: pack

  defp merge_root(pack, live),
    do: %{pack | identity: live.identity, member_read_count: live.member_read_count, github_member_count: live.github_member_count}

  defp merge_member(planned, live, identities, health) do
    current = Map.get(live, locator(planned.identity), planned)
    current = if health.state == :healthy and health.complete?, do: current, else: %{planned | identity: current.identity}
    dependencies = Enum.map(planned.dependencies ++ current.dependencies, &remap_dependency(&1, identities)) |> Enum.uniq()
    %{current | metadata: planned.metadata, dependencies: dependencies, document_url: planned.document_url, document_path: planned.document_path, draft_body: planned.draft_body}
  end

  defp remap_dependency(dependency, identities) do
    %{dependency | identity: remap(dependency.identity, identities), blocker_identity: remap(dependency.blocker_identity, identities), blocked_identity: remap(dependency.blocked_identity, identities)}
  end

  defp remap(identity, identities), do: Map.get(identities, locator(identity), identity)
  defp generation(%{generation: generation}) when is_integer(generation) and generation > 0, do: generation
  defp generation(_snapshot), do: 0
  defp locator(%TrackerIdentity{owner: owner, repository: repository, identifier: number}), do: {String.downcase(owner), String.downcase(repository), number}
  defp locator(_identity), do: nil
end
