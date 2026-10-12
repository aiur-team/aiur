defmodule Aiur.BuildQueue.Sources.ProjectionRead do
  @moduledoc "Reads existing Build Order projections without demand, refresh, or upstream requests."
  alias Aiur.BuildOrder.{Catalog, GraphProjection, ProgressRenderer, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildQueue.ReadModel

  @spec read(pos_integer(), integer(), GenServer.server()) :: map()
  def read(root, now, server \\ GraphProjection) do
    with %Snapshot{data: %Catalog{entries: entries}} <- GraphProjection.catalog(server),
         [entry] <- Enum.filter(entries, &(&1.identity && &1.identity.identifier == to_string(root))),
         {:ok, %Snapshot{data: %SelectedRoot{} = data, health: health}} <- GraphProjection.selected(server, entry.identity) do
      source = health(health, now)
      %{source: source, progress: progress(data, source)}
    else
      _ -> unavailable(now, :projection_unavailable)
    end
  catch
    :exit, _reason -> unavailable(now, :projection_unavailable)
  end

  defp progress(_data, %{freshness: :unknown}), do: unknown_progress()

  defp progress(data, _source) do
    completion = ProgressRenderer.json(data.root)

    %{
      completed: if(completion["progress"], do: Enum.count(data.members, &(&1.lifecycle.state == :closed and &1.lifecycle.state_reason == :completed))),
      resolved: completion["progress_resolved_count"],
      total: data.root.member_count,
      percent: completion["progress"],
      resolution: completion["progress_resolution"]
    }
  end

  defp health(health, now) do
    observed = if health.observed_at, do: DateTime.to_unix(health.observed_at, :millisecond)
    source = ReadModel.source(observed, now, 9_223_372_036_854_775_807, Enum.reject([health.failure], &is_nil/1))

    freshness =
      case health.state do
        :healthy -> if(observed, do: :current, else: :unknown)
        :stale -> :stale
        _ -> :unknown
      end

    %{source | freshness: freshness, partial: not health.complete?, state: if(health.state in [:healthy, :stale], do: :ok, else: :unavailable)}
  end

  defp unavailable(now, reason), do: %{source: ReadModel.source(nil, now, 1, [reason]), progress: unknown_progress()}
  defp unknown_progress, do: %{completed: nil, resolved: nil, total: nil, percent: nil, resolution: :unknown}
end

defmodule Aiur.BuildQueue.Sources.BuildOrder do
  @moduledoc "Optional dependency input from complete, healthy selected Build Order projections."
  @behaviour Aiur.BuildQueue.Source
  alias Aiur.{Bounded, TrackerIdentity}
  alias Aiur.BuildOrder.{GraphProjection, ProviderHealth, SelectedRoot}
  alias Aiur.BuildQueue.Model.{Edge, Item}

  @spec projection() :: module()
  def projection, do: GraphProjection

  @spec available?(GenServer.server()) :: boolean()
  def available?(server), do: GenServer.whereis(server) != nil

  @spec watch(pos_integer(), GenServer.server()) :: {:ok, map()} | {:unavailable, term()}
  def watch(root, server) do
    with {:ok, identity} <- identity(root, server),
         {:ok, snapshot} <- GraphProjection.demand(server, identity),
         :ok <- GraphProjection.subscribe_selected(server, identity) do
      {:ok, snapshot}
    else
      {:error, %{kind: :capacity}} -> {:unavailable, :too_many_roots}
      {:error, _} -> {:unavailable, :partial}
      unavailable -> unavailable
    end
  catch
    :exit, {:noproc, _} -> {:unavailable, :projection_down}
    :exit, _ -> {:unavailable, :projection_unavailable}
  end

  @spec watch_all([pos_integer()], GenServer.server()) :: map()
  def watch_all(roots, server), do: collect(roots, &watch(&1, server))

  @spec refresh_all([pos_integer()], GenServer.server(), integer()) :: map()
  def refresh_all(roots, server, now), do: collect(roots, &refresh(&1, server, now))

  defp collect(roots, read) do
    roots
    |> Enum.reduce({%{}, nil}, fn root, {results, failure} ->
      result = failure || read.(root)
      failure = if match?({:unavailable, reason} when reason in [:projection_down, :projection_unavailable], result), do: result
      {Map.put(results, root, result), failure}
    end)
    |> elem(0)
  end

  defp refresh(root, server, now) do
    with {:ok, identity} <- identity(root, server),
         {:ok, snapshot} <- GraphProjection.selected(server, identity) do
      if GraphProjection.read_due?(snapshot, DateTime.from_unix!(now, :millisecond)), do: GraphProjection.refresh(server, identity), else: :ok
    end
  catch
    :exit, {:noproc, _} -> {:unavailable, :projection_down}
    :exit, _ -> {:unavailable, :projection_unavailable}
  end

  @spec release(pos_integer(), GenServer.server()) :: :ok | {:unavailable, term()} | {:error, term()}
  def release(root, server) do
    with {:ok, identity} <- identity(root, server) do
      Phoenix.PubSub.unsubscribe(Aiur.PubSub, GraphProjection.selected_topic(identity))
      GraphProjection.release(server, identity)
    end
  catch
    :exit, {:noproc, _} -> {:unavailable, :projection_down}
    :exit, _ -> {:unavailable, :projection_unavailable}
  end

  @impl true
  def members(%{kind: :build_order} = queue, document) do
    with {:ok, snapshot} <- Map.get(Map.get(document, :source_snapshots, %{}), queue.root, {:unavailable, :projection_down}),
         :ok <- usable(snapshot) do
      existing = Map.new(document.items, &{&1.issue_id, &1})
      members = Enum.filter(snapshot.data.members, &(&1.lifecycle.state == :open or Map.has_key?(existing, id(&1.identity))))
      items = Enum.map(members, &Map.get(existing, id(&1.identity), item(&1, queue)))
      edges = snapshot.data.members |> Enum.flat_map(& &1.dependencies) |> Enum.flat_map(&edge/1) |> Enum.uniq()
      {:ok, items, edges, :current}
    end
  end

  def members(_, _), do: {:unavailable, :not_build_order}

  @spec unknowns(map()) :: map()
  def unknowns(snapshot) do
    snapshot.data.members
    |> Enum.flat_map(& &1.dependencies)
    |> Enum.filter(&(&1.kind != :native and Bounded.same_repository?(snapshot.data.root.identity, &1.blocked_identity)))
    |> Map.new(&{id(&1.blocked_identity), {:unknown, [:external_edge]}})
  end

  @spec root_number(map()) :: pos_integer() | nil
  def root_number(%{scope: {:selected, %{identifier: identifier}}}) do
    case Integer.parse(identifier) do
      {root, ""} when root > 0 -> root
      _ -> nil
    end
  end

  def root_number(_), do: nil

  defp identity(root, server) do
    case GraphProjection.catalog(server) do
      %{data: %{entries: entries}} -> find_identity(entries, root)
      _ -> {:unavailable, :partial}
    end
  end

  defp find_identity(entries, root) do
    case Enum.find(entries, &(&1.identity && &1.identity.identifier == Integer.to_string(root))) do
      %{identity: identity} -> if TrackerIdentity.joinable?(identity), do: {:ok, identity}, else: {:unavailable, :partial}
      _ -> {:unavailable, :root_not_found}
    end
  end

  defp usable(%{health: health, data: %SelectedRoot{} = selected}) do
    cond do
      not ProviderHealth.usable?(health) -> {:unavailable, if(health.state == :stale, do: :stale, else: :partial)}
      not ProviderHealth.usable?(selected.provider) or not SelectedRoot.structurally_valid?(selected) -> {:unavailable, :partial}
      selected.root.lifecycle.state == :closed -> {:unavailable, :completed}
      selected.root.lifecycle.state != :open -> {:unavailable, :partial}
      true -> :ok
    end
  end

  defp usable(_), do: {:unavailable, :partial}

  defp item(member, queue),
    do: %Item{issue_id: id(member.identity), queue_id: queue.id, position: nil, hold: nil, override: nil, promoted_at: nil, added_at: queue.created_at}

  defp edge(%{kind: :native, blocker_identity: blocker, blocked_identity: blocked}) when not is_nil(blocker) and not is_nil(blocked),
    do: [%Edge{prerequisite: id(blocker), dependent: id(blocked), source: :build_order}]

  defp edge(_), do: []
  defp id(nil), do: nil
  defp id(identity), do: identity.identifier
end
