defmodule Aiur.FeatureCLI.Writes do
  @moduledoc false
  alias Aiur.BuildOrder.Features
  alias Aiur.FeatureCLI.Output

  @spec apply(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply(args, snapshot, context) do
    meta = Keyword.take(context, [:actor, :source, :server, :timeout]) ++ Enum.to_list(Map.take(args, [:epic, :move, :remove, :replace]))

    with :ok <- known_feature(args, snapshot),
         {:ok, result} <- write(args, snapshot, meta, context) do
      ids = Enum.uniq(Map.get(args, :ids, []))
      labels = Output.label_states(ids, context)
      results = Enum.map(ids, &member_result(&1, args, snapshot, result, labels, meta))
      envelope = %{schema_version: 1, command: "feature #{args.op}", feature: args.slug, generation: result.generation, results: results}
      {:ok, Map.merge(envelope, Map.take(result, [:outcome, :previous_baseline]))}
    end
  end

  defp known_feature(%{op: :create}, _), do: :ok
  defp known_feature(args, snapshot), do: if(Map.has_key?(snapshot.features, args.slug), do: :ok, else: {:error, {:unknown_feature, args.slug}})

  defp write(%{op: :create} = args, snapshot, meta, _context) do
    existing = snapshot.features[args.slug]
    attrs = Map.take(args, [:label, :hue, :epics])

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

  defp write(%{op: :edit} = args, _snapshot, meta, context) do
    attrs = Map.take(args, [:label, :hue])
    attrs = if args[:end], do: Map.put(attrs, :to, end_time(args.end, context)), else: attrs

    with {:ok, initial} <- Features.update_feature(args.slug, attrs, meta) do
      Enum.reduce_while(Map.get(args, :add_epics, []), {:ok, initial}, &add_epic(&1, &2, args.slug, meta))
    end
  end

  defp write(%{op: :add} = args, _snapshot, meta, _context), do: Features.add(args.slug, Enum.uniq(args.ids), meta)
  defp write(%{op: :also} = args, _snapshot, meta, _context), do: Features.also(args.slug, Enum.uniq(args.ids), meta)

  defp add_epic(epic, _previous, slug, meta) do
    case Features.add_epic(slug, epic, meta) do
      {:ok, result} -> {:cont, {:ok, result}}
      error -> {:halt, error}
    end
  end

  defp same_create?(feature, attrs, slug) do
    epics = Map.get(attrs, :epics, [%{key: "f-" <> slug, label: attrs.label}])
    feature.label == attrs.label and feature.epics == epics and (not Map.has_key?(attrs, :hue) or feature.hue == attrs.hue)
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
      id not in result.changed -> :unchanged
      args.op == :remove or (args.op == :also and args[:remove]) -> :removed
      args.op == :also -> :added
      is_nil(snapshot.owners[id]) -> :added
      snapshot.owners[id].feature != args.slug -> :moved
      true -> :updated
    end
  end
end
