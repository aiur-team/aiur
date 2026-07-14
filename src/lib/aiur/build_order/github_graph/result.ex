defmodule Aiur.BuildOrder.GitHubGraph.Result do
  @moduledoc false

  alias Aiur.BuildOrder.{
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

  @spec catalog([map()], {String.t(), String.t()}, map()) :: Aiur.BuildOrder.GitHubGraph.result()
  def catalog(nodes, repository, state) do
    roots = Enum.map(nodes, &Normalizer.root(&1, repository))
    catalog = Catalog.new(roots, ProviderHealth.new(1, :healthy, true))

    if Enum.any?(roots, &duplicate_root?(&1, roots)) do
      failure(:invalid_catalog, state, candidate: catalog, diagnostics: [Diagnostic.new(:duplicate_identity)])
    else
      success(catalog, state)
    end
  end

  @spec selected(map(), [map()], {String.t(), String.t()}, map()) :: Aiur.BuildOrder.GitHubGraph.result()
  def selected(root_node, member_nodes, repository, state) do
    root = Normalizer.root(root_node, repository)
    members = member_nodes |> Enum.map(&Normalizer.member(&1, repository, root)) |> Dependencies.validate_internal(root)
    selected = SelectedRoot.new(root, members, ProviderHealth.new(1, :healthy, true))

    cond do
      not RootSummary.valid?(root) ->
        failure(:structurally_invalid, state, candidate: selected)

      duplicate_candidate_identities?(root, members) ->
        failure(:duplicate_identity, state,
          candidate: selected,
          diagnostics: [Diagnostic.new(:duplicate_identity)]
        )

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

  defp duplicate_root?(root, roots), do: Enum.count(roots, &Endpoint.same?(&1.identity, root.identity)) > 1

  defp duplicate_candidate_identities?(root, members) do
    keys = [root.identity | Enum.map(members, & &1.identity)] |> Enum.map(&Endpoint.key/1) |> Enum.reject(&is_nil/1)
    length(keys) != MapSet.size(MapSet.new(keys))
  end
end
