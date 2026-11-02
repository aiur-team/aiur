defmodule Aiur.FeatureCLI.Writes do
  @moduledoc false
  alias Aiur.BuildOrder.Features
  alias Aiur.BuildOrder.Features.FeatureData
  alias Aiur.FeatureCLI.Output

  @spec apply(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply(%{op: :confirm} = args, _snapshot, context) do
    meta = Keyword.take(context, [:actor, :source, :server, :timeout])

    with {:ok, result} <- Features.confirm(args.slug, args.ids, meta) do
      {:ok, Map.merge(result, %{schema_version: 1, command: "feature confirm", feature: args.slug})}
    end
  end

  def apply(args, snapshot, context) do
    meta = Keyword.take(context, [:actor, :source, :server, :timeout]) ++ Enum.to_list(Map.take(args, [:epic, :move, :remove, :replace]))

    with :ok <- known_feature(args, snapshot),
         {:ok, result} <- write(args, snapshot, meta, context) do
      ids = Enum.uniq(Map.get(args, :ids, []))
      labels = Output.label_states(ids, context)
      results = Enum.map(ids, &member_result(&1, args, snapshot, result, labels, meta))
      envelope = %{schema_version: 1, command: "feature #{args.op}", feature: args.slug, generation: result.generation, results: results}
      {:ok, Map.merge(envelope, Map.take(result, [:outcome, :previous_baseline, :kept]))}
    end
  end

  defp known_feature(%{op: :create}, _), do: :ok
  defp known_feature(args, snapshot), do: if(Map.has_key?(snapshot.features, args.slug), do: :ok, else: {:error, {:unknown_feature, args.slug}})

  defp write(%{op: :create} = args, snapshot, meta, _context) do
    existing = snapshot.features[args.slug]
    attrs = Map.take(args, [:label, :hue, :epics])
    epics = attrs[:epics] || [%{key: "f-" <> args.slug, label: args.label}]
    attrs = if map_size(args[:epic_hues] || %{}) > 0, do: Map.put(attrs, :epics, decorate_epics(epics, args[:epic_hues])), else: attrs

    cond do
      is_nil(existing) -> with {:ok, result} <- Features.create(args.slug, attrs, meta), do: {:ok, Map.put(result, :outcome, :created)}
      same_create?(existing, attrs, args.slug) -> {:ok, %{generation: snapshot.generation, changed: [], outcome: :unchanged}}
      true -> {:error, {:feature_exists, args.slug}}
    end
  end

  defp write(%{op: :remove} = args, snapshot, meta, _context) do
    ids = Enum.filter(args.ids, &match?(%{feature: slug} when slug == args.slug, snapshot.owners[&1]))
    if ids == [], do: {:ok, %{generation: snapshot.generation, changed: []}}, else: Features.remove(args.slug, Enum.uniq(ids), meta)
  end

  defp write(%{op: :baseline} = args, snapshot, meta, context) do
    previous = snapshot.features[args.slug].baseline

    if previous != :none and args[:replace] != true do
      {:error, {:baseline_exists, Output.baseline(previous, context)}}
    else
      with {:ok, result} <- Features.set_baseline(args.slug, meta), do: {:ok, Map.put(result, :previous_baseline, Output.baseline(previous, context))}
    end
  end

  defp write(%{op: :edit} = args, snapshot, meta, context) do
    attrs = Map.take(args, [:label, :hue])
    attrs = if args[:end], do: Map.put(attrs, :to, end_time(args.end, context)), else: attrs

    initial = if map_size(attrs) == 0, do: {:ok, %{generation: snapshot.generation}}, else: Features.update_feature(args.slug, attrs, meta)

    with {:ok, initial} <- initial,
         {:ok, updated} <- update_existing_epics(args, snapshot, initial, meta) do
      args |> Map.get(:add_epics, []) |> decorate_epics(args[:epic_hues] || %{}) |> Enum.reduce_while({:ok, updated}, &add_epic(&1, &2, args.slug, meta))
    end
  end

  defp write(%{op: :add} = args, snapshot, meta, _context) do
    with {:ok, result} <- Features.add(args.slug, Enum.uniq(args.ids), meta),
         {:ok, updated} <- update_existing_epics(args, snapshot, result, meta) do
      {:ok, Map.merge(updated, Map.take(result, [:changed, :kept]))}
    end
  end

  defp write(%{op: :also} = args, _snapshot, meta, _context), do: Features.also(args.slug, Enum.uniq(args.ids), meta)

  defp add_epic(epic, _previous, slug, meta) do
    case Features.add_epic(slug, epic, meta) do
      {:ok, result} -> {:cont, {:ok, result}}
      error -> {:halt, error}
    end
  end

  defp decorate_epics(epics, hues),
    do:
      Enum.map(epics, fn epic ->
        case Map.get(hues, epic.key) do
          name when is_binary(name) ->
            {:ok, hue} = FeatureData.palette_hue(name)
            Map.merge(epic, %{hue: hue, color: name})

          hue when is_integer(hue) ->
            epic |> Map.delete(:color) |> Map.put(:hue, hue)

          _ ->
            epic
        end
      end)

  defp update_existing_epics(args, snapshot, previous, meta) do
    hues = args[:epic_hues] || %{}
    feature = snapshot.features[args.slug]
    changes = Map.keys(hues) |> Enum.reject(&Enum.any?(args[:add_epics] || [], fn epic -> epic.key == &1 end))
    known = MapSet.new(Enum.map(feature.epics, & &1.key))

    cond do
      not MapSet.subset?(MapSet.new(changes), known) ->
        {:error, {:unknown_epic, Enum.find(changes, &(&1 not in known))}}

      changes == [] ->
        {:ok, previous}

      true ->
        epics = feature.epics |> replace_selected_epic_hues(hues) |> decorate_epics(hues)
        Features.update_feature(args.slug, %{epics: epics}, meta)
    end
  end

  defp replace_selected_epic_hues(epics, hues), do: Enum.map(epics, &replace_selected_epic_hue(&1, hues))
  defp replace_selected_epic_hue(epic, hues), do: if(Map.has_key?(hues, epic.key), do: Map.drop(epic, [:hue, :color]), else: epic)

  defp same_create?(feature, attrs, slug) do
    epics = Map.get(attrs, :epics, [%{key: "f-" <> slug, label: attrs.label}])

    feature.label == attrs.label and length(feature.epics) == length(epics) and
      Enum.zip(feature.epics, epics)
      |> Enum.all?(fn {stored, requested} ->
        stored.key == requested.key and stored.label == requested.label and
          Enum.all?([:hue, :color], &(not Map.has_key?(requested, &1) or stored[&1] == requested[&1]))
      end) and (not Map.has_key?(attrs, :hue) or feature.hue == attrs.hue)
  end

  defp end_time("now", context), do: Keyword.get(context, :clock, &DateTime.utc_now/0).()
  defp end_time(value, _context), do: elem(DateTime.from_iso8601(value), 1)

  defp member_result(id, args, snapshot, result, labels, meta) do
    outcome = outcome(id, args, snapshot, result)
    row = %{id: id, outcome: outcome}
    row = if outcome == :removed, do: row, else: Map.put(row, :label, Map.get(labels, id, "unknown"))

    if outcome in [:added, :updated, :moved] do
      previous = snapshot.owners[id]
      confirmed = meta[:source] != "backfill-agent" or match?(%{feature: slug, confirmed: true} when slug == args.slug, previous)
      Map.merge(row, %{previous_feature: if(previous, do: previous.feature), source: meta[:source], actor: meta[:actor], confirmed: confirmed})
    else
      row
    end
  end

  defp outcome(id, args, snapshot, result) do
    cond do
      id in Map.get(result, :kept, []) -> :kept_existing
      id not in result.changed -> :unchanged
      true -> changed_outcome(id, args, snapshot)
    end
  end

  defp changed_outcome(id, args, snapshot) do
    cond do
      args.op == :remove or (args.op == :also and args[:remove]) -> :removed
      args.op == :also -> :added
      is_nil(snapshot.owners[id]) -> :added
      snapshot.owners[id].feature != args.slug -> :moved
      true -> :updated
    end
  end
end
