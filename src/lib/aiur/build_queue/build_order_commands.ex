defmodule Aiur.BuildQueue.BuildOrderCommands do
  @moduledoc false
  require Logger
  alias Aiur.BuildQueue.{ListCommands, Model.Queue, Reconcile}
  alias Aiur.BuildQueue.Sources.BuildOrder

  @spec prepare(map(), {:adopt | :unadopt, term()}) :: {:ok, map(), list(), map(), map()} | {:error, term()}
  def prepare(state, {:adopt, root}) when is_integer(root) and root > 0 do
    queues = Enum.filter(state.document.queues, &(&1.kind == :build_order))

    cond do
      Enum.any?(queues, &(&1.root == root)) -> {:error, :already_adopted}
      length(queues) >= 32 -> {:error, :too_many_roots}
      true -> adopt(state, root)
    end
  end

  def prepare(state, {:unadopt, root}) do
    case Enum.find(state.document.queues, &(&1.kind == :build_order and &1.root == root)) do
      nil -> {:error, :not_adopted}
      queue -> unadopt(state, queue)
    end
  end

  def prepare(_, _), do: {:error, :invalid_root}

  defp adopt(state, root) do
    with {:ok, snapshot} <- BuildOrder.watch(root, state.build_order_projection),
         {:ok, id} <- ListCommands.queue_id(state.document) do
      queue = %Queue{id: id, name: "Build Order ##{root}", kind: :build_order, root: root, held: false, generation: 0, created_at: DateTime.from_unix!(state.clock.(), :millisecond)}
      document = %{state.document | queues: state.document.queues ++ [queue]}
      {document, actions, sources, verdicts, refusals} = import(document, queue, {:ok, snapshot})
      observations = Reconcile.observations(state)
      document = ListCommands.record(state, document, actions, observations)
      updates = %{sources: Map.merge(state.sources, sources), source_verdicts: Map.merge(state.source_verdicts, verdicts), refusals: refusals}
      {:ok, document, actions, observations, updates}
    else
      {:unavailable, reason} -> {:error, reason}
      error -> error
    end
  end

  defp unadopt(state, queue) do
    ids = for item <- state.document.items, item.queue_id == queue.id, do: item.issue_id

    document = %{
      state.document
      | queues: Enum.reject(state.document.queues, &(&1.id == queue.id)),
        items: Enum.reject(state.document.items, &(&1.queue_id == queue.id)),
        edges: Enum.reject(state.document.edges, &(&1.source == :build_order and &1.dependent in ids))
    }

    observations = Reconcile.observations(state)
    actions = Enum.map(ids, &{:unmark, &1})
    document = ListCommands.record(state, document, actions, observations)
    {:ok, document, actions, observations, %{sources: Map.delete(state.sources, key(queue)), source_verdicts: Map.drop(state.source_verdicts, ids), refusals: []}}
  end

  @spec sync(map()) :: {map(), list(), map(), map()}
  def sync(state) do
    queues = Enum.filter(state.document.queues, &(&1.kind == :build_order))

    snapshots = BuildOrder.watch_all(Enum.map(queues, & &1.root), state.build_order_projection)

    Enum.reduce(queues, {state.document, [], %{}, %{}}, fn queue, {document, actions, sources, verdicts} ->
      snapshot = Map.fetch!(snapshots, queue.root)
      {document, marks, source, unknowns, _refusals} = import(document, queue, snapshot)
      {document, actions ++ marks, Map.merge(sources, source), Map.merge(verdicts, unknowns)}
    end)
  end

  @spec hint(map()) :: map()
  def hint(%{document: nil} = state), do: state
  def hint(state), do: refresh_queues(state, state.document.queues)

  @spec refresh_unavailable(map()) :: map()
  def refresh_unavailable(state) do
    queues = Enum.filter(state.document.queues, &match?({:unavailable, reason} when reason not in [:completed, :projection_down, :projection_unavailable], state.sources[key(&1)]))
    refresh_queues(state, queues)
  end

  defp refresh_queues(state, queues) do
    now = state.clock.()
    interval = state.settings.build_queue.reconcile_interval_seconds * 1_000
    roots = for queue <- queues, queue.kind == :build_order, now - Map.get(state.source_refreshes, queue.root, -1_000_000_000) >= interval, do: queue.root
    BuildOrder.refresh_all(roots, state.build_order_projection, now)
    %{state | source_refreshes: Map.merge(state.source_refreshes, Map.new(roots, &{&1, now}))}
  end

  @spec release(pos_integer(), map()) :: term()
  def release(root, state) do
    case BuildOrder.release(root, state.build_order_projection) do
      :ok ->
        :ok

      {_, reason} = error ->
        Logger.warning("Build queue projection release failed root=#{root} reason=#{inspect(reason)}")
        error
    end
  end

  @spec generation_root(map()) :: pos_integer() | nil
  def generation_root(snapshot), do: BuildOrder.root_number(snapshot)

  defp import(document, queue, snapshot) do
    context = Map.put(document, :source_snapshots, %{queue.root => snapshot})

    case BuildOrder.members(queue, context) do
      {:ok, items, edges, :current} ->
        merge(document, queue, items, edges, elem(snapshot, 1))

      {:unavailable, reason} ->
        unknowns = for item <- document.items, item.queue_id == queue.id, into: %{}, do: {item.issue_id, {:unknown, [reason]}}
        {document, [], %{key(queue) => {:unavailable, reason}}, unknowns, []}
    end
  end

  defp merge(document, queue, items, edges, snapshot) do
    others = Enum.reject(document.items, &(&1.queue_id == queue.id))
    owned = MapSet.new(others, & &1.issue_id)
    {refused, accepted} = Enum.split_with(items, &MapSet.member?(owned, &1.issue_id))
    ids = MapSet.new(accepted, & &1.issue_id)
    old_ids = MapSet.new(for item <- document.items, item.queue_id == queue.id, do: item.issue_id)
    actions = for id <- MapSet.difference(ids, old_ids), do: {:mark, id}
    actions = actions ++ for id <- MapSet.difference(old_ids, ids), do: {:unmark, id}
    edges = Enum.filter(edges, &MapSet.member?(ids, &1.dependent))
    retained = Enum.reject(document.edges, &(&1.source == :build_order and MapSet.member?(old_ids, &1.dependent)))
    queues = Enum.map(document.queues, &if(&1.id == queue.id, do: %{&1 | generation: snapshot.generation}, else: &1))
    document = %{document | queues: queues, items: others ++ accepted, edges: Enum.uniq(retained ++ edges)}
    refusals = Enum.map(refused, &{&1.issue_id, :already_queued})
    {document, actions, %{key(queue) => :current}, Map.take(BuildOrder.unknowns(snapshot), MapSet.to_list(ids)), refusals}
  end

  defp key(queue), do: "build_order:#{queue.root}"
end
