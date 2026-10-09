defmodule Aiur.BuildQueue.ReadModel do
  @moduledoc "Version 1 queue view from held reconciliation evidence; never performs tracker reads."
  alias Aiur.BuildQueue.{Progress, Readiness, Settings}
  alias Aiur.BuildQueue.Sources.{BuildOrder, ProjectionRead}

  @spec build(map()) :: map()
  def build(state) do
    now = state.clock.()
    document = state.document || %{queues: [], items: [], edges: [], latches: []}
    projection = Map.get(state, :build_order_projection, BuildOrder.projection())
    build_orders = Map.new(document.queues |> Enum.filter(&(&1.kind == :build_order)), &{&1.root, ProjectionRead.read(&1.root, now, projection)})
    context = %{cycles: Readiness.cyclic_items(document.edges), build_orders: build_orders, state: state, document: document, now: now, observations: Map.get(state, :observations, %{})}
    context = Map.put(context, :tracker_source, tracker_source(context))
    queues = Enum.map(document.queues, &queue(&1, context))
    sources = Map.new(document.queues |> Enum.filter(&(&1.kind == :build_order)), &{"build_order:#{&1.root}", build_orders[&1.root].source})

    %{
      schema_version: 1,
      page: "build-queue",
      instance: System.get_env("AIUR_INSTANCE_KEY"),
      snapshot: %{captured_at: DateTime.from_unix!(now, :millisecond)},
      status: state.status,
      build_queue: %{build_order_source: BuildOrder.available?(projection)},
      sources: Map.put(sources, "tracker_observation", context.tracker_source),
      queues: queues
    }
  end

  @spec unavailable(atom()) :: map()
  def unavailable(status), do: build(%{status: status, clock: fn -> System.system_time(:millisecond) end, document: nil, projections: [], observations: %{}})

  @spec source(integer() | nil, integer(), pos_integer(), [term()]) :: map()
  def source(nil, _now, _max_age, reasons), do: %{state: :unavailable, observed_at: nil, age_ms: nil, freshness: :unknown, partial: true, reasons: reasons}

  def source(observed, now, max_age, reasons) do
    age = max(now - observed, 0)
    freshness = if age > max_age, do: :stale, else: :current
    %{state: :ok, observed_at: DateTime.from_unix!(observed, :millisecond), age_ms: age, freshness: freshness, partial: false, reasons: reasons}
  end

  defp tracker_source(context) do
    observed = context.observations |> Map.values() |> Enum.map(& &1.observed_at_ms) |> Enum.min(fn -> Map.get(context.state, :observed_at_ms) end)
    max_age = if Map.has_key?(context.state, :settings), do: Settings.observation_max_age_ms(context.state.settings), else: 1
    source(observed, context.now, max_age, if(is_nil(observed), do: [:observation_unavailable], else: []))
  end

  defp queue(queue, context) do
    members = Enum.filter(context.document.items, &(&1.queue_id == queue.id)) |> Map.new(&{&1.issue_id, &1})
    items = for projection <- context.state.projections, Map.has_key?(members, projection.issue_id), do: item(members[projection.issue_id], projection, context)
    missing = for member <- Map.values(members), not Enum.any?(items, &(&1.number == String.to_integer(member.issue_id))), do: unknown_item(member, context)
    items = items ++ Enum.sort_by(missing, & &1.position)
    progress = if queue.kind == :build_order, do: context.build_orders[queue.root].progress, else: Progress.summary(items)
    %{queue_id: queue.id, kind: queue.kind, root: queue.root, name: queue.name, held: queue.held, progress: progress, items: items}
  end

  defp unknown_item(member, context), do: item(member, %{state: :unknown, verdict: {:unknown, [:not_reconciled]}, rank: nil}, context)

  defp item(member, projection, context) do
    projection = fresh_projection(projection, context)

    %{
      number: String.to_integer(member.issue_id),
      position: member.position,
      state: projection.state,
      reason: Map.get(projection, :reason),
      verdict: verdict(projection.verdict),
      prerequisites: prerequisites(member.issue_id, context),
      downstream_open: if(projection.rank, do: -elem(projection.rank, 0)),
      rank: projection.rank,
      promoted_at: member.promoted_at,
      attention: attention(member.issue_id, context.document.latches)
    }
  end

  defp fresh_projection(projection, context) do
    cond do
      context.tracker_source.freshness != :current -> %{projection | state: :unknown, verdict: {:unknown, [:observation_unavailable]}, rank: nil} |> Map.put(:reason, :observation_unavailable)
      projection.state == :unknown -> %{projection | rank: nil}
      true -> projection
    end
  end

  defp prerequisites(id, context) do
    opts = [now_ms: context.now, max_age_ms: Settings.observation_max_age_ms(context.state.settings), label_prefix: context.state.settings.tracker.github.label_prefix]

    for edge <- context.document.edges, edge.dependent == id do
      cyclic = match?({:unknown, _}, context.cycles) or MapSet.member?(context.cycles, edge.prerequisite)
      result = Readiness.edge_verdict(context.observations[edge.prerequisite], Keyword.put(opts, :cyclic, cyclic))
      %{number: String.to_integer(edge.prerequisite), verdict: verdict(result), source: edge.source}
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
