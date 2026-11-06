defmodule Aiur.BuildQueue.Sources.Epic do
  @moduledoc """
  Optional dependency input from an epic record.

  An epic entry's members are the union of its features' registry members and, when
  the epic has a Build Order root, the root's open sub-issues, without duplicates.
  Nothing is stored per member, so a ticket filed into one of the epic's features
  later joins on the next reconcile. Already-queued members keep their item record.

  The snapshot is `%{registry: snapshot, root: nil | root_snapshot}`. Without a
  usable root projection the source is unavailable rather than answering with the
  features alone, which would unmark every root sub-issue.
  """
  @behaviour Aiur.BuildQueue.Source
  alias Aiur.BuildOrder.Features
  alias Aiur.BuildQueue.Model.Item
  alias Aiur.BuildQueue.Sources.{BuildOrder, Feature}

  @spec watch(String.t(), keyword()) :: {:ok, map()} | {:unavailable, term()}
  def watch(slug, opts \\ []) do
    registry = Keyword.get(opts, :registry, Features)

    with {:ok, snapshot} <- registry_snapshot(registry),
         {:ok, epic} <- find(snapshot, slug),
         {:ok, root} <- root_snapshot(epic.root, Keyword.get(opts, :projection)) do
      {:ok, %{registry: snapshot, epic: epic, root: root}}
    end
  catch
    :exit, _reason -> {:unavailable, :features_down}
  end

  @doc "The epic record whose Build Order root is `root`, if the registry has one."
  @spec for_root(pos_integer(), keyword()) :: {:ok, String.t()} | :none
  def for_root(root, opts \\ []) do
    with {:ok, snapshot} <- registry_snapshot(Keyword.get(opts, :registry, Features)),
         %{slug: slug} <- Enum.find(Map.get(snapshot, :epics, []), &(&1.root == root)) do
      {:ok, slug}
    else
      _ -> :none
    end
  catch
    :exit, _reason -> :none
  end

  @impl true
  def members(%{kind: :epic} = queue, context) do
    with {:ok, %{registry: registry, epic: epic, root: root}} <-
           Map.get(Map.get(context, :source_snapshots, %{}), {:epic, queue.epic}, {:unavailable, :features_down}),
         {:ok, open} <- open_ids(context),
         {:ok, root_items, edges} <- root_members(queue, epic, root, context) do
      existing = Map.new(context.items, &{&1.issue_id, &1})
      feature_ids = Enum.flat_map(epic.features, &Feature.members_of(registry, &1)) |> Enum.filter(&(MapSet.member?(open, &1) or Map.has_key?(existing, &1)))
      root_ids = Enum.map(root_items, & &1.issue_id)
      ids = Enum.uniq(feature_ids ++ root_ids) |> Enum.sort_by(&String.to_integer/1)
      {:ok, Enum.map(ids, &Map.get(existing, &1, item(&1, queue))), edges, :current}
    end
  end

  def members(_, _), do: {:unavailable, :not_epic}

  defp registry_snapshot(registry) do
    case registry.snapshot([]) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, %{state: :stale}} -> {:unavailable, :stale}
      _ -> {:unavailable, :partial}
    end
  end

  defp find(snapshot, slug) do
    case Enum.find(Map.get(snapshot, :epics, []), &(&1.slug == slug)) do
      nil -> {:unavailable, :epic_not_found}
      epic -> {:ok, epic}
    end
  end

  defp root_snapshot(nil, _projection), do: {:ok, nil}
  defp root_snapshot(root, projection), do: BuildOrder.watch(root, projection)

  defp root_members(_queue, %{root: nil}, _root, _context), do: {:ok, [], []}

  defp root_members(queue, %{root: root}, snapshot, context) do
    root_queue = %{queue | kind: :build_order, root: root}
    context = Map.put(context, :source_snapshots, %{root => {:ok, snapshot}})

    case BuildOrder.members(root_queue, context) do
      {:ok, items, edges, :current} -> {:ok, items, edges}
      error -> error
    end
  end

  defp open_ids(context) do
    case Map.get(context, :observations, %{}) do
      observations when map_size(observations) == 0 -> {:unavailable, :observation_unavailable}
      observations -> {:ok, MapSet.new(Map.keys(observations))}
    end
  end

  defp item(id, queue),
    do: %Item{issue_id: id, queue_id: queue.id, position: nil, hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}
end
