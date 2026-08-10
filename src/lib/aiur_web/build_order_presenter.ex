defmodule AiurWeb.BuildOrderPresenter do
  @moduledoc """
  Pure join from one planning generation, one orchestrator snapshot, and one
  ticket-activity snapshot into the versioned Build Order view model.

  This module performs no I/O and never derives GitHub planning truth from
  Aiur execution progress. Joins require an exact `TrackerIdentity.github_key/1`.
  """

  alias Aiur.BuildOrder.{
    Bounded,
    Diagnostic,
    EdgeState,
    GraphAnalysis,
    Icon,
    Member,
    Metadata,
    ProviderHealth,
    Readiness,
    SelectedRoot
  }

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.{OpaqueIdentifier, TrackerIdentity}
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Capability, Edge, Group, Node, Relationships}

  @capability_keys [:issue, :pull_request, :commands, :chat, :document]
  @safe_stages [:brainstorm, :plan, :work, :review]
  @safe_activity_statuses [:fresh, :stale]
  @safe_retention [:current, :recent]
  @safe_ci_decisions [:pass, :passed, :fail, :failed, :pending, :unknown]
  @safe_capability_reasons [
    :identity_mismatch,
    :inactive,
    :invalid_destination,
    :missing,
    :not_available,
    :not_configured,
    :not_opened,
    :stale,
    :unauthorized,
    :unavailable,
    :unreadable,
    :unsupported
  ]

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
    edge_inputs = edge_inputs(planning.selected.members, member_index)
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

  defp member_index(members) when is_list(members) do
    Enum.reduce(members, %{}, fn
      %Member{} = member, index ->
        case identity_key(member.identity) do
          nil -> index
          key -> Map.put_new(index, key, member)
        end

      _member, index ->
        index
    end)
  end

  defp edge_inputs(members, member_index) do
    members
    |> Enum.filter(&match?(%Member{}, &1))
    |> Enum.sort_by(&member_sort_key/1)
    |> Enum.flat_map(&member_edge_inputs(&1, member_index))
    |> merge_duplicate_edges()
    |> Enum.sort_by(&edge_input_sort_key/1)
  end

  defp member_edge_inputs(%Member{} = member, member_index) do
    owner_key = identity_key(member.identity)

    member.dependencies
    |> Enum.with_index()
    |> Enum.map(fn {dependency, index} ->
      edge_input(dependency, owner_key, index, member_index)
    end)
  end

  defp edge_input(dependency, owner_key, index, member_index) do
    source = Map.get(dependency, :blocker_identity)
    target = Map.get(dependency, :blocked_identity)
    source_key = identity_key(source) || unresolved_key(owner_key, dependency, index, :source)
    target_key = identity_key(target) || unresolved_key(owner_key, dependency, index, :target)
    kind = edge_kind(Map.get(dependency, :kind))
    missing_internal? = kind == :native and not internal_edge?({source_key, target_key}, member_index)

    diagnostics =
      dependency
      |> Map.get(:diagnostics, [])
      |> List.wrap()
      |> Kernel.++(if(missing_internal?, do: [Diagnostic.new(:unresolved_internal_dependency)], else: []))
      |> normalize_diagnostics()

    %{
      source: tracker_identity(source),
      target: tracker_identity(target),
      source_key: source_key,
      target_key: target_key,
      kind: kind,
      source_connection: source_connection(Map.get(dependency, :source_connection)),
      url: safe_dependency_url(dependency),
      diagnostics: diagnostics
    }
  end

  defp merge_duplicate_edges(edges) do
    edges
    |> Enum.group_by(&edge_dedup_key/1)
    |> Enum.map(fn {_key, grouped} ->
      first = Enum.min_by(grouped, & &1.source_connection)
      diagnostics = Enum.flat_map(grouped, & &1.diagnostics)
      %{first | diagnostics: normalize_diagnostics(diagnostics)}
    end)
  end

  defp edge_dedup_key(edge),
    do: {edge.kind, edge.source_key, edge.target_key}

  defp edge_input_sort_key(edge),
    do: {edge.source_key, edge.target_key, edge.kind, edge.source_connection}

  defp unresolved_key(owner_key, dependency, index, endpoint),
    do: {:unresolved, owner_key, source_connection(Map.get(dependency, :source_connection)), endpoint, index}

  defp safe_dependency_url(%{url: url}) do
    case Bounded.github_url(url) do
      {:ok, safe_url} -> safe_url
      :error -> nil
    end
  end

  defp safe_dependency_url(_dependency), do: nil

  defp edge_kind(kind) when kind in [:native, :external, :unknown], do: kind
  defp edge_kind(_kind), do: :unknown
  defp source_connection(value) when value in [:blocked_by, :blocking], do: value
  defp source_connection(_value), do: :blocked_by

  defp native_member_edges(edges, member_index) do
    edges
    |> Enum.filter(&(&1.kind == :native and internal_edge?({&1.source_key, &1.target_key}, member_index)))
    |> Enum.map(&{&1.source_key, &1.target_key})
  end

  defp internal_edge?({source, target}, member_index),
    do: Map.has_key?(member_index, source) and Map.has_key?(member_index, target)

  defp build_edges(inputs, member_index, graph, planning_health) do
    Enum.map(inputs, fn input ->
      state = edge_state(input, member_index, graph, planning_health)

      %Edge{
        id: edge_id(input),
        source: input.source,
        target: input.target,
        source_key: input.source_key,
        target_key: input.target_key,
        kind: input.kind,
        state: state,
        source_connection: input.source_connection,
        url: input.url,
        text: edge_text(input, member_index, state),
        diagnostics: input.diagnostics
      }
    end)
  end

  defp edge_state(input, member_index, graph, planning_health) do
    edge = {input.source_key, input.target_key}

    cond do
      input.kind != :native -> :unknown
      not internal_edge?(edge, member_index) -> :unknown
      MapSet.member?(graph.cyclic_edges, edge) -> EdgeState.cyclic()
      true -> member_index |> Map.fetch!(input.source_key) |> Map.fetch!(:lifecycle) |> EdgeState.classify(planning_health)
    end
  end

  defp edge_id(input) do
    "edge:" <> key_text(input.source_key) <> "->" <> key_text(input.target_key)
  end

  defp edge_text(input, member_index, state) do
    source = endpoint_label(input.source_key, input.source, member_index, "Unknown blocker")
    target = endpoint_label(input.target_key, input.target, member_index, "Unknown blocked ticket")
    source <> " blocks " <> target <> "; " <> edge_state_text(state)
  end

  defp endpoint_label(key, identity, member_index, fallback) do
    case Map.get(member_index, key) do
      %Member{title: title} -> title
      nil -> identity_label(identity, fallback)
    end
  end

  defp identity_label(%TrackerIdentity{owner: owner, repository: repository, identifier: identifier}, _fallback)
       when is_binary(owner) and is_binary(repository) and is_binary(identifier),
       do: owner <> "/" <> repository <> "#" <> identifier

  defp identity_label(_identity, fallback), do: fallback

  defp edge_state_text(:cleared), do: "dependency cleared."
  defp edge_state_text(:blocking), do: "dependency is blocking."
  defp edge_state_text(:terminal_unsatisfied), do: "dependency ended without completion."
  defp edge_state_text(:cyclic), do: "dependency is part of a cycle."
  defp edge_state_text(:unknown), do: "dependency status is unavailable."

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
      lane: plan.lane,
      phase: plan.phase,
      lane_icon: lane_icon,
      status_icon: status_icon,
      status_text: status_icon.text,
      icon: member.icon,
      planned?: member.draft?
    }
  end

  defp current_activity_stage(%{
         status: :fresh,
         stage: %{status: :known, freshness: :fresh, value: stage}
       })
       when stage in @safe_stages,
       do: stage

  defp current_activity_stage(_activity), do: :unknown

  defp activity_progress(%{
         status: :fresh,
         progress: %{status: :known, freshness: :fresh, percent: percent}
       })
       when percent in 0..100,
       do: percent

  defp activity_progress(_activity), do: :unknown

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

  defp execution_index(snapshot) when is_map(snapshot) do
    if Enum.all?([:running, :retrying, :idle], &is_list(Map.get(snapshot, &1))) do
      rows =
        Enum.flat_map([:running, :retrying, :idle], fn kind ->
          Enum.map(Map.fetch!(snapshot, kind), &{kind, &1})
        end)

      {index, duplicates} = exact_index(rows, &execution_identity/1)
      {index, duplicates, :available}
    else
      {%{}, MapSet.new(), :unavailable}
    end
  end

  defp execution_index(_snapshot), do: {%{}, MapSet.new(), :unavailable}

  defp execution_identity({_kind, row}) when is_map(row), do: Map.get(row, :tracker_identity)
  defp execution_identity(_row), do: nil

  defp execution_for(key, index, duplicates) do
    cond do
      MapSet.member?(duplicates, key) -> unknown_execution()
      match?({_, _}, Map.get(index, key)) -> index |> Map.fetch!(key) |> normalize_execution()
      true -> unknown_execution()
    end
  end

  defp normalize_execution({kind, row}) do
    %{
      status: :known,
      kind: kind,
      work_state: execution_work_state(kind, row),
      pause_reason: safe_atom(Map.get(row, :pause_reason)),
      waiting_reason: safe_atom(Map.get(row, :waiting_reason)),
      tracker_paused: boolean_or_unknown(Map.get(row, :tracker_paused)),
      runtime_seconds: non_negative_or_unknown(Map.get(row, :runtime_seconds)),
      ci_result: safe_ci_result(Map.get(row, :ci_result)),
      observed_at: execution_observed_at(row)
    }
  end

  defp execution_work_state(:running, row), do: safe_atom(Map.get(row, :work_state))
  defp execution_work_state(:retrying, _row), do: :retrying
  defp execution_work_state(:idle, _row), do: :idle

  defp execution_observed_at(row) do
    case Map.get(row, :last_codex_timestamp) || Map.get(row, :started_at) do
      %DateTime{} = datetime -> datetime
      _value -> nil
    end
  end

  defp safe_ci_result(%{decision: decision} = result) when decision in @safe_ci_decisions do
    %{
      status: :known,
      decision: decision,
      pr_number: positive_or_unknown(Map.get(result, :pr_number)),
      head_sha: OpaqueIdentifier.normalize(Map.get(result, :head_sha), 128)
    }
  end

  defp safe_ci_result(_result), do: %{status: :unknown}

  defp unknown_execution do
    %{
      status: :unknown,
      kind: :unknown,
      work_state: :unknown,
      pause_reason: :unknown,
      waiting_reason: :unknown,
      tracker_paused: :unknown,
      runtime_seconds: :unknown,
      ci_result: %{status: :unknown},
      observed_at: nil
    }
  end

  defp activity_index(%{entries: entries} = snapshot) when is_list(entries) do
    {index, duplicates} = exact_index(entries, &activity_identity/1)
    generation = positive_or_unknown(Map.get(snapshot, :generation))
    {index, duplicates, :available, generation}
  end

  defp activity_index(_snapshot), do: {%{}, MapSet.new(), :unavailable, :unknown}
  defp activity_identity(row) when is_map(row), do: Map.get(row, :identity)
  defp activity_identity(_row), do: nil

  defp activity_for(key, index, duplicates) do
    cond do
      MapSet.member?(duplicates, key) -> unknown_activity()
      is_map(Map.get(index, key)) -> index |> Map.fetch!(key) |> normalize_activity()
      true -> unknown_activity()
    end
  end

  defp normalize_activity(row) do
    %{
      status: activity_status(Map.get(row, :status)),
      active_stage: safe_stage(Map.get(row, :active_stage)),
      stage: safe_stage_snapshot(Map.get(row, :stage)),
      progress: safe_progress_snapshot(Map.get(row, :progress)),
      latest_evidence: safe_evidence(Map.get(row, :latest_evidence)),
      provenance: safe_provenance(Map.get(row, :provenance)),
      observed_at: datetime_or_nil(Map.get(row, :observed_at)),
      retention: safe_retention(Map.get(row, :retention)),
      generation: positive_or_unknown(Map.get(row, :generation))
    }
  end

  defp safe_progress_snapshot(%{status: :known, percent: percent} = progress)
       when is_integer(percent) and percent in 0..100 do
    %{
      status: :known,
      percent: percent,
      source: safe_progress_source(Map.get(progress, :source)),
      freshness: activity_status(Map.get(progress, :freshness)),
      occurred_at: datetime_or_nil(Map.get(progress, :occurred_at)),
      observed_at: datetime_or_nil(Map.get(progress, :observed_at)),
      event_id: positive_or_unknown(Map.get(progress, :event_id))
    }
  end

  defp safe_progress_snapshot(_progress), do: %{status: :unknown}

  defp safe_stage_snapshot(%{status: :known} = stage) do
    %{
      status: :known,
      value: safe_stage(Map.get(stage, :value)),
      freshness: activity_status(Map.get(stage, :freshness)),
      observed_at: datetime_or_nil(Map.get(stage, :observed_at)),
      event_id: positive_or_unknown(Map.get(stage, :event_id))
    }
  end

  defp safe_stage_snapshot(_stage), do: %{status: :unknown}

  defp safe_evidence(%{status: :known} = evidence) do
    %{
      status: :known,
      source: safe_evidence_source(Map.get(evidence, :source)),
      attributes: safe_activity_attributes(Map.get(evidence, :attributes)),
      provenance: safe_provenance(Map.get(evidence, :provenance)),
      occurred_at: datetime_or_nil(Map.get(evidence, :occurred_at)),
      observed_at: datetime_or_nil(Map.get(evidence, :observed_at)),
      event_id: positive_or_unknown(Map.get(evidence, :event_id))
    }
  end

  defp safe_evidence(_evidence), do: %{status: :unknown}

  defp safe_evidence_source(%{kind: kind, name: name})
       when kind in [:agent_event, :agent_alert, :legacy] and is_binary(name) and byte_size(name) <= 64,
       do: %{kind: kind, name: name}

  defp safe_evidence_source(_source), do: %{kind: :legacy, name: "unclassified"}

  defp safe_activity_attributes(attributes) when is_map(attributes) do
    attributes
    |> Map.take([:percent, :stage, :transition, :needs_attention, :severity])
    |> Enum.reduce(%{}, &safe_activity_attribute/2)
  end

  defp safe_activity_attributes(_attributes), do: %{}

  defp safe_activity_attribute({:percent, value}, attributes) when is_integer(value) and value in 0..100,
    do: Map.put(attributes, :percent, value)

  defp safe_activity_attribute({:stage, value}, attributes) when value in @safe_stages,
    do: Map.put(attributes, :stage, value)

  defp safe_activity_attribute({:transition, value}, attributes) when value in [:start, :end],
    do: Map.put(attributes, :transition, value)

  defp safe_activity_attribute({:needs_attention, value}, attributes) when is_boolean(value),
    do: Map.put(attributes, :needs_attention, value)

  defp safe_activity_attribute({:severity, value}, attributes) when value in ["info", "warning", "critical"],
    do: Map.put(attributes, :severity, value)

  defp safe_activity_attribute(_attribute, attributes), do: attributes

  defp safe_provenance(provenance) when is_map(provenance) do
    provenance
    |> Map.take([:run_id, :attempt, :session_id, :source_event_id])
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_integer(value) and value >= 0 -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(value) -> maybe_put_opaque(acc, key, value)
      _entry, acc -> acc
    end)
  end

  defp safe_provenance(_provenance), do: %{}

  defp maybe_put_opaque(acc, key, value) do
    case OpaqueIdentifier.normalize(value, 128) do
      nil -> acc
      safe -> Map.put(acc, key, safe)
    end
  end

  defp unknown_activity do
    %{
      status: :unknown,
      active_stage: :unknown,
      stage: %{status: :unknown},
      progress: %{status: :unknown},
      latest_evidence: %{status: :unknown},
      provenance: %{},
      observed_at: nil,
      retention: :unknown,
      generation: :unknown
    }
  end

  defp exact_index(rows, identity_fun) do
    Enum.reduce(rows, {%{}, MapSet.new()}, fn row, {index, duplicates} ->
      key = row |> identity_fun.() |> identity_key()

      cond do
        is_nil(key) -> {index, duplicates}
        Map.has_key?(index, key) -> {Map.delete(index, key), MapSet.put(duplicates, key)}
        MapSet.member?(duplicates, key) -> {index, duplicates}
        true -> {Map.put(index, key, row), duplicates}
      end
    end)
  end

  defp groups(nodes, :lane) do
    nodes
    |> Enum.group_by(& &1.plan.lane)
    |> Enum.map(fn {key, members} -> group(:lane, key, members) end)
    |> Enum.sort_by(&lane_group_sort_key/1)
  end

  defp groups(nodes, :phase) do
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

  defp summary(nodes, edges, lane_groups, phase_groups, graph) do
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

  # No graph was resolved, so every count here is unknown rather than zero. The
  # `resolved?: false` flag is what stops the surface rendering `MEMBERS 0` for a
  # Build Order whose real membership was simply never fetched.
  defp empty_summary do
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

  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    Map.new(@capability_keys, fn key -> {key, normalize_capability(key, Map.get(capabilities, key))} end)
  end

  defp normalize_capabilities(_capabilities), do: normalize_capabilities(%{})

  defp normalize_capability(key, capability) when key in @capability_keys and is_map(capability) do
    destination = Map.get(capability, :destination) || Map.get(capability, :url) || Map.get(capability, :path)
    identity = safe_capability_identity(Map.get(capability, :identity))
    number = safe_capability_number(Map.get(capability, :number))
    label = safe_label(Map.get(capability, :label))
    active? = optional_boolean(Map.get(capability, :active?))
    readable? = optional_boolean(Map.get(capability, :readable?))

    case {Map.get(capability, :available?) == true, is_struct(identity, TrackerIdentity), safe_destination(key, destination, identity, number)} do
      {true, false, _destination} ->
        unavailable_capability(:invalid_destination, identity, number, label, active?, readable?)

      {true, true, nil} ->
        unavailable_capability(:invalid_destination, identity, number, label, active?, readable?)

      {true, true, safe} ->
        %Capability{
          identity: identity,
          destination: safe,
          number: number,
          label: label,
          reason: nil,
          available?: true,
          active?: active?,
          readable?: readable?
        }

      {false, _identity?, _destination} ->
        unavailable_capability(safe_reason(Map.get(capability, :reason)), identity, number, label, active?, readable?)
    end
  end

  defp normalize_capability(_key, _capability), do: unavailable_capability(:unavailable)

  defp unavailable_capability(reason, identity \\ nil, number \\ nil, label \\ nil, active? \\ nil, readable? \\ nil) do
    %Capability{
      identity: identity,
      destination: nil,
      number: number,
      label: label,
      reason: reason,
      available?: false,
      active?: active?,
      readable?: readable?
    }
  end

  defp safe_destination(:issue, value, identity, _number), do: safe_destination_result(Bounded.github_issue_url_for(value, identity))
  defp safe_destination(:pull_request, value, identity, number), do: safe_destination_result(Bounded.github_pull_request_url_for(value, identity, number))
  defp safe_destination(:chat, value, identity, _number), do: safe_destination_result(Bounded.chat_route_for(value, identity))
  defp safe_destination(:commands, value, _identity, _number), do: safe_destination_result(Bounded.commands_route(value))
  # Planning-doc link (pre-ticket): any bounded https://github.com URL, including
  # a doc blob path that `github_url/1` (issue/PR-shaped) would reject.
  defp safe_destination(:document, value, _identity, _number), do: safe_document_destination(value)

  defp safe_destination_result({:ok, safe}), do: safe
  defp safe_destination_result(:error), do: nil

  defp safe_document_destination(value) when is_binary(value) and byte_size(value) in 1..512 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} = uri when host in ["github.com", "www.github.com"] ->
        URI.to_string(uri)

      _uri ->
        nil
    end
  end

  defp safe_document_destination(_value), do: nil

  defp safe_label(value) when is_binary(value) and byte_size(value) in 1..80 and value != "" do
    if String.valid?(value) and not String.match?(value, ~r/[\x00-\x1F\x7F]/), do: value
  end

  defp safe_label(_value), do: nil

  defp safe_capability_identity(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity), do: identity
  end

  defp safe_capability_identity(_identity), do: nil
  defp safe_capability_number(value) when is_integer(value) and value > 0, do: value
  defp safe_capability_number(_value), do: nil
  defp optional_boolean(value) when is_boolean(value), do: value
  defp optional_boolean(_value), do: nil
  defp safe_reason(value) when value in @safe_capability_reasons, do: value
  defp safe_reason(_value), do: :unavailable

  defp model_diagnostics(planning, nodes, edges, execution_duplicates, activity_duplicates) do
    duplicate_count = MapSet.size(MapSet.union(execution_duplicates, activity_duplicates))
    duplicate_diagnostics = if duplicate_count > 0, do: [Diagnostic.new(:duplicate_identity)], else: []

    normalize_diagnostics(
      planning ++
        Enum.flat_map(nodes, & &1.diagnostics) ++
        Enum.flat_map(edges, & &1.diagnostics) ++ duplicate_diagnostics
    )
  end

  defp normalize_diagnostics(diagnostics) do
    diagnostics
    |> Enum.filter(&match?(%Diagnostic{}, &1))
    |> Enum.uniq_by(& &1.code)
    |> Enum.sort_by(& &1.code)
  end

  defp same_identity?(left, right) do
    left_key = identity_key(left)
    not is_nil(left_key) and left_key == identity_key(right)
  end

  defp identity_key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)
  defp identity_key(_identity), do: nil
  defp tracker_identity(%TrackerIdentity{} = identity), do: identity
  defp tracker_identity(_identity), do: nil

  defp key_text(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  defp member_sort_key(%Member{} = member), do: member_key(member)

  defp member_key(%Member{identity: identity, title: title, url: url}),
    do: identity_key(identity) || {:invalid_member, title, url}

  defp member_identifier(%TrackerIdentity{identifier: identifier}) when is_binary(identifier),
    do: identifier

  defp member_identifier(_identity), do: "Unknown ticket"

  defp safe_atom(value) when is_atom(value) and not is_nil(value), do: value
  defp safe_atom(_value), do: :unknown
  defp boolean_or_unknown(value) when is_boolean(value), do: value
  defp boolean_or_unknown(_value), do: :unknown
  defp non_negative_or_unknown(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_or_unknown(_value), do: :unknown
  defp positive_or_unknown(value) when is_integer(value) and value > 0, do: value
  defp positive_or_unknown(_value), do: :unknown
  defp datetime_or_nil(%DateTime{} = value), do: value
  defp datetime_or_nil(_value), do: nil
  defp activity_status(value) when value in @safe_activity_statuses, do: value
  defp activity_status(_value), do: :unknown
  defp safe_stage(value) when value in @safe_stages, do: value
  defp safe_stage(_value), do: :unknown
  defp safe_progress_source(value) when value in [:checkin, :phase], do: value
  defp safe_progress_source(_value), do: :unknown
  defp safe_retention(value) when value in @safe_retention, do: value
  defp safe_retention(_value), do: :unknown
end
