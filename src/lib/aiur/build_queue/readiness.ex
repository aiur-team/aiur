defmodule Aiur.BuildQueue.Readiness do
  @moduledoc """
  Pure prerequisite verdicts and bounded cycle detection.

  `edge_verdict/2` requires `:now_ms`, `:max_age_ms`, and `:label_prefix`.
  Optional `:not_planned` defaults to `:fail` (or `:satisfy`); `:cyclic`
  overrides observation evidence. `:trigger` defaults to `:issue_closed`.

  `cyclic_items/1` returns cycle members, including self-loops. On more than
  1,000 distinct endpoints it returns `{:unknown, :graph_too_large}` instead
  of an incomplete set; callers must propagate that verdict to every item.
  """
  alias Aiur.BuildQueue.Model.{Edge, Observation}

  @type edge_verdict :: :satisfied | :pending | {:failed, atom()} | {:unknown, atom()}
  @type item_verdict :: :ready | :waiting | {:failed, [atom()]} | {:unknown, [atom()]}

  @spec edge_verdict(Observation.t() | nil, keyword()) :: edge_verdict()
  def edge_verdict(observation, opts) do
    result = Aiur.StartTrigger.edge_verdict(Keyword.get(opts, :trigger, :issue_closed), evidence(observation, Keyword.fetch!(opts, :label_prefix)), opts)

    case result do
      {:satisfied, _} -> :satisfied
      verdict -> verdict
    end
  end

  @spec evidence(Observation.t() | nil, String.t()) :: Aiur.StartTrigger.Evidence.t() | nil
  def evidence(nil, _prefix), do: nil

  def evidence(observation, prefix) do
    states = for label <- observation.labels, String.starts_with?(label, prefix <> ":"), do: String.replace_prefix(label, prefix <> ":", "")
    # An error must win over any competing lifecycle label.
    state = if "error" in states, do: "error", else: Enum.find(["done", "merging", "human-review", "rework", "ci-wait"], &(&1 in states))

    %Aiur.StartTrigger.Evidence{
      issue_open?: observation.open?,
      state_reason: observation.state_reason,
      state_label: state,
      pr: observation.pr,
      stage_reached: observation.stage_reached,
      observed_at_ms: observation.observed_at_ms,
      unavailable_reason: observation.unavailable_reason
    }
  end

  @spec item_verdict([edge_verdict()]) :: item_verdict()
  def item_verdict(verdicts) do
    unknown = causes(verdicts, :unknown)
    failed = causes(verdicts, :failed)

    cond do
      unknown != [] -> {:unknown, unknown}
      failed != [] -> {:failed, failed}
      :pending in verdicts -> :waiting
      true -> :ready
    end
  end

  @spec cyclic_items([Edge.t()]) :: MapSet.t(String.t()) | {:unknown, :graph_too_large}
  def cyclic_items(edges) do
    nodes = edges |> Enum.flat_map(&[&1.prerequisite, &1.dependent]) |> MapSet.new()

    if MapSet.size(nodes) > 1_000 do
      {:unknown, :graph_too_large}
    else
      graph = Enum.reduce(edges, Map.new(nodes, &{&1, []}), fn edge, graph -> Map.update!(graph, edge.prerequisite, &[edge.dependent | &1]) end)
      state = %{next: 0, index: %{}, low: %{}, active: MapSet.new(), stack: [], cyclic: MapSet.new()}
      Enum.reduce(nodes, state, &visit([{:enter, &1}], graph, &2)).cyclic
    end
  end

  defp causes(verdicts, kind), do: for({^kind, cause} <- verdicts, do: cause)

  # Explicit DFS frames keep traversal off the process call stack.
  defp visit([], _graph, state), do: state

  defp visit([{:enter, node} | rest], graph, state) do
    if Map.has_key?(state.index, node) do
      visit(rest, graph, state)
    else
      state = %{
        state
        | next: state.next + 1,
          index: Map.put(state.index, node, state.next),
          low: Map.put(state.low, node, state.next),
          active: MapSet.put(state.active, node),
          stack: [node | state.stack]
      }

      visit([{:neighbors, node, Map.fetch!(graph, node)} | rest], graph, state)
    end
  end

  defp visit([{:neighbors, node, []} | rest], graph, state), do: visit(rest, graph, complete(node, graph, state))

  defp visit([{:neighbors, node, [neighbor | tail]} | rest], graph, state) do
    frames = [{:neighbors, node, tail} | rest]

    cond do
      not Map.has_key?(state.index, neighbor) -> visit([{:enter, neighbor}, {:return, node, neighbor} | frames], graph, state)
      MapSet.member?(state.active, neighbor) -> visit(frames, graph, lower(state, node, Map.fetch!(state.index, neighbor)))
      true -> visit(frames, graph, state)
    end
  end

  defp visit([{:return, node, child} | rest], graph, state), do: visit(rest, graph, lower(state, node, Map.fetch!(state.low, child)))

  defp lower(state, node, value), do: %{state | low: Map.update!(state.low, node, &min(&1, value))}

  defp complete(node, graph, state) do
    if Map.fetch!(state.low, node) == Map.fetch!(state.index, node) do
      {component, stack} = pop(state.stack, node, [])
      cyclic = if length(component) > 1 or node in Map.fetch!(graph, node), do: MapSet.union(state.cyclic, MapSet.new(component)), else: state.cyclic
      %{state | stack: stack, active: MapSet.difference(state.active, MapSet.new(component)), cyclic: cyclic}
    else
      state
    end
  end

  defp pop([node | rest], node, component), do: {[node | component], rest}
  defp pop([head | rest], node, component), do: pop(rest, node, [head | component])
end
