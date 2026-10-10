defmodule AiurWeb.BuildOrderPresenter.Edges do
  @moduledoc "Dependency edge inputs, states and labels for the Build Order view model."

  import AiurWeb.BuildOrderPresenter.Common

  alias Aiur.Bounded
  alias Aiur.BuildOrder.{EdgeState, Member}
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderViewModel.Edge

  @doc false
  @spec member_index([term()]) :: map()
  def member_index(members) when is_list(members) do
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

  @doc false
  @spec edge_inputs([term()]) :: [map()]
  def edge_inputs(members) do
    members
    |> Enum.filter(&match?(%Member{}, &1))
    |> Enum.sort_by(&member_sort_key/1)
    |> Enum.flat_map(&member_edge_inputs/1)
    |> merge_duplicate_edges()
    |> Enum.sort_by(&edge_input_sort_key/1)
  end

  defp member_edge_inputs(%Member{} = member) do
    owner_key = identity_key(member.identity)

    member.dependencies
    |> Enum.with_index()
    |> Enum.map(fn {dependency, index} ->
      edge_input(dependency, owner_key, index)
    end)
  end

  defp edge_input(dependency, owner_key, index) do
    source = Map.get(dependency, :blocker_identity)
    target = Map.get(dependency, :blocked_identity)
    source_key = identity_key(source) || unresolved_key(owner_key, dependency, index, :source)
    target_key = identity_key(target) || unresolved_key(owner_key, dependency, index, :target)
    kind = edge_kind(Map.get(dependency, :kind))

    # A native edge whose endpoint falls outside this root's member set is a
    # cross-root reference, not a defect: it already renders neutrally (state
    # `:unknown`) as leaving the graph, so it contributes no diagnostic here.
    diagnostics =
      dependency
      |> Map.get(:diagnostics, [])
      |> List.wrap()
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

  @doc false
  @spec native_member_edges([map()], map()) :: [{term(), term()}]
  def native_member_edges(edges, member_index) do
    edges
    |> Enum.filter(&(&1.kind == :native and internal_edge?({&1.source_key, &1.target_key}, member_index)))
    |> Enum.map(&{&1.source_key, &1.target_key})
  end

  defp internal_edge?({source, target}, member_index),
    do: Map.has_key?(member_index, source) and Map.has_key?(member_index, target)

  @doc false
  @spec build_edges([map()], map(), term(), term()) :: [Edge.t()]
  def build_edges(inputs, member_index, graph, planning_health) do
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
      Map.get(Map.fetch!(member_index, input.source_key), :draft?) == true -> :unknown
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

  defp tracker_identity(%TrackerIdentity{} = identity), do: identity
  defp tracker_identity(_identity), do: nil

  defp key_text(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
end
