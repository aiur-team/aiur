defmodule Aiur.BuildOrder.GitHubGraph.Result do
  @moduledoc false

  alias Aiur.BuildOrder.{
    Bounded,
    Catalog,
    Diagnostic,
    GitHubGraph.Dependencies,
    GitHubGraph.Endpoint,
    GitHubGraph.Normalizer,
    ProviderHealth,
    ProviderResult,
    RootSummary,
    SelectedRoot
  }

  alias Aiur.TrackerIdentity

  @spec catalog([map()], {String.t(), String.t()}, map()) :: Aiur.BuildOrder.GitHubGraph.result()
  def catalog(nodes, repository, state) do
    roots = Enum.map(nodes, &Normalizer.root(&1, repository))

    if duplicate_records?(roots) do
      duplicate_catalog(roots, state)
    else
      roots
      |> Catalog.new(healthy_provider())
      |> success(state)
    end
  end

  @spec selected(map(), [map()], {String.t(), String.t()}, map()) :: Aiur.BuildOrder.GitHubGraph.result()
  def selected(root_node, member_nodes, repository, state) do
    root = Normalizer.root(root_node, repository)
    members = member_nodes |> normalize_members(repository, root, root_node) |> Dependencies.validate_internal(root)
    selected = SelectedRoot.new(root, members, healthy_provider())

    cond do
      not RootSummary.valid?(root) ->
        failure(:structurally_invalid, state, candidate: selected)

      duplicate_candidate_identities?(root, members) ->
        duplicate_selected(selected, state)

      not SelectedRoot.structurally_valid?(selected) ->
        failure(:structurally_invalid, state, candidate: selected)

      true ->
        success(selected, state)
    end
  end

  @spec success(term(), map()) :: Aiur.BuildOrder.GitHubGraph.result()
  def success(candidate, state) do
    {:ok, ProviderResult.complete(candidate, calls: state.calls, pages: state.pages, rate_limit: state.rate_limit)}
  end

  @spec failure(atom(), map(), keyword()) :: Aiur.BuildOrder.GitHubGraph.result()
  def failure(reason, state, opts \\ []) do
    {:error,
     ProviderResult.failed(reason,
       calls: state.calls,
       pages: state.pages,
       rate_limit: state.rate_limit,
       candidate: Keyword.get(opts, :candidate),
       diagnostics: Keyword.get(opts, :diagnostics, diagnostics(reason))
     )}
  end

  defp diagnostics(reason)
       when reason in [
              :call_budget_exhausted,
              :catalog_overflow,
              :hierarchy_overflow,
              :member_overflow,
              :page_budget_exhausted,
              :pagination_mismatch
            ],
       do: [Diagnostic.new(reason)]

  defp diagnostics(:invalid_planning_bounds), do: [Diagnostic.new(:invalid_planning_bounds)]
  defp diagnostics(:invalid_requested_root), do: [Diagnostic.new(:invalid_requested_root)]

  defp diagnostics(reason) when reason in [:invalid_connection, :invalid_graphql_response, :invalid_root],
    do: [Diagnostic.new(:provider_schema)]

  defp diagnostics(reason) when reason in [:invalid_catalog, :structurally_invalid], do: []
  defp diagnostics(_reason), do: [Diagnostic.new(:provider_unavailable)]

  defp healthy_provider, do: ProviderHealth.new(1, :healthy, true)
  defp failed_provider, do: ProviderHealth.new(1, :unavailable, false)

  defp duplicate_catalog(roots, state) do
    catalog =
      roots
      |> Catalog.new(failed_provider())
      |> add_duplicate_diagnostic()

    failure(:duplicate_identity, state, candidate: catalog, diagnostics: [Diagnostic.new(:duplicate_identity)])
  end

  defp duplicate_selected(selected, state) do
    candidate = %{selected | provider: failed_provider()} |> add_duplicate_diagnostic()
    failure(:duplicate_identity, state, candidate: candidate, diagnostics: [Diagnostic.new(:duplicate_identity)])
  end

  defp add_duplicate_diagnostic(candidate) do
    %{candidate | diagnostics: [Diagnostic.new(:duplicate_identity) | candidate.diagnostics]}
  end

  defp duplicate_candidate_identities?(root, members), do: duplicate_records?([root | members])

  # A selected graph may include nested Epic containers. Normalize each member
  # against its actual fetched parent, not only the Build Order root, so the
  # native hierarchy remains visible while a missing or contradictory parent
  # still invalidates the candidate.
  defp normalize_members(nodes, repository, root, root_node) do
    parent_nodes = Map.new(nodes, fn node -> {node_key(node, repository), node} end)
    root_key = node_key(root_node, repository)

    members =
      Enum.map(nodes, fn node ->
        parent =
          case node_key(Map.get(node, "parent"), repository) do
            ^root_key ->
              root

            key ->
              case Map.get(parent_nodes, key) do
                nil -> RootSummary.new(%{})
                parent_node -> Normalizer.root(parent_node, repository)
              end
          end

        node
        |> Normalizer.member(repository, parent)
        |> validate_yielding_parent(node)
      end)

    parent_keys = Map.new(nodes, fn node -> {node_key(node, repository), node_key(Map.get(node, "parent"), repository)} end)
    Enum.map(members, &validate_ancestry(&1, root_key, parent_keys))
  end

  defp validate_yielding_parent(member, %{"__aiur_expected_parent_id" => expected_id, "parent" => %{"id" => expected_id}})
       when is_binary(expected_id),
       do: member

  defp validate_yielding_parent(member, %{"__aiur_expected_parent_id" => _expected_id}),
    do: %{member | diagnostics: member.diagnostics ++ [Diagnostic.new(:invalid_member)]}

  defp validate_yielding_parent(member, _node), do: member

  defp validate_ancestry(member, root_key, parent_keys) do
    if reaches_root?(Endpoint.key(member.identity), root_key, parent_keys, MapSet.new()) do
      member
    else
      %{member | diagnostics: member.diagnostics ++ [Diagnostic.new(:invalid_member)]}
    end
  end

  defp reaches_root?(key, root_key, _parents, _seen) when key == root_key, do: true
  defp reaches_root?(nil, _root_key, _parents, _seen), do: false

  defp reaches_root?(key, root_key, parents, seen) do
    if MapSet.member?(seen, key), do: false, else: reaches_root?(Map.get(parents, key), root_key, parents, MapSet.put(seen, key))
  end

  defp node_key(node, repository) do
    node
    |> Endpoint.node_identity(repository)
    |> elem(0)
    |> Endpoint.key()
  end

  defp duplicate_records?(records) do
    keys = Enum.flat_map(records, &record_keys/1)
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp record_keys(%{identity: %TrackerIdentity{} = identity, url: url}) do
    identity_keys(identity) ++ normalized_url_key(url)
  end

  defp record_keys(_record), do: []

  defp identity_keys(identity) do
    case Endpoint.key(identity) do
      {:github, owner, repository, provider_id} ->
        [{:provider_id, owner, repository, provider_id} | locator_keys(identity, owner, repository)]

      nil ->
        []
    end
  end

  defp locator_keys(%TrackerIdentity{database_id: database_id, identifier: identifier}, owner, repository) do
    database_key = if is_integer(database_id), do: [{:database_id, owner, repository, database_id}], else: []
    number_key = if is_binary(identifier), do: [{:issue_number, owner, repository, identifier}], else: []
    database_key ++ number_key
  end

  defp normalized_url_key(url) do
    case Bounded.github_issue_reference(url) do
      {:ok, %{owner: owner, repository: repository, kind: kind, identifier: identifier}} ->
        [{:url, String.downcase(owner), String.downcase(repository), String.downcase(kind), identifier}]

      :error ->
        []
    end
  end
end
