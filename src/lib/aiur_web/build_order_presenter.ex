defmodule AiurWeb.BuildOrderPresenter do
  @moduledoc """
  Pure join from one planning generation, one orchestrator snapshot, and one
  ticket-activity snapshot into the versioned Build Order view model.

  This module performs no I/O and never derives GitHub planning truth from
  Aiur execution progress. Joins require an exact `TrackerIdentity.github_key/1`.
  """
  alias Aiur.BuildOrder.{
    Diagnostic,
    GraphAnalysis,
    Icon,
    Member,
    ProviderHealth,
    Readiness,
    SelectedRoot
  }

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Node, Relationships}

  import AiurWeb.BuildOrderPresenter.Activity
  import AiurWeb.BuildOrderPresenter.Capabilities
  import AiurWeb.BuildOrderPresenter.Common
  import AiurWeb.BuildOrderPresenter.Edges
  import AiurWeb.BuildOrderPresenter.Summary

  @spec present(term(), term(), term(), keyword()) :: BuildOrderViewModel.t()
  def present(planning_snapshot, execution_snapshot, activity_snapshot, opts \\ []) do
    case planning(planning_snapshot) do
      {:ok, planning} ->
        render(planning, execution_snapshot, activity_snapshot, opts)

      {:error, health, status, diagnostics} ->
        %BuildOrderViewModel{
          status: status,
          planning_health: health,
          diagnostics: diagnostics,
          summary: empty_summary()
        }
    end
  end

  @doc "Builds the read-only relationship context for one exact member identity."
  @spec relationships(BuildOrderViewModel.t(), term(), term()) :: Relationships.t()
  def relationships(model, identity, capabilities \\ %{})

  def relationships(%BuildOrderViewModel{} = model, identity, capabilities) do
    case identity_key(identity) do
      nil ->
        %Relationships{status: :invalid_selection}

      key ->
        selected_relationships(model.nodes, model.edges, key, capabilities)
    end
  end

  def relationships(_model, _identity, _capabilities),
    do: %Relationships{status: :invalid_selection}

  defp planning(%Snapshot{data: %SelectedRoot{} = selected} = snapshot) do
    health = provider_health(snapshot.health)
    diagnostics = selected_diagnostics(selected, snapshot)

    status =
      if Enum.any?(diagnostics, &(&1.code == :invalid_root)),
        do: :structurally_invalid,
        else: selected_status(selected, health)

    {:ok,
     %{
       selected: selected,
       status: status,
       generation: snapshot.generation,
       health: health,
       repository: snapshot.repository,
       diagnostics: diagnostics
     }}
  end

  defp planning(%Snapshot{data: nil, health: health}) do
    health = provider_health(health)
    {:error, health, unavailable_status(health), [Diagnostic.new(:provider_unavailable)]}
  end

  defp planning(_snapshot) do
    health = %ProviderHealth{}
    {:error, health, :structurally_invalid, [Diagnostic.new(:invalid_root)]}
  end

  defp render(planning, execution_snapshot, activity_snapshot, opts) do
    {execution_index, execution_duplicates, execution_health} = execution_index(execution_snapshot)

    {activity_index, activity_duplicates, activity_health, activity_generation} =
      activity_index(activity_snapshot)

    joined_sources = %{
      execution_index: execution_index,
      execution_duplicates: execution_duplicates,
      execution_health: execution_health,
      activity_index: activity_index,
      activity_duplicates: activity_duplicates,
      activity_health: activity_health,
      activity_generation: activity_generation
    }

    member_index = member_index(planning.selected.members)
    edge_inputs = edge_inputs(planning.selected.members)
    native_edges = native_member_edges(edge_inputs, member_index)
    graph = GraphAnalysis.analyze(Map.keys(member_index), native_edges)
    edges = build_edges(edge_inputs, member_index, graph, edge_health(planning))

    nodes =
      planning.selected.members
      |> Enum.filter(&match?(%Member{}, &1))
      |> Enum.sort_by(&member_sort_key/1)
      |> Enum.map(&build_node(&1, edges, joined_sources, planning))

    lane_groups = groups(nodes, :lane)
    phase_groups = groups(nodes, :phase)
    diagnostics = model_diagnostics(planning.diagnostics, nodes, edges, execution_duplicates, activity_duplicates)

    model = %BuildOrderViewModel{
      status: planning.status,
      root: root_model(planning),
      nodes: nodes,
      edges: edges,
      lane_groups: lane_groups,
      phase_groups: phase_groups,
      adjacency: graph.adjacency,
      reverse_adjacency: graph.reverse_adjacency,
      strongly_connected_components: graph.strongly_connected_components,
      topological_order: graph.topological_order,
      summary: summary(nodes, edges, lane_groups, phase_groups, graph),
      planning_health: planning.health,
      execution_health: execution_health,
      activity_health: activity_health,
      generations: %{planning: planning.generation, activity: activity_generation},
      diagnostics: diagnostics,
      planning?: planning.selected.planning?
    }

    selection = Keyword.get(opts, :selected_identity)
    capabilities = Keyword.get(opts, :capabilities, %{})
    %{model | relationships: relationships(model, selection, capabilities)}
  end

  # Availability first: a graph the provider could not deliver cannot support a
  # structural claim about the operator's Build Order.
  defp selected_status(selected, health) do
    case SelectedRoot.availability(selected, health) do
      nil ->
        cond do
          not SelectedRoot.structurally_valid?(selected) -> :structurally_invalid
          selected.members == [] -> :empty
          true -> :ready
        end

      availability ->
        availability
    end
  end

  defp unavailable_status(%ProviderHealth{state: :stale}), do: :provider_stale
  defp unavailable_status(%ProviderHealth{state: :structurally_invalid}), do: :structurally_invalid
  defp unavailable_status(_health), do: :provider_unavailable

  defp edge_health(%{status: :structurally_invalid, generation: generation, health: health}) do
    ProviderHealth.new(generation, :structurally_invalid, false,
      observed_at: health.observed_at,
      last_success_at: health.last_success_at
    )
  end

  defp edge_health(planning), do: planning.health

  defp provider_health(%ProviderHealth{} = health), do: health
  defp provider_health(_health), do: %ProviderHealth{}

  defp selected_diagnostics(selected, snapshot) do
    scope_diagnostics =
      case snapshot.scope do
        {:selected, identity} ->
          if same_identity?(identity, selected.root.identity), do: [], else: [Diagnostic.new(:invalid_root)]

        _scope ->
          [Diagnostic.new(:invalid_root)]
      end

    repository_diagnostics =
      if repository_matches?(selected.root.identity, snapshot.repository),
        do: [],
        else: [Diagnostic.new(:invalid_root)]

    normalize_diagnostics(selected.diagnostics ++ selected.root.diagnostics ++ scope_diagnostics ++ repository_diagnostics)
  end

  defp repository_matches?(%TrackerIdentity{} = identity, {owner, repository}) do
    is_binary(owner) and is_binary(repository) and
      String.downcase(identity.owner || "") == String.downcase(owner) and
      String.downcase(identity.repository || "") == String.downcase(repository)
  end

  defp repository_matches?(_identity, _repository), do: false

  defp build_node(member, edges, joined_sources, planning) do
    execution_index = joined_sources.execution_index
    execution_duplicates = joined_sources.execution_duplicates
    execution_health = joined_sources.execution_health
    activity_index = joined_sources.activity_index
    activity_duplicates = joined_sources.activity_duplicates
    activity_health = joined_sources.activity_health
    activity_generation = joined_sources.activity_generation
    key = member_key(member)
    edge_states = edges |> Enum.filter(&(&1.target_key == key)) |> Enum.map(& &1.state)
    readiness = Readiness.from_edges(edge_states)
    execution = execution_for(key, execution_index, execution_duplicates)

    activity =
      key
      |> activity_for(activity_index, activity_duplicates)
      |> Map.put(:generation, activity_generation)

    lane_icon = Icon.lane(member.metadata.lane)
    status_icon = Icon.status(member.lifecycle, readiness, execution)
    diagnostics = node_diagnostics(member, key, execution_duplicates, activity_duplicates)

    plan = %{
      lifecycle: member.lifecycle,
      complexity: member.metadata.complexity,
      phase: member.metadata.phase,
      lane: member.metadata.lane,
      parent_identity: member.parent_identity,
      created_at: member.created_at,
      updated_at: member.updated_at
    }

    health = %{
      planning: planning.status,
      execution: node_source_health(key, execution_duplicates, execution_health, execution),
      activity: node_source_health(key, activity_duplicates, activity_health, activity)
    }

    observed_at = %{
      planning: member.updated_at || planning.health.observed_at,
      execution: Map.get(execution, :observed_at),
      activity: Map.get(activity, :observed_at)
    }

    provenance = %{
      planning_generation: planning.generation,
      activity_generation: Map.get(activity, :generation, :unknown),
      activity: Map.get(activity, :provenance, %{})
    }

    card =
      card(member, key, plan, execution, activity, readiness, lane_icon, status_icon)

    %Node{
      key: key,
      identity: member.identity,
      title: member.title,
      url: member.url,
      document_url: member.document_url,
      document_path: member.document_path,
      draft_body: member.draft_body,
      plan: plan,
      execution: execution,
      activity: Map.delete(activity, :generation),
      readiness: readiness,
      lane_icon: lane_icon,
      status_icon: status_icon,
      health: health,
      observed_at: observed_at,
      provenance: provenance,
      diagnostics: diagnostics,
      card: card
    }
  end

  defp card(member, key, plan, execution, activity, readiness, lane_icon, status_icon) do
    %{
      key: key,
      identifier: member_identifier(member.identity),
      title: member.title,
      url: member.url,
      lifecycle: member.lifecycle,
      readiness: readiness,
      execution_state: Map.get(execution, :work_state, :unknown),
      agent_stage: current_activity_stage(activity),
      progress: activity_progress(activity),
      progress_freshness: activity_progress_freshness(activity),
      progress_observed_at: activity_progress_observed_at(activity),
      lane: plan.lane,
      phase: plan.phase,
      lane_icon: lane_icon,
      status_icon: status_icon,
      status_text: status_icon.text,
      icon: member.icon,
      planned?: member.draft?
    }
  end

  defp node_diagnostics(member, key, execution_duplicates, activity_duplicates) do
    duplicate_diagnostics =
      if MapSet.member?(execution_duplicates, key) or MapSet.member?(activity_duplicates, key),
        do: [Diagnostic.new(:duplicate_identity)],
        else: []

    normalize_diagnostics(member.diagnostics ++ member.metadata.warnings ++ duplicate_diagnostics)
  end

  defp node_source_health(key, duplicates, global_health, source) do
    cond do
      global_health == :unavailable -> :unavailable
      MapSet.member?(duplicates, key) -> :ambiguous
      Map.get(source, :status) == :unknown -> :unknown
      true -> Map.get(source, :status)
    end
  end

  defp root_model(planning) do
    root = planning.selected.root

    %{
      key: identity_key(root.identity),
      identity: root.identity,
      title: root.title,
      url: root.url,
      lifecycle: root.lifecycle,
      health: planning.status,
      observed_at: root.updated_at || planning.health.observed_at,
      generation: planning.generation,
      diagnostics: normalize_diagnostics(root.diagnostics)
    }
  end

  defp selected_relationships(nodes, edges, key, capabilities) do
    case Enum.find(nodes, &(&1.key == key)) do
      nil ->
        %Relationships{status: :not_found}

      selected ->
        blocked_by = edges |> Enum.filter(&(&1.target_key == key)) |> Enum.sort_by(& &1.id)
        blocking = edges |> Enum.filter(&(&1.source_key == key)) |> Enum.sort_by(& &1.id)
        external = Enum.filter(blocked_by ++ blocking, &(&1.kind != :native))

        %Relationships{
          selected: selected,
          blocked_by: blocked_by,
          blocking: blocking,
          external: external,
          capabilities: normalize_capabilities(capabilities),
          diagnostics: relationship_diagnostics(selected, blocked_by, blocking),
          status: :selected
        }
    end
  end

  defp relationship_diagnostics(selected, blocked_by, blocking) do
    related = Enum.flat_map(blocked_by ++ blocking, & &1.diagnostics)
    normalize_diagnostics(selected.diagnostics ++ related)
  end

  defp model_diagnostics(planning, nodes, edges, execution_duplicates, activity_duplicates) do
    duplicate_count = MapSet.size(MapSet.union(execution_duplicates, activity_duplicates))
    duplicate_diagnostics = if duplicate_count > 0, do: [Diagnostic.new(:duplicate_identity)], else: []

    normalize_diagnostics(
      planning ++
        Enum.flat_map(nodes, & &1.diagnostics) ++
        Enum.flat_map(edges, & &1.diagnostics) ++ duplicate_diagnostics
    )
  end

  defp same_identity?(left, right) do
    left_key = identity_key(left)
    not is_nil(left_key) and left_key == identity_key(right)
  end

  defp member_identifier(%TrackerIdentity{identifier: identifier}) when is_binary(identifier),
    do: identifier

  defp member_identifier(_identity), do: "Unknown ticket"
end
