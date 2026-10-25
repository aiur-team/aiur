defmodule AiurWeb.BuildOrderPresenter.Summary do
  @moduledoc "Lane and wave groups and the selected-root summary counts."

  alias Aiur.BuildOrder.{GraphAnalysis, Metadata}
  alias AiurWeb.BuildOrderViewModel.{Edge, Group, Node}

  @doc false
  @spec groups([Node.t()], :lane | :phase) :: [Group.t()]
  def groups(nodes, :lane) do
    nodes
    |> Enum.group_by(& &1.plan.lane)
    |> Enum.map(fn {key, members} -> group(:lane, key, members) end)
    |> Enum.sort_by(&lane_group_sort_key/1)
  end

  def groups(nodes, :phase) do
    nodes
    |> Enum.group_by(& &1.plan.phase)
    |> Enum.map(fn {key, members} -> group(:phase, key, members) end)
    |> Enum.sort_by(&phase_group_sort_key/1)
  end

  defp group(dimension, key, nodes) do
    node_keys = nodes |> Enum.map(& &1.key) |> Enum.sort()

    %Group{
      dimension: dimension,
      key: key,
      label: group_label(dimension, key),
      node_keys: node_keys,
      count: length(node_keys)
    }
  end

  defp group_label(:lane, :unassigned), do: "Unassigned"
  defp group_label(:lane, lane), do: lane |> to_string() |> String.replace("-", " ") |> String.capitalize()
  defp group_label(:phase, :unphased), do: "Unphased"
  defp group_label(:phase, phase), do: "Wave #{phase}"

  defp lane_group_sort_key(%Group{key: :unassigned}), do: {1, 0}

  defp lane_group_sort_key(%Group{key: key}) do
    {0, Enum.find_index(Metadata.lanes(), &(&1 == key)) || length(Metadata.lanes())}
  end

  defp phase_group_sort_key(%Group{key: :unphased}), do: {1, 0}
  defp phase_group_sort_key(%Group{key: key}), do: {0, key}

  @doc false
  @spec summary([Node.t()], [Edge.t()], [Group.t()], [Group.t()], term()) :: map()
  def summary(nodes, edges, lane_groups, phase_groups, graph) do
    %{
      resolved?: true,
      members: length(nodes),
      edges: length(edges),
      external_edges: Enum.count(edges, &(&1.kind == :external)),
      readiness: frequencies(nodes, & &1.readiness),
      lifecycle: frequencies(nodes, &lifecycle_key/1),
      execution: frequencies(nodes, &Map.get(&1.execution, :work_state, :unknown)),
      lanes: Map.new(lane_groups, &{&1.key, &1.count}),
      phases: Map.new(phase_groups, &{&1.key, &1.count}),
      ready_at_start: length(GraphAnalysis.ready_at_start(graph)),
      longest_chain: GraphAnalysis.longest_chain_length(graph)
    }
  end

  @doc false
  @spec empty_summary() :: map()
  # No graph was resolved, so every count here is unknown rather than zero. The
  # `resolved?: false` flag is what stops the surface rendering `MEMBERS 0` for a
  # Build Order whose real membership was simply never fetched.
  def empty_summary do
    %{
      resolved?: false,
      members: 0,
      edges: 0,
      external_edges: 0,
      readiness: %{},
      lifecycle: %{},
      execution: %{},
      lanes: %{},
      phases: %{},
      ready_at_start: 0,
      longest_chain: 0
    }
  end

  defp frequencies(entries, mapper),
    do: Enum.frequencies_by(entries, mapper)

  defp lifecycle_key(%Node{plan: %{lifecycle: %{state: state, state_reason: reason}}}),
    do: {state, reason}
end
