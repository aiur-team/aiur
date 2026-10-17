defmodule Aiur.BuildQueue.ReadModel do
  @moduledoc "Version 1 queue view from held reconciliation evidence; never performs tracker reads."
  alias Aiur.BuildQueue.Model.Edge
  alias Aiur.BuildQueue.{Progress, Readiness, SetSummary, Settings}
  alias Aiur.BuildQueue.Sources.{BuildOrder, ProjectionRead}

  @spec build(map()) :: map()
  def build(state) do
    now = state.clock.()
    document = state.document || %{queues: [], items: [], edges: [], latches: []}
    projection = Map.get(state, :build_order_projection, BuildOrder.projection())

    build_orders =
      Map.new(
        document.queues |> Enum.filter(&(&1.kind == :build_order)),
        &{&1.root, ProjectionRead.read(&1.root, now, projection)}
      )

    context = %{
      cycles: Readiness.cyclic_items(document.edges),
      build_orders: build_orders,
      state: state,
      document: document,
      now: now,
      observations: Map.get(state, :observations, %{})
    }

    context = Map.put(context, :tracker_source, tracker_source(context))

    unavailable =
      for q <- document.queues,
          context.tracker_source.freshness != :current or
            (q.kind == :build_order and build_orders[q.root].source.freshness != :current),
          do: q.id

    native_blockers = Map.get(state, :native_blockers, %{})
    native_blockers = Map.merge(native_blockers, build_order_blockers(document, context.observations))
    context = Map.put(context, :native_blockers, native_blockers)
    context = Map.put(context, :summary_edges, document.edges ++ blocker_edges(native_blockers))

    open_member_ids =
      context.state.projections
      |> Enum.filter(&(&1.state not in [:removed, :completed, :cancelled]))
      |> Enum.map(& &1.issue_id)

    queues =
      Enum.map(document.queues, &queue(&1, context))
      |> Enum.map(&Map.put(&1, :open_member_ids, open_member_ids))
      |> SetSummary.decorate(unavailable)

    sources =
      Map.new(
        document.queues |> Enum.filter(&(&1.kind == :build_order)),
        &{"build_order:#{&1.root}", build_orders[&1.root].source}
      )

    %{
      schema_version: 1,
      page: "build-queue",
      instance: System.get_env("AIUR_INSTANCE_KEY"),
      snapshot: %{captured_at: DateTime.from_unix!(now, :millisecond)},
      status: state.status,
      build_queue: %{build_order_source: BuildOrder.available?(projection)},
      sources: Map.put(sources, "tracker_observation", context.tracker_source),
      queues: queues,
      order: order_summary(queues, state)
    }
  end

  @doc "Returns startable focus members only while lower-ranked work holds a claim."
  @spec focus_starvation([map()]) :: {:starved, [pos_integer()]} | :clear
  def focus_starvation(queues) do
    ordered = Enum.sort_by(queues, &{&1.set_rank, &1.queue_id})
    focus = List.first(ordered)

    startable =
      if focus do
        Enum.filter(focus.items, &(&1.state in [:ready, :promoted, :overridden] and &1.verdict == :ready))
      else
        []
      end

    lower_claimed? =
      Enum.any?(Enum.drop(ordered, 1), fn queue ->
        Enum.any?(queue.items, &(&1.state == :claimed))
      end)

    focus_claimed? = focus && Enum.any?(focus.items, &(&1.state == :claimed))

    if startable != [] and not focus_claimed? and lower_claimed?,
      do: {:starved, Enum.map(startable, & &1.number)},
      else: :clear
  end

  @doc "Returns focus starvation from the current reconciliation projections."
  @spec focus_starvation(map(), [map()]) :: {:starved, [pos_integer()]} | :clear
  def focus_starvation(state, projections) do
    document = state.document || %{queues: [], items: []}
    queues = Enum.sort_by(document.queues, &{&1.rank, &1.id})
    projection_by_id = Map.new(projections, &{&1.issue_id, &1})
    focus = List.first(queues)
    focus_members = if focus, do: queue_projections(document.items, focus.id, projection_by_id), else: []

    startable =
      Enum.filter(focus_members, fn projection ->
        projection.state in [:ready, :promoted, :overridden] and projection.verdict == :ready and
          not blocked_by_github?(Map.get(state, :native_blockers) || %{}, projection.issue_id)
      end)

    lower_claimed? =
      queues
      |> Enum.drop(1)
      |> Enum.any?(fn queue ->
        Enum.any?(queue_projections(document.items, queue.id, projection_by_id), &(&1.state == :claimed))
      end)

    focus_claimed? = Enum.any?(focus_members, &(&1.state == :claimed))

    if startable != [] and not focus_claimed? and lower_claimed?,
      do: {:starved, Enum.map(startable, &String.to_integer(&1.issue_id))},
      else: :clear
  end

  defp queue_projections(items, queue_id, projection_by_id) do
    for %{queue_id: ^queue_id, issue_id: id} <- items,
        projection = projection_by_id[id],
        not is_nil(projection),
        do: projection
  end

  defp blocked_by_github?(native_blockers, id) do
    case Map.get(native_blockers, id) do
      {:ok, blockers} -> Enum.any?(blockers, & &1.open?)
      {:unknown, _reason} -> true
      _ -> false
    end
  end

  defp order_summary(queues, state) do
    actual = queues |> Enum.sort_by(&{&1.set_rank, &1.queue_id}) |> Enum.map(& &1.name)
    {declared, source} = declared_order(queues, state)

    %{
      declared: declared,
      actual: actual,
      source: source
    }
  end

  defp declared_order(queues, %{document: document} = state) when is_map(document) do
    roots = queues |> Enum.filter(&(&1.kind == :build_order)) |> Map.new(&{&1.root, &1.name})
    root_edges = Enum.filter(document.edges, &(&1.prerequisite in Map.keys(roots) and &1.dependent in Map.keys(roots)))

    cond do
      root_edges != [] ->
        ordered_roots = topological_roots(Map.keys(roots), root_edges)
        {Enum.map(ordered_roots, &Map.fetch!(roots, &1)), :build_order_roots}

      Map.get(state, :settings) && state.settings.build_queue.set_order == "ranked" && map_size(roots) > 0 ->
        ordered = Enum.sort_by(queues, &{&1.set_rank, &1.queue_id})
        {Enum.map(ordered, & &1.name), :queue_rank}

      true ->
        {nil, :none}
    end
  end

  defp declared_order(_queues, _state), do: {nil, :none}

  defp topological_roots(roots, edges) do
    graph = Enum.group_by(edges, & &1.prerequisite, & &1.dependent)
    indegree = Map.new(roots, &{&1, 0})
    indegree = Enum.reduce(edges, indegree, fn edge, acc -> Map.update!(acc, edge.dependent, &(&1 + 1)) end)
    topo(roots, graph, indegree, [])
  end

  defp topo([], _graph, _indegree, ordered), do: Enum.reverse(ordered)

  defp topo(remaining, graph, indegree, ordered) do
    ready = remaining |> Enum.filter(&(indegree[&1] == 0)) |> Enum.sort()

    case ready do
      [] ->
        Enum.reverse(ordered) ++ Enum.sort(remaining)

      [next | _] ->
        remaining = List.delete(remaining, next)
        indegree = Enum.reduce(Map.get(graph, next, []), indegree, &Map.update!(&2, &1, fn value -> value - 1 end))
        topo(remaining, graph, Map.put(indegree, next, -1), [next | ordered])
    end
  end

  @doc "Returns cached-only blocker facts for queue members, with explicit misses."
  @spec cached_native_blockers(map(), map(), module() | nil, MapSet.t(String.t())) :: map()
  def cached_native_blockers(document, observations, tracker, terminal_states) do
    build_order_ids =
      for item <- document.items,
          queue = Enum.find(document.queues, &(&1.id == item.queue_id)),
          queue && queue.kind == :build_order,
          do: item.issue_id

    ids = document.items |> Enum.map(& &1.issue_id) |> Enum.uniq() |> Enum.reject(&(&1 in build_order_ids))

    Map.new(ids, &{&1, cached_blocker_result(&1, observations, tracker, terminal_states)})
    |> Map.reject(fn {_id, result} -> result == :skip end)
  end

  defp cached_blocker_result(id, observations, tracker, terminal_states) do
    issue = %Aiur.Issue{id: id, identifier: id, title: "", state: "todo"}

    case cached_blocker_fetch(issue, tracker) do
      {:ok, hydrated} -> {:ok, Enum.map(hydrated.blocked_by, &cached_blocker(&1, observations, terminal_states))}
      {:error, reason} when reason in [:cache_miss, :unsupported] -> :skip
      {:error, reason} -> {:unknown, reason}
      :skip -> :skip
    end
  end

  defp cached_blocker_fetch(issue, tracker) do
    if tracker && Code.ensure_loaded?(tracker) && function_exported?(tracker, :cached_blocked_by, 1),
      do: tracker.cached_blocked_by(issue),
      else: :skip
  end

  defp cached_blocker(%{identifier: number, state: state}, observations, terminal_states) do
    terminal? = is_binary(state) and MapSet.member?(terminal_states, String.downcase(String.trim(state)))
    open? = not match?(%{open?: false}, Map.get(observations, to_string(number))) and not terminal?

    %{number: String.to_integer(to_string(number)), state: state, open?: open?}
  end

  defp cached_blocker(%{identifier: number}, _observations, _terminal_states),
    do: %{number: String.to_integer(to_string(number)), state: nil, open?: true}

  defp cached_blocker(_blocker, _observations, _terminal_states), do: %{number: nil, state: nil, open?: true}

  defp build_order_blockers(document, observations) do
    document.edges
    |> Enum.filter(&(&1.source == :build_order))
    |> Enum.group_by(& &1.dependent)
    |> Map.new(fn {dependent, edges} ->
      blockers = Enum.map(edges, &%{number: String.to_integer(&1.prerequisite), open?: blocker_open?(&1.prerequisite, observations)})

      {dependent, {:ok, blockers}}
    end)
  end

  defp blocker_open?(id, observations), do: not match?(%{open?: false}, Map.get(observations, id))

  defp blocker_edges(blockers) do
    for {dependent, {:ok, prerequisites}} <- blockers,
        %{number: number, open?: true} <- prerequisites do
      %Edge{
        prerequisite: to_string(number),
        dependent: dependent,
        source: :native
      }
    end
  end

  @spec unavailable(atom()) :: map()
  def unavailable(status),
    do:
      build(%{
        status: status,
        clock: fn -> System.system_time(:millisecond) end,
        document: nil,
        projections: [],
        observations: %{}
      })

  @spec source(integer() | nil, integer(), pos_integer(), [term()]) :: map()
  def source(nil, _now, _max_age, reasons),
    do: %{
      state: :unavailable,
      observed_at: nil,
      age_ms: nil,
      freshness: :unknown,
      partial: true,
      reasons: reasons
    }

  def source(observed, now, max_age, reasons) do
    age = max(now - observed, 0)
    freshness = if age > max_age, do: :stale, else: :current

    %{
      state: :ok,
      observed_at: DateTime.from_unix!(observed, :millisecond),
      age_ms: age,
      freshness: freshness,
      partial: false,
      reasons: reasons
    }
  end

  defp tracker_source(context) do
    observed =
      context.observations
      |> Map.values()
      |> Enum.map(& &1.observed_at_ms)
      |> Enum.min(fn -> Map.get(context.state, :observed_at_ms) end)

    max_age =
      if Map.has_key?(context.state, :settings),
        do: Settings.observation_max_age_ms(context.state.settings),
        else: 1

    source(
      observed,
      context.now,
      max_age,
      if(is_nil(observed), do: [:observation_unavailable], else: [])
    )
  end

  defp queue(queue, context) do
    context =
      Map.put(context, :trigger, Settings.effective_trigger(queue, context.state.settings))

    members =
      Enum.filter(context.document.items, &(&1.queue_id == queue.id))
      |> Map.new(&{&1.issue_id, &1})

    items =
      for projection <- context.state.projections,
          Map.has_key?(members, projection.issue_id),
          do: item(members[projection.issue_id], projection, context)

    missing =
      for member <- Map.values(members),
          not Enum.any?(items, &(&1.number == String.to_integer(member.issue_id))),
          do: unknown_item(member, context)

    items = items ++ Enum.sort_by(missing, & &1.position)

    progress =
      if queue.kind == :build_order,
        do: context.build_orders[queue.root].progress,
        else:
          Progress.summary(
            items,
            Progress.available?() and not Map.get(context.state, :progress_unavailable, false)
          )

    %{
      queue_id: queue.id,
      set_rank: queue.rank,
      kind: queue.kind,
      root: queue.root,
      name: queue.name,
      start_trigger: context.trigger,
      start_trigger_override: queue.start_trigger,
      start_trigger_source: if(is_nil(queue.start_trigger), do: :config, else: :queue),
      held: queue.held,
      progress: progress,
      progress_reasons: Progress.reasons(queue, items, progress, context.build_orders[queue.root]),
      edges: context.summary_edges,
      items: items
    }
  end

  defp unknown_item(member, context),
    do: item(member, %{state: :unknown, verdict: {:unknown, [:not_reconciled]}, rank: nil}, context)

  defp item(member, projection, context) do
    projection = fresh_projection(projection, context)

    prerequisites = prerequisites(member.issue_id, context) ++ native_prerequisites(member.issue_id, context)
    {state, verdict, reason} = native_readiness(projection, prerequisites)

    %{
      number: String.to_integer(member.issue_id),
      position: member.position,
      state: state,
      reason: reason,
      verdict: verdict,
      prerequisites: prerequisites,
      downstream_open: if(projection.rank, do: -elem(projection.rank, 0)),
      rank: projection.rank,
      promoted_at: member.promoted_at,
      attention: attention(member.issue_id, context.document.latches)
    }
  end

  defp native_readiness(projection, prerequisites) do
    case Enum.find(prerequisites, &(&1.source == :github and &1.verdict in [:pending, :unknown])) do
      nil -> {projection.state, verdict(projection.verdict), Map.get(projection, :reason)}
      %{verdict: :unknown, description: description} -> {waiting_state(projection.state), :unknown, description}
      %{description: description} -> {waiting_state(projection.state), :waiting, description}
    end
  end

  defp waiting_state(:ready), do: :waiting
  defp waiting_state(state), do: state

  defp native_prerequisites(id, context) do
    case Map.get(Map.get(context.state, :native_blockers, %{}), id) do
      {:ok, blockers} ->
        Enum.map(blockers, fn blocker ->
          %{
            number: blocker.number,
            verdict: if(blocker.open?, do: :pending, else: :satisfied),
            source: :github,
            trigger: context.trigger,
            stage: nil,
            optimistic: false,
            description: "waiting on ##{blocker.number} (github)"
          }
        end)

      {:unknown, reason} ->
        [
          %{
            number: nil,
            verdict: :unknown,
            source: :github,
            trigger: context.trigger,
            stage: nil,
            optimistic: false,
            description: "GitHub dependencies unknown (#{reason})"
          }
        ]

      _ ->
        []
    end
  end

  defp fresh_projection(projection, context) do
    cond do
      context.tracker_source.freshness != :current ->
        %{
          projection
          | state: :unknown,
            verdict: {:unknown, [:observation_unavailable]},
            rank: nil
        }
        |> Map.put(:reason, :observation_unavailable)

      projection.state == :unknown ->
        %{projection | rank: nil}

      true ->
        projection
    end
  end

  defp prerequisites(id, context) do
    opts = [
      trigger: context.trigger,
      now_ms: context.now,
      max_age_ms: Settings.observation_max_age_ms(context.state.settings),
      label_prefix: context.state.settings.tracker.github.label_prefix
    ]

    for edge <- context.document.edges, edge.dependent == id do
      cyclic =
        match?({:unknown, _}, context.cycles) or MapSet.member?(context.cycles, edge.prerequisite)

      evidence =
        Readiness.evidence(context.observations[edge.prerequisite], opts[:label_prefix]) ||
          %Aiur.StartTrigger.Evidence{identifier: edge.prerequisite}

      result =
        Aiur.StartTrigger.edge_verdict(
          context.trigger,
          evidence,
          Keyword.put(opts, :cyclic, cyclic)
        )

      %{
        number: String.to_integer(edge.prerequisite),
        verdict: verdict(result),
        source: edge.source,
        trigger: context.trigger,
        stage: Aiur.StartTrigger.stage(evidence),
        optimistic: result == {:satisfied, :optimistic},
        description: Aiur.StartTrigger.describe(context.trigger, evidence, result)
      }
    end
  end

  defp verdict({kind, _causes}), do: kind
  defp verdict(kind), do: kind

  defp attention(id, latches) do
    case Enum.filter(latches, &(elem(&1.key, 1) == id)) do
      [] -> nil
      matches -> Enum.map(matches, &elem(&1.key, 0))
    end
  end
end
