defmodule Aiur.BuildQueue.Sources.Feature do
  @moduledoc """
  Optional dependency input from the feature registry.

  A feature entry has no stored positions: its members are whatever the registry
  currently owns for that slug, so a ticket filed into the feature later joins on
  the next reconcile. Members that are already queued keep their item record, so
  an operator hold or manual override survives every sync.

  The registry does not know whether a member is still open, so the caller
  supplies the open-issue observation. A closed member that is already queued
  stays in the entry long enough for the planner to dequeue it, and a closed
  member that is not queued is never added. Without a fresh observation the
  source is unavailable rather than guessing, which leaves membership untouched.
  """
  @behaviour Aiur.BuildQueue.Source
  alias Aiur.BuildOrder.Features
  alias Aiur.BuildQueue.Model.Item

  @spec watch(String.t(), keyword()) :: {:ok, map()} | {:unavailable, term()}
  def watch(slug, opts \\ []) do
    registry = Keyword.get(opts, :registry, Features)

    case registry.snapshot(Keyword.delete(opts, :registry)) do
      {:ok, snapshot} ->
        if Map.has_key?(snapshot.features, slug), do: {:ok, snapshot}, else: {:unavailable, :feature_not_found}

      {:error, %{state: state}} ->
        {:unavailable, if(state == :stale, do: :stale, else: :partial)}

      {:error, _reason} ->
        {:unavailable, :partial}
    end
  catch
    :exit, _reason -> {:unavailable, :features_down}
  end

  @impl true
  def members(%{kind: :feature} = queue, context) do
    with {:ok, snapshot} <- Map.get(Map.get(context, :source_snapshots, %{}), queue.feature, {:unavailable, :features_down}),
         {:ok, open} <- open_ids(context) do
      existing = Map.new(context.items, &{&1.issue_id, &1})
      ids = snapshot |> members_of(queue.feature) |> Enum.filter(&(MapSet.member?(open, &1) or Map.has_key?(existing, &1)))
      {:ok, Enum.map(ids, &Map.get(existing, &1, item(&1, queue))), [], :current}
    end
  end

  def members(_, _), do: {:unavailable, :not_feature}

  @doc "Registry member numbers for a slug, as issue IDs in ascending order."
  @spec members_of(map(), String.t()) :: [String.t()]
  def members_of(snapshot, slug) do
    snapshot.owners
    |> Enum.filter(fn {_number, owner} -> owner.feature == slug end)
    |> Enum.map(fn {number, _owner} -> Integer.to_string(number) end)
    |> Enum.sort_by(&String.to_integer/1)
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
