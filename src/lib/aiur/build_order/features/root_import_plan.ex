defmodule Aiur.BuildOrder.Features.RootImportPlan do
  @moduledoc false
  alias Aiur.BuildOrder.CatalogStore
  alias Aiur.BuildOrder.Features.RootImportMapping, as: Mapping
  @source "import:build-order"
  @lists ~w(creates updates new_epics moves removes adds also also_removes conflicts deferred)a

  @spec plan(map(), map(), map()) :: map()
  def plan(history, features, journals) do
    roots = history.rows |> Map.values() |> Enum.filter(&root?/1) |> Enum.sort_by(& &1.number)
    initial = Map.merge(Map.new(@lists, &{&1, []}), %{skipped_cross_repo: 0, skipped_lanes: 0})
    context = %{history: history, features: features, journals: journals}
    plan = Enum.reduce(roots, initial, &root(&1, &2, context))
    moved = for {_, numbers, _, _} <- plan.moves, number <- numbers, do: number
    plan |> Map.update!(:removes, &Enum.reject(&1, fn {_, [n]} -> n in moved end)) |> group()
  end

  defp root?(%{labels: labels}) when is_list(labels), do: CatalogStore.root_label() in labels
  defp root?(_), do: false

  defp root(root, plan, context) do
    slug = Mapping.slug(root.number)
    events = Map.get(context.journals, slug, [])
    existing = context.features.features[slug]

    if existing && not imported?(events) do
      push(plan, :conflicts, %{slug: slug, reason: :slug_taken})
    else
      import(root, plan, context, events, existing)
    end
  end

  defp import(root, plan, context, events, existing) do
    members = context.history.rows |> Map.values() |> Enum.filter(&member?(&1, root.number, context.history.repository)) |> Enum.sort_by(& &1.number)
    feature = Mapping.feature(root, members)
    plan = feature(plan, feature, existing)
    plan = Enum.reduce(members, plan, &join(&1, &2, root, context, events))
    plan = leaves(plan, feature.slug, members, context)
    cross = Enum.count(Mapping.entries(root), &(not Mapping.same_repository?(&1.ref, context.history.repository)))
    skipped = Enum.count(members, &Mapping.skipped_lane?(root.number, &1))
    %{plan | skipped_cross_repo: plan.skipped_cross_repo + cross, skipped_lanes: plan.skipped_lanes + skipped}
  end

  defp feature(plan, desired, nil), do: push(plan, :creates, desired)

  defp feature(plan, desired, existing) do
    epics = Enum.map(existing.epics, &Mapping.relabel(&1, desired.label))
    changes = Map.take(desired, [:label, :from, :to]) |> Map.put(:epics, epics) |> Map.reject(fn {k, v} -> existing[k] == v end)
    plan = if changes == %{}, do: plan, else: push(plan, :updates, Map.put(changes, :slug, desired.slug))
    keys = Enum.map(existing.epics, & &1.key)
    Enum.reduce(Enum.reject(desired.epics, &(&1.key in keys)), plan, &push(&2, :new_epics, {desired.slug, &1}))
  end

  defp join(row, plan, root, context, events) do
    if operator_removed?(events, row.number) do
      plan
    else
      slug = Mapping.slug(root.number)
      epic = Mapping.key(root.number, Mapping.lane(root.number, row))
      at = Mapping.joined_at(root, row.number, context.history.repository)
      join_owner(context.features.owners[row.number], {slug, [row.number], epic, at}, plan, context)
    end
  end

  defp join_owner(nil, operation, plan, _), do: push(plan, :adds, operation)
  defp join_owner(%{feature: slug, epic: epic}, {slug, _, epic, _}, plan, _), do: plan
  defp join_owner(%{feature: slug}, {slug, _, _, _} = operation, plan, _), do: push(plan, :adds, operation)

  defp join_owner(%{feature: "bo-" <> _, source: @source}, {_, [n], _, _} = operation, plan, context) do
    if context.history.health.complete?, do: push(plan, :moves, operation), else: push(plan, :deferred, n)
  end

  defp join_owner(owner, {slug, [n], _, _}, plan, context) do
    plan = push(plan, :conflicts, %{number: n, owner: owner.feature, feature: slug})
    if slug in Map.get(context.features.also, n, []), do: plan, else: push(plan, :also, {slug, [n]})
  end

  defp leaves(plan, slug, members, context) do
    if context.history.health.complete? do
      numbers = Enum.map(members, & &1.number)
      owners = for {n, %{feature: ^slug, source: @source}} <- context.features.owners, left?(n, numbers, context), do: {slug, [n]}
      links = for {n, slugs} <- context.features.also, slug in slugs, left?(n, numbers, context), do: {slug, [n]}
      %{plan | removes: plan.removes ++ owners, also_removes: plan.also_removes ++ links}
    else
      plan
    end
  end

  defp left?(n, members, context), do: n not in members and known_parent?(context.history.rows[n])
  defp known_parent?(nil), do: false
  defp known_parent?(%{parent: :unknown}), do: false
  defp known_parent?(_), do: true
  defp member?(%{parent: %{number: root} = ref}, root, repository), do: Mapping.same_repository?(ref, repository)
  defp member?(_, _, _), do: false
  defp imported?(events), do: match?(%{source: @source}, Enum.find(events, &(&1.type == "feature.created")))

  defp operator_removed?(events, n) do
    last = events |> Enum.filter(&(&1[:number] == n and &1.type in ~w(member.added member.removed also.added also.removed))) |> List.last()
    match?(%{type: type, source: source} when type in ["member.removed", "also.removed"] and source != @source, last)
  end

  defp push(plan, field, item), do: Map.update!(plan, field, &(&1 ++ [item]))

  defp group(plan) do
    Enum.reduce([:adds, :moves], plan, fn field, plan ->
      grouped = plan[field] |> Enum.group_by(fn {s, _, e, at} -> {s, e, at} end, &elem(&1, 1)) |> Enum.sort()
      Map.put(plan, field, Enum.flat_map(grouped, fn {{s, e, at}, ns} -> ns |> List.flatten() |> Enum.sort() |> Enum.chunk_every(1_000) |> Enum.map(&{s, &1, e, at}) end))
    end)
  end
end
