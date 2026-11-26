defmodule Aiur.BuildQueue.BuildOrderCommands do
  @moduledoc """
  Adopt, unadopt and sync the queue entries whose membership comes from a source.

  A Build Order entry follows a selected root projection; a feature entry follows
  the feature registry; an epic entry follows its features plus its root. Each keeps
  the item record of a member that is already queued, so operator holds and manual
  overrides survive every sync. Ownership is ranked: a list owns over a feature, a
  feature over an epic or Build Order. An entry refuses a member an equal or higher
  owner holds and takes one from a lower owner.
  """
  require Logger
  alias Aiur.BuildQueue.{ListCommands, Model.Queue, QueueRanks, Reconcile, Sets}
  alias Aiur.BuildQueue.Sources.{BuildOrder, Epic, Feature}

  @max_entries 32

  @spec prepare(
          map(),
          {:adopt | :unadopt, term()}
          | {:adopt, term(), String.t() | nil}
          | {:adopt, term(), String.t() | nil, Aiur.StartTrigger.trigger() | nil}
          | {:adopt, term(), String.t() | nil, Aiur.StartTrigger.trigger() | nil, non_neg_integer()}
          | {:adopt_feature | :unadopt_feature, term()}
          | {:adopt_feature, term(), String.t() | nil}
          | {:adopt_feature, term(), String.t() | nil, Aiur.StartTrigger.trigger() | nil}
          | {:adopt_feature, term(), String.t() | nil, Aiur.StartTrigger.trigger() | nil, non_neg_integer()}
          | {:adopt_epic | :unadopt_epic, term()}
          | {:adopt_epic, term(), String.t() | nil}
          | {:adopt_epic, term(), String.t() | nil, Aiur.StartTrigger.trigger() | nil}
          | {:adopt_epic, term(), String.t() | nil, Aiur.StartTrigger.trigger() | nil, non_neg_integer()}
        ) ::
          {:ok, map(), list(), map(), map()} | {:error, term()}
  def prepare(state, {:adopt, root, name, trigger, rank}) do
    with true <- is_integer(rank) and rank >= 0 and rank <= length(state.document.queues),
         {:ok, document, actions, observations, updates} <- prepare(state, {:adopt, root, name, trigger}),
         name = name || "Build Order ##{root}",
         {:ok, document} <- QueueRanks.creation(document, state.document, queue: name, rank: rank) do
      {:ok, document, actions, observations, updates}
    else
      false -> {:error, :invalid_position}
      error -> error
    end
  end

  def prepare(state, {:adopt, root}), do: prepare(state, {:adopt, root, nil})
  def prepare(state, {:adopt, root, name}), do: prepare(state, {:adopt, root, name, nil})

  def prepare(state, {:adopt, root, name, trigger}) when is_integer(root) and root > 0 do
    name = if is_nil(name), do: "Build Order ##{root}", else: name
    queues = Enum.filter(state.document.queues, &(&1.kind == :build_order))

    cond do
      Enum.any?(queues, &(&1.root == root)) -> {:error, :already_adopted}
      length(queues) >= @max_entries -> {:error, :too_many_roots}
      not is_binary(name) or String.trim(name) == "" -> {:error, :invalid_queue}
      Enum.any?(state.document.queues, &(&1.name == name)) -> {:error, :queue_exists}
      true -> adopt_root(state, root, name, trigger)
    end
  end

  def prepare(state, {:unadopt, root}) do
    case Enum.find(state.document.queues, &(&1.kind == :build_order and &1.root == root)) do
      nil -> {:error, :not_adopted}
      queue -> unadopt(state, queue)
    end
  end

  def prepare(state, {:adopt_feature, slug, name, trigger, rank}) do
    with true <- is_integer(rank) and rank >= 0 and rank <= length(state.document.queues),
         {:ok, document, actions, observations, updates} <- prepare(state, {:adopt_feature, slug, name, trigger}),
         name = name || "Feature #{slug}",
         {:ok, document} <- QueueRanks.creation(document, state.document, queue: name, rank: rank) do
      {:ok, document, actions, observations, updates}
    else
      false -> {:error, :invalid_position}
      error -> error
    end
  end

  def prepare(state, {:adopt_feature, slug}), do: prepare(state, {:adopt_feature, slug, nil})
  def prepare(state, {:adopt_feature, slug, name}), do: prepare(state, {:adopt_feature, slug, name, nil})

  def prepare(state, {:adopt_feature, slug, name, trigger}) when is_binary(slug) do
    name = if is_nil(name), do: "Feature #{slug}", else: name
    queues = Enum.filter(state.document.queues, &(&1.kind == :feature))

    cond do
      Enum.any?(queues, &(&1.feature == slug)) -> {:error, :already_adopted}
      length(queues) >= @max_entries -> {:error, :too_many_features}
      not is_binary(name) or String.trim(name) == "" -> {:error, :invalid_queue}
      Enum.any?(state.document.queues, &(&1.name == name)) -> {:error, :queue_exists}
      true -> adopt_feature(state, slug, name, trigger)
    end
  end

  def prepare(state, {:unadopt_feature, slug}) do
    case Enum.find(state.document.queues, &(&1.kind == :feature and &1.feature == slug)) do
      nil -> {:error, :not_adopted}
      queue -> unadopt(state, queue)
    end
  end

  def prepare(state, {:adopt_epic, slug, name, trigger, rank}) do
    with true <- is_integer(rank) and rank >= 0 and rank <= length(state.document.queues),
         {:ok, document, actions, observations, updates} <- prepare(state, {:adopt_epic, slug, name, trigger}),
         name = name || "Epic #{slug}",
         {:ok, document} <- QueueRanks.creation(document, state.document, queue: name, rank: rank) do
      {:ok, document, actions, observations, updates}
    else
      false -> {:error, :invalid_position}
      error -> error
    end
  end

  def prepare(state, {:adopt_epic, slug}), do: prepare(state, {:adopt_epic, slug, nil})
  def prepare(state, {:adopt_epic, slug, name}), do: prepare(state, {:adopt_epic, slug, name, nil})

  def prepare(state, {:adopt_epic, slug, name, trigger}) when is_binary(slug) do
    name = if is_nil(name), do: "Epic #{slug}", else: name
    adopt_epic_checked(state, slug, name, trigger)
  end

  def prepare(state, {:unadopt_epic, slug}) do
    case Enum.find(state.document.queues, &(&1.kind == :epic and &1.epic == slug)) do
      nil -> {:error, :not_adopted}
      queue -> unadopt(state, queue, epic_root(state, slug))
    end
  end

  def prepare(_, _), do: {:error, :invalid_root}

  # `--build-order ROOT` adopts the root's epic when the registry has one, so its features join too.
  defp adopt_root(state, root, name, trigger) do
    case Epic.for_root(root, registry: state.feature_registry) do
      {:ok, slug} -> adopt_epic_checked(state, slug, name, trigger)
      :none -> adopt(state, root, name, trigger)
    end
  end

  defp adopt_epic_checked(state, slug, name, trigger) do
    queues = Enum.filter(state.document.queues, &(&1.kind == :epic))

    cond do
      Enum.any?(queues, &(&1.epic == slug)) -> {:error, :already_adopted}
      length(queues) >= @max_entries -> {:error, :too_many_roots}
      not is_binary(name) or String.trim(name) == "" -> {:error, :invalid_queue}
      Enum.any?(state.document.queues, &(&1.name == name)) -> {:error, :queue_exists}
      true -> adopt_epic(state, slug, name, trigger)
    end
  end

  defp epic_root(state, slug) do
    with {:ok, %{epics: epics}} <- state.feature_registry.epics([]),
         %{root: root} when is_integer(root) <- Enum.find(epics, &(&1.slug == slug)) do
      root
    else
      _ -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp adopt(state, root, name, trigger) do
    with :ok <- valid_trigger(trigger),
         {:ok, snapshot} <- BuildOrder.watch(root, state.build_order_projection),
         {:ok, id} <- ListCommands.queue_id(state.document) do
      queue = %Queue{
        id: id,
        name: name,
        rank: Sets.next_rank(state.document),
        kind: :build_order,
        root: root,
        start_trigger: trigger,
        held: false,
        generation: 0,
        created_at: DateTime.from_unix!(state.clock.(), :millisecond)
      }

      document = %{state.document | queues: state.document.queues ++ [queue]}
      observations = Reconcile.observations(state)
      {document, actions, sources, verdicts, refusals} = import(document, queue, {:ok, snapshot}, observations)
      document = ListCommands.record(state, document, actions, observations)

      updates = %{
        sources: Map.merge(state.sources, sources) |> with_elsewhere(queue, document, refusals),
        source_verdicts: Map.merge(state.source_verdicts, verdicts),
        refusals: refusals
      }

      {:ok, document, actions, observations, updates}
    else
      {:unavailable, reason} -> {:error, reason}
      error -> error
    end
  end

  defp adopt_feature(state, slug, name, trigger),
    do: adopt_registry(state, name, trigger, [kind: :feature, feature: slug], Feature.watch(slug, registry: state.feature_registry))

  defp adopt_epic(state, slug, name, trigger),
    do: adopt_registry(state, name, trigger, [kind: :epic, epic: slug], Epic.watch(slug, registry: state.feature_registry, projection: state.build_order_projection))

  defp adopt_registry(state, name, trigger, fields, watched) do
    with :ok <- valid_trigger(trigger),
         {:ok, snapshot} <- watched,
         {:ok, id} <- ListCommands.queue_id(state.document) do
      queue = %Queue{
        id: id,
        name: name,
        rank: Sets.next_rank(state.document),
        kind: Keyword.fetch!(fields, :kind),
        feature: fields[:feature],
        epic: fields[:epic],
        root: nil,
        start_trigger: trigger,
        held: false,
        generation: 0,
        created_at: DateTime.from_unix!(state.clock.(), :millisecond)
      }

      document = %{state.document | queues: state.document.queues ++ [queue]}
      observations = Reconcile.observations(state)
      {document, actions, sources, verdicts, refusals} = import(document, queue, {:ok, snapshot}, observations)
      document = ListCommands.record(state, document, actions, observations)

      updates = %{
        sources: Map.merge(state.sources, sources) |> with_elsewhere(queue, document, refusals),
        source_verdicts: Map.merge(state.source_verdicts, verdicts),
        refusals: refusals
      }

      {:ok, document, actions, observations, updates}
    else
      {:unavailable, reason} -> {:error, reason}
      error -> error
    end
  end

  defp valid_trigger(nil), do: :ok
  defp valid_trigger(trigger), do: if(trigger in Aiur.StartTrigger.triggers(), do: :ok, else: {:error, :invalid_start_trigger})

  defp unadopt(state, queue, release_root \\ nil) do
    ids = for item <- state.document.items, item.queue_id == queue.id, do: item.issue_id
    source = edge_source(queue)

    document = %{
      state.document
      | queues: Enum.reject(state.document.queues, &(&1.id == queue.id)),
        items: Enum.reject(state.document.items, &(&1.queue_id == queue.id)),
        edges: Enum.reject(state.document.edges, &(&1.source == source and &1.dependent in ids))
    }

    observations = Reconcile.observations(state)
    actions = Enum.map(ids, &{:unmark, &1})
    document = ListCommands.record(state, document, actions, observations)

    {:ok, document, actions, observations,
     %{sources: Map.delete(state.sources, key(queue)), source_verdicts: Map.drop(state.source_verdicts, ids), refusals: [], release_root: release_root(state, queue, release_root)}}
  end

  # A root another entry still follows stays demanded.
  defp release_root(state, queue, root) do
    if root && not Enum.any?(state.document.queues, &(&1.id != queue.id and (&1.root == root or &1.kind == :epic))), do: root
  end

  @spec sync(map(), map()) :: {map(), list(), map(), map()}
  def sync(state, observations) do
    queues = Enum.filter(state.document.queues, &(&1.kind in [:build_order, :feature, :epic]))
    snapshots = watch_all(queues, state)

    Enum.reduce(queues, {state.document, [], %{}, %{}}, fn queue, {document, actions, sources, verdicts} ->
      snapshot = Map.fetch!(snapshots, source_key(queue))
      {document, marks, source, unknowns, refusals} = import(document, queue, snapshot, observations)
      {document, actions ++ marks, Map.merge(sources, with_elsewhere(source, queue, document, refusals)), Map.merge(verdicts, unknowns)}
    end)
  end

  @doc "Key under which a set's members owned by another set are held in the transient sources map."
  @spec elsewhere_key(map()) :: String.t()
  def elsewhere_key(queue), do: key(queue) <> ":elsewhere"

  # A source member another entry owns stays with that entry; the operator sees who holds it.
  defp with_elsewhere(sources, queue, document, refusals) do
    case Enum.map(refusals, &{elem(&1, 0), owner(document, &1)}) do
      [] -> sources
      entries -> Map.put(sources, elsewhere_key(queue), entries)
    end
  end

  defp owner(document, {id, _reason}) do
    with %{queue_id: queue_id} <- Enum.find(document.items, &(&1.issue_id == id)),
         %{name: name} <- Enum.find(document.queues, &(&1.id == queue_id)) do
      name
    else
      _ -> nil
    end
  end

  defp watch_all(queues, state) do
    roots = for queue <- queues, queue.kind == :build_order, do: queue.root
    features = for queue <- queues, queue.kind == :feature, do: queue.feature
    epics = for queue <- queues, queue.kind == :epic, do: queue.epic

    BuildOrder.watch_all(roots, state.build_order_projection)
    |> Map.merge(Map.new(features, &{&1, Feature.watch(&1, registry: state.feature_registry)}))
    |> Map.merge(Map.new(epics, &{{:epic, &1}, Epic.watch(&1, registry: state.feature_registry, projection: state.build_order_projection)}))
  end

  @spec hint(map()) :: map()
  def hint(%{document: nil} = state), do: state
  def hint(state), do: refresh_queues(state, state.document.queues)

  @spec refresh_unavailable(map()) :: map()
  def refresh_unavailable(state) do
    queues =
      Enum.filter(state.document.queues, fn queue ->
        queue.kind == :build_order and
          match?({:unavailable, reason} when reason not in [:completed, :projection_down, :projection_unavailable], state.sources[key(queue)])
      end)

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

  @doc "Releases the root projection a just-removed entry no longer follows."
  @spec release_after(map(), atom(), term(), map()) :: term()
  def release_after(state, :unadopt, root, _updates), do: release(root, state)
  def release_after(state, _verb, _target, %{release_root: root}) when not is_nil(root), do: release(root, state)
  def release_after(_state, _verb, _target, _updates), do: :ok

  @spec generation_root(map()) :: pos_integer() | nil
  def generation_root(snapshot), do: BuildOrder.root_number(snapshot)

  defp import(document, queue, snapshot, observations) do
    context =
      document
      |> Map.put(:source_snapshots, %{source_key(queue) => snapshot})
      |> Map.put(:observations, observations)

    case source(queue).members(queue, context) do
      {:ok, items, edges, :current} ->
        merge(document, queue, items, edges, generation(snapshot), unknowns(queue, snapshot))

      {:unavailable, reason} ->
        unknowns = for item <- document.items, item.queue_id == queue.id, into: %{}, do: {item.issue_id, {:unknown, [reason]}}
        {document, [], %{key(queue) => {:unavailable, reason}}, unknowns, []}
    end
  end

  defp merge(document, queue, items, edges, generation, unknowns) do
    others = Enum.reject(document.items, &(&1.queue_id == queue.id))
    ranks = Map.new(document.queues, &{&1.id, precedence(&1)})
    holders = Map.new(others, &{&1.issue_id, Map.fetch!(ranks, &1.queue_id)})
    {held, free} = Enum.split_with(items, &Map.has_key?(holders, &1.issue_id))
    {taken, refused} = Enum.split_with(held, &(holders[&1.issue_id] > precedence(queue)))
    taken_ids = MapSet.new(taken, & &1.issue_id)
    others = Enum.reject(others, &MapSet.member?(taken_ids, &1.issue_id))
    accepted = free ++ Enum.map(taken, &%{&1 | queue_id: queue.id})
    ids = MapSet.new(accepted, & &1.issue_id)
    old_ids = MapSet.new(for item <- document.items, item.queue_id == queue.id, do: item.issue_id)
    actions = for id <- MapSet.difference(MapSet.difference(ids, old_ids), taken_ids), do: {:mark, id}
    actions = actions ++ for id <- MapSet.difference(old_ids, ids), do: {:unmark, id}
    edges = Enum.filter(edges, &MapSet.member?(ids, &1.dependent))
    retained = Enum.reject(document.edges, &(&1.source == edge_source(queue) and MapSet.member?(old_ids, &1.dependent)))
    queues = Enum.map(document.queues, &if(&1.id == queue.id, do: %{&1 | generation: max(&1.generation, generation)}, else: &1))
    document = %{document | queues: queues, items: others ++ accepted, edges: Enum.uniq(retained ++ edges)}
    refusals = Enum.map(refused, &{&1.issue_id, :already_queued})
    {document, actions, %{key(queue) => :current}, Map.take(unknowns, MapSet.to_list(ids)), refusals}
  end

  # Lower number owns: a list over a feature, a feature over an epic or Build Order.
  defp precedence(%{kind: :list}), do: 0
  defp precedence(%{kind: :feature}), do: 1
  defp precedence(_queue), do: 2

  defp source(%{kind: :feature}), do: Feature
  defp source(%{kind: :epic}), do: Epic
  defp source(_queue), do: BuildOrder

  defp unknowns(%{kind: :build_order}, {:ok, snapshot}), do: BuildOrder.unknowns(snapshot)
  defp unknowns(%{kind: :epic}, {:ok, %{root: %{data: _} = root}}), do: BuildOrder.unknowns(root)
  defp unknowns(_queue, _snapshot), do: %{}

  defp generation({:ok, %{registry: registry}}), do: Map.get(registry, :generation, 0)
  defp generation({:ok, snapshot}), do: Map.get(snapshot, :generation, 0)
  defp generation(_snapshot), do: 0

  defp edge_source(%{kind: :feature}), do: :feature
  defp edge_source(_queue), do: :build_order

  defp key(%{kind: :feature} = queue), do: "feature:#{queue.feature}"
  defp key(%{kind: :epic} = queue), do: "epic:#{queue.epic}"
  defp key(queue), do: "build_order:#{queue.root}"

  @doc "Key of a registry-backed entry in the transient sources map."
  @spec source_status_key(map()) :: String.t()
  def source_status_key(queue), do: key(queue)

  # Feature and epic slugs share a namespace in the snapshot map, so epics are keyed apart.
  defp source_key(%{kind: :feature} = queue), do: queue.feature
  defp source_key(%{kind: :epic} = queue), do: {:epic, queue.epic}
  defp source_key(queue), do: queue.root
end
