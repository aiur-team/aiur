defmodule Aiur.BuildOrder.GitHubGraph do
  @moduledoc "Bounded, body-free GitHub reads for Build Order planning candidates."

  alias Aiur.BuildOrder.{
    Catalog,
    Dependency,
    Diagnostic,
    Lifecycle,
    Member,
    ProviderHealth,
    ProviderResult,
    RootSummary,
    SelectedRoot
  }

  alias Aiur.{GitHub, TrackerIdentity}
  alias Aiur.GitHub.{Errors, Transport}

  @root_label "build-order"
  @member_limit 100
  @connection_limit 100
  @max_page_budget 4
  @max_call_budget 4

  defmodule Paging do
    @moduledoc false

    defstruct [
      :repository,
      :token,
      :limits,
      :limit,
      :root_number,
      :requested_root,
      :root,
      root_fingerprint: nil,
      expected_total: nil,
      cursor: nil,
      seen_cursors: MapSet.new(),
      nodes: []
    ]
  end

  @catalog_query """
  query AiurBuildOrderCatalog($owner: String!, $repo: String!, $cursor: String, $pageSize: Int!) {
    repository(owner: $owner, name: $repo) {
      issues(first: $pageSize, after: $cursor, labels: ["#{@root_label}"]) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          id databaseId number title url state stateReason createdAt updatedAt
          repository { name owner { login } }
          parent { id databaseId number url repository { name owner { login } } }
          labels(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { name } }
        }
      }
    }
  }
  """

  @selected_root_query """
  query AiurBuildOrderSelectedRoot($owner: String!, $repo: String!, $number: Int!, $cursor: String, $pageSize: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        id databaseId number title url state stateReason createdAt updatedAt
        repository { name owner { login } }
        parent { id databaseId number url repository { name owner { login } } }
        labels(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { name } }
        subIssues(first: $pageSize, after: $cursor) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes {
            id databaseId number title url state stateReason createdAt updatedAt
            repository { name owner { login } }
            parent { id databaseId number url repository { name owner { login } } }
            labels(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { name } }
            blockedBy(first: 100) {
              totalCount
              pageInfo { hasNextPage endCursor }
              nodes { id databaseId number url repository { name owner { login } } }
            }
            blocking(first: 100) {
              totalCount
              pageInfo { hasNextPage endCursor }
              nodes { id databaseId number url repository { name owner { login } } }
            }
          }
        }
      }
    }
  }
  """

  @type result :: {:ok, ProviderResult.t()} | {:error, ProviderResult.t()}

  @spec fetch_catalog(keyword()) :: result()
  def fetch_catalog(opts \\ []) do
    with {:ok, repository} <- configured_repository(opts),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, limits} <- limits(opts) do
      state = initial_state(opts)

      paging = new_paging(repository, token, limits, limits.root_limit)

      case catalog_pages(paging, state) do
        {:ok, nodes, state} -> catalog_result(nodes, repository, state)
        {:error, reason, state} -> failure(reason, state)
      end
    else
      {:error, reason} -> failure(reason, initial_state(opts))
    end
  end

  @spec fetch_selected_root(TrackerIdentity.t(), keyword()) :: result()
  def fetch_selected_root(root, opts \\ []) do
    with {:ok, repository} <- configured_repository(opts),
         {:ok, requested_root} <- requested_root(root, repository),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, limits} <- limits(opts) do
      state = initial_state(opts)

      paging = new_paging(repository, token, limits, @member_limit, requested_root)

      case selected_pages(paging, state) do
        {:ok, root_node, member_nodes, state} -> selected_result(root_node, member_nodes, repository, state)
        {:error, reason, state} -> failure(reason, state)
      end
    else
      {:error, reason} -> failure(reason, initial_state(opts))
    end
  end

  defp catalog_pages(paging, state) do
    case request_catalog_page(paging, state) do
      {:ok, body, next_state} -> catalog_response(body, paging, next_state)
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp catalog_response(body, paging, state) do
    with {:ok, connection} <- catalog_connection(body),
         {:ok, nodes, total, page_info} <- connection(connection) do
      catalog_page_result(advance_page(paging, nodes, total, page_info, state))
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp selected_pages(paging, state) do
    case request_selected_page(paging, state) do
      {:ok, body, next_state} -> selected_response(body, paging, next_state)
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp selected_response(body, paging, state) do
    with {:ok, fetched_root, connection} <- selected_connection(body),
         {:ok, paging} <- selected_root_page(paging, fetched_root),
         {:ok, nodes, total, page_info} <- connection(connection) do
      selected_page_result(advance_page(paging, nodes, total, page_info, state), paging.root)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp catalog_page_result({:next, paging, state}), do: catalog_pages(paging, state)
  defp catalog_page_result({:ok, nodes, state}), do: {:ok, nodes, state}
  defp catalog_page_result({:error, reason, state}), do: {:error, reason, state}

  defp selected_page_result({:next, paging, state}, _root), do: selected_pages(paging, state)
  defp selected_page_result({:ok, nodes, state}, root), do: {:ok, root, nodes, state}
  defp selected_page_result({:error, reason, state}, _root), do: {:error, reason, state}

  defp advance_page(paging, nodes, total, page_info, state) do
    case remember_total(paging, total) do
      {:ok, paging} ->
        paging = %{paging | nodes: paging.nodes ++ nodes}

        case page_status(paging, total, page_info, state) do
          :overflow -> {:error, overflow_code(paging), state}
          :page_budget_exhausted -> {:error, :page_budget_exhausted, state}
          :complete -> {:ok, paging.nodes, state}
          :next -> advance_cursor(paging, page_info, state)
          :pagination_mismatch -> {:error, :pagination_mismatch, state}
        end

      :error ->
        {:error, :pagination_mismatch, state}
    end
  end

  defp remember_total(%Paging{expected_total: nil} = paging, total),
    do: {:ok, %{paging | expected_total: total}}

  defp remember_total(%Paging{expected_total: total} = paging, total), do: {:ok, paging}
  defp remember_total(%Paging{}, _total), do: :error

  defp page_status(paging, total, page_info, state) do
    cond do
      page_overflow?(paging, total, page_info) -> :overflow
      page_info.has_next? and state.pages >= paging.limits.page_budget -> :page_budget_exhausted
      page_info.has_next? -> :next
      length(paging.nodes) == total -> :complete
      true -> :pagination_mismatch
    end
  end

  defp page_overflow?(paging, total, page_info) do
    total > paging.limit or
      length(paging.nodes) > paging.limit or
      (page_info.has_next? and length(paging.nodes) >= paging.limit)
  end

  defp advance_cursor(paging, page_info, state) do
    case next_cursor(page_info, paging.seen_cursors) do
      {:ok, cursor} ->
        next_paging = %{
          paging
          | cursor: cursor,
            seen_cursors: MapSet.put(paging.seen_cursors, cursor)
        }

        {:next, next_paging, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp overflow_code(%Paging{root_number: nil}), do: :catalog_overflow
  defp overflow_code(%Paging{}), do: :member_overflow

  defp request_catalog_page(paging, state) do
    variables = catalog_variables(paging.repository, paging.cursor, paging.limits)
    request_page(state, paging.token, @catalog_query, variables)
  end

  defp request_selected_page(paging, state) do
    variables = selected_variables(paging.repository, paging.root_number, paging.cursor, paging.limits)
    request_page(state, paging.token, @selected_root_query, variables)
  end

  defp catalog_result(nodes, repository, state) do
    roots = Enum.map(nodes, &(root_summary(&1, repository) |> validate_root_label()))
    catalog = Catalog.new(roots, ProviderHealth.new(1, :healthy, true))

    if Enum.any?(roots, &duplicate_root?(&1, roots)) do
      failure(:invalid_catalog, state, candidate: catalog, diagnostics: [Diagnostic.new(:duplicate_identity)])
    else
      success(catalog, state)
    end
  end

  defp selected_result(root_node, member_nodes, repository, state) do
    root = root_node |> root_summary(repository) |> validate_root_label()
    members = Enum.map(member_nodes, &member(&1, repository, root.identity))
    members = validate_internal_dependencies(members, root.identity)
    selected = SelectedRoot.new(root, members, ProviderHealth.new(1, :healthy, true))

    cond do
      not RootSummary.valid?(root) ->
        failure(:structurally_invalid, state, candidate: selected)

      duplicate_members?(members) ->
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

  defp root_summary(node, repository) do
    {identity, identity_diagnostic} = node_identity(node, repository)
    {parent, parent_diagnostic} = parent_identity(node, repository)
    {labels, labels_diagnostic} = labels(node)
    {created_at, created_diagnostic} = timestamp(node, "createdAt")
    {updated_at, updated_diagnostic} = timestamp(node, "updatedAt")

    summary =
      RootSummary.new(%{
        identity: identity,
        title: Map.get(node, "title"),
        url: Map.get(node, "url"),
        parent_identity: parent,
        state: Map.get(node, "state"),
        state_reason: Map.get(node, "stateReason"),
        labels: labels,
        created_at: created_at,
        updated_at: updated_at
      })

    append_diagnostics(summary, [
      identity_diagnostic,
      parent_diagnostic,
      lifecycle_diagnostic(node),
      labels_diagnostic,
      created_diagnostic,
      updated_diagnostic
    ])
  end

  defp member(node, repository, root_identity) do
    {identity, identity_diagnostic} = node_identity(node, repository)
    {parent, parent_diagnostic} = parent_identity(node, repository)
    {labels, labels_diagnostic} = labels(node)
    {created_at, created_diagnostic} = timestamp(node, "createdAt")
    {updated_at, updated_diagnostic} = timestamp(node, "updatedAt")
    {blocked_by, blocked_count, blocked_diagnostic} = dependencies(node, "blockedBy", repository, identity, :blocked_by)
    {blocking, blocking_count, blocking_diagnostic} = dependencies(node, "blocking", repository, identity, :blocking)

    Member.new(%{
      identity: identity,
      title: Map.get(node, "title"),
      url: Map.get(node, "url"),
      state: Map.get(node, "state"),
      state_reason: Map.get(node, "stateReason"),
      labels: labels,
      parent_identity: parent,
      created_at: created_at,
      updated_at: updated_at,
      connection_counts: %{blocked_by: blocked_count, blocking: blocking_count},
      dependencies: blocked_by ++ blocking
    })
    |> append_diagnostics([
      identity_diagnostic,
      parent_diagnostic,
      direct_parent_diagnostic(parent, root_identity),
      lifecycle_diagnostic(node),
      labels_diagnostic,
      created_diagnostic,
      updated_diagnostic,
      blocked_diagnostic,
      blocking_diagnostic
    ])
  end

  defp dependencies(node, key, repository, configured_identity, direction) do
    connection = Map.get(node, key)
    total = connection_total(connection)

    with {:ok, connection} <- connection_value(connection),
         {:ok, nodes, total, page_info} <- connection(connection) do
      dependencies_from_connection(nodes, total, page_info, repository, configured_identity, direction)
    else
      {:error, _reason} -> {[], total, Diagnostic.new(:connection_overflow)}
    end
  end

  defp dependencies_from_connection(nodes, total, page_info, repository, configured_identity, direction)
       when total <= @connection_limit and not page_info.has_next? and length(nodes) == total do
    {dependencies, malformed_endpoint?} =
      Enum.map_reduce(nodes, false, fn endpoint, malformed? ->
        {identity, _diagnostic} = endpoint_identity(endpoint, repository)
        dependency = Dependency.new(configured_identity, identity, Map.get(endpoint, "url"), direction)
        {dependency, malformed? or invalid_native_dependency?(dependency) or dependency.kind == :unknown}
      end)

    diagnostic =
      cond do
        malformed_endpoint? -> Diagnostic.new(:invalid_dependency)
        duplicate_native_dependencies?(dependencies) -> Diagnostic.new(:duplicate_identity)
        true -> nil
      end

    {dependencies, total, diagnostic}
  end

  defp dependencies_from_connection(_nodes, total, _page_info, _repository, _configured_identity, _direction),
    do: {[], total, Diagnostic.new(:connection_overflow)}

  defp invalid_native_dependency?(%Dependency{kind: :native, diagnostics: diagnostics}) do
    Enum.any?(diagnostics, &(&1.code == :invalid_url))
  end

  defp invalid_native_dependency?(_dependency), do: false

  defp validate_internal_dependencies(members, root_identity) do
    identities =
      members
      |> Enum.map(&identity_key(&1.identity))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    identities =
      if TrackerIdentity.joinable?(root_identity) do
        MapSet.put(identities, identity_key(root_identity))
      else
        identities
      end

    Enum.map(members, fn member ->
      if Enum.any?(member.dependencies, &unresolved_internal?(&1, identities)) do
        append_diagnostics(member, [Diagnostic.new(:unresolved_internal_dependency)])
      else
        member
      end
    end)
  end

  defp unresolved_internal?(%Dependency{kind: :native, identity: identity}, identities),
    do: not MapSet.member?(identities, identity_key(identity))

  defp unresolved_internal?(_dependency, _identities), do: false

  defp node_identity(node, repository) do
    case endpoint_identity(node, repository) do
      {nil, diagnostic} ->
        {nil, diagnostic}

      {%TrackerIdentity{} = identity, diagnostic} ->
        if same_repository?(identity, repository),
          do: {identity, diagnostic},
          else: {nil, Diagnostic.new(:invalid_identity)}
    end
  end

  defp endpoint_identity(node, fallback_repository) when is_map(node) do
    with {:ok, {owner, name}} <- repository_from_node(node, fallback_repository),
         {:ok, identity} <-
           TrackerIdentity.from_github(
             %{
               "node_id" => Map.get(node, "id"),
               "database_id" => Map.get(node, "databaseId"),
               "number" => Map.get(node, "number"),
               "repository" => Map.get(node, "repository")
             },
             {owner, name},
             {owner, name}
           ) do
      {identity, nil}
    else
      _ -> {nil, Diagnostic.new(:invalid_identity)}
    end
  end

  defp endpoint_identity(_node, _fallback_repository), do: {nil, Diagnostic.new(:invalid_identity)}

  defp parent_identity(node, repository) do
    case Map.get(node, "parent") do
      nil -> {nil, nil}
      parent -> endpoint_identity(parent, repository)
    end
  end

  defp repository_from_node(%{"repository" => %{"name" => repository, "owner" => %{"login" => owner}}}, _fallback)
       when is_binary(owner) and is_binary(repository),
       do: {:ok, {owner, repository}}

  defp repository_from_node(_node, _fallback), do: {:error, :missing_repository_identity}

  defp labels(node) do
    with {:ok, connection} <- Map.fetch(node, "labels"),
         {:ok, nodes, total, page_info} <- connection(connection),
         true <- total <= @connection_limit and not page_info.has_next? and length(nodes) == total,
         true <- Enum.all?(nodes, &is_binary(Map.get(&1, "name"))) do
      {Enum.map(nodes, &Map.fetch!(&1, "name")), nil}
    else
      _ -> {[], Diagnostic.new(:invalid_dependency)}
    end
  end

  defp timestamp(node, key) do
    case Map.get(node, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {datetime, nil}
          _ -> {nil, Diagnostic.new(:invalid_member)}
        end

      _ ->
        {nil, Diagnostic.new(:invalid_member)}
    end
  end

  defp direct_parent_diagnostic(parent, root) do
    if same_identity?(parent, root), do: nil, else: Diagnostic.new(:invalid_member)
  end

  defp append_diagnostics(%{diagnostics: existing_diagnostics} = record, additions) do
    additions = Enum.reject(additions, &is_nil/1)
    %{record | diagnostics: existing_diagnostics ++ additions}
  end

  defp validate_root_label(%{labels: labels} = root) do
    if @root_label in labels,
      do: root,
      else: append_diagnostics(root, [Diagnostic.new(:missing_root_label)])
  end

  defp lifecycle_diagnostic(node) do
    lifecycle = Lifecycle.from_github(Map.get(node, "state"), Map.get(node, "stateReason"))

    if Map.has_key?(node, "state") and Map.has_key?(node, "stateReason") and Lifecycle.valid?(lifecycle),
      do: nil,
      else: Diagnostic.new(:invalid_lifecycle)
  end

  defp duplicate_root?(root, roots), do: Enum.count(roots, &same_identity?(&1.identity, root.identity)) > 1

  defp duplicate_members?(members) do
    identity_keys = Enum.map(members, &identity_key(&1.identity))
    Enum.any?(identity_keys, &is_nil/1) or length(identity_keys) != MapSet.size(MapSet.new(identity_keys))
  end

  defp same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right) do
    case {identity_key(left), identity_key(right)} do
      {{:github, _, _, _} = left_key, {:github, _, _, _} = right_key} -> left_key == right_key
      _ -> false
    end
  end

  defp same_identity?(_left, _right), do: false

  defp identity_key(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity) do
      {:github, String.downcase(identity.owner), String.downcase(identity.repository), identity.provider_id}
    end
  end

  defp identity_key(_identity), do: nil

  defp duplicate_native_dependencies?(dependencies) do
    keys =
      dependencies
      |> Enum.filter(&(&1.kind == :native))
      |> Enum.map(&identity_key(&1.identity))

    Enum.any?(keys, &is_nil/1) or length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp selected_root_page(%Paging{root: nil, requested_root: requested_root} = paging, fetched_root) do
    if requested_root?(fetched_root, requested_root, paging.repository) do
      {:ok, %{paging | root: fetched_root, root_fingerprint: root_fingerprint(fetched_root)}}
    else
      {:error, :invalid_root}
    end
  end

  defp selected_root_page(%Paging{} = paging, fetched_root) do
    if requested_root?(fetched_root, paging.requested_root, paging.repository) and
         root_fingerprint(fetched_root) == paging.root_fingerprint do
      {:ok, paging}
    else
      {:error, :pagination_mismatch}
    end
  end

  defp requested_root?(fetched_root, requested_root, repository) do
    case node_identity(fetched_root, repository) do
      {%TrackerIdentity{} = fetched_identity, nil} -> same_requested_root?(fetched_identity, requested_root)
      _ -> false
    end
  end

  defp same_requested_root?(%TrackerIdentity{} = fetched, %TrackerIdentity{} = requested) do
    same_identity?(fetched, requested) and fetched.identifier == requested.identifier
  end

  defp same_requested_root?(_fetched, _requested), do: false

  defp root_fingerprint(root) when is_map(root), do: Map.drop(root, ["subIssues"])
  defp root_fingerprint(_root), do: nil

  defp catalog_connection(body), do: get_in(body, ["data", "repository", "issues"]) |> connection_value()

  defp selected_connection(body) do
    case get_in(body, ["data", "repository", "issue"]) do
      %{} = root ->
        case Map.get(root, "subIssues") do
          %{} = connection -> {:ok, root, connection}
          _ -> {:error, :invalid_connection}
        end

      _ ->
        {:error, :invalid_root}
    end
  end

  defp connection_value(%{} = connection), do: {:ok, connection}
  defp connection_value(_connection), do: {:error, :invalid_connection}

  defp connection(%{"nodes" => nodes, "totalCount" => total, "pageInfo" => page_info})
       when is_list(nodes) and is_integer(total) and total >= 0 and is_map(page_info) do
    with has_next when is_boolean(has_next) <- Map.get(page_info, "hasNextPage"),
         end_cursor <- Map.get(page_info, "endCursor"),
         true <- is_nil(end_cursor) or is_binary(end_cursor) do
      {:ok, nodes, total, %{has_next?: has_next, end_cursor: end_cursor}}
    else
      _ -> {:error, :invalid_connection}
    end
  end

  defp connection(_connection), do: {:error, :invalid_connection}

  defp connection_total(%{"totalCount" => total}) when is_integer(total) and total >= 0, do: total
  defp connection_total(_connection), do: 0

  defp next_cursor(%{end_cursor: cursor}, seen_cursors) when is_binary(cursor) and byte_size(cursor) > 0 do
    if MapSet.member?(seen_cursors, cursor), do: {:error, :pagination_mismatch}, else: {:ok, cursor}
  end

  defp next_cursor(_page_info, _seen_cursors), do: {:error, :pagination_mismatch}

  defp request_page(%{pages: pages, calls: _calls} = state, _token, _query, _variables)
       when pages >= state.page_budget,
       do: {:error, :page_budget_exhausted, state}

  defp request_page(%{calls: calls} = state, _token, _query, _variables) when calls >= state.call_budget,
    do: {:error, :call_budget_exhausted, state}

  defp request_page(state, token, query, variables) do
    state = %{state | calls: state.calls + 1}

    case Transport.github_graphql_response(state.request_fun, token, query, variables) do
      {:ok, body, response} -> {:ok, body, observe(state, response)}
      {:error, reason, response} -> {:error, reason, observe_failure(state, response)}
    end
  end

  defp observe(state, response) do
    %{state | pages: state.pages + 1, rate_limit: observed_rate_limit(state, response)}
  end

  defp observe_failure(state, response), do: %{state | rate_limit: observed_rate_limit(state, response)}

  defp observed_rate_limit(state, response),
    do: Map.merge(state.rate_limit, Errors.rate_limit_observation(response))

  defp success(candidate, state),
    do: {:ok, ProviderResult.complete(candidate, calls: state.calls, pages: state.pages, rate_limit: state.rate_limit)}

  defp failure(reason, state, opts \\ []) do
    {:error,
     ProviderResult.failed(reason,
       calls: state.calls,
       pages: state.pages,
       rate_limit: state.rate_limit,
       candidate: Keyword.get(opts, :candidate),
       diagnostics: Keyword.get(opts, :diagnostics, failure_diagnostics(reason))
     )}
  end

  defp failure_diagnostics(reason)
       when reason in [
              :call_budget_exhausted,
              :catalog_overflow,
              :member_overflow,
              :page_budget_exhausted,
              :pagination_mismatch
            ],
       do: [Diagnostic.new(reason)]

  defp failure_diagnostics(:invalid_planning_bounds), do: [Diagnostic.new(:invalid_planning_bounds)]

  defp failure_diagnostics(reason) when reason in [:invalid_connection, :invalid_root],
    do: [Diagnostic.new(:provider_schema)]

  defp failure_diagnostics(reason) when reason in [:invalid_catalog, :structurally_invalid], do: []
  defp failure_diagnostics(_reason), do: [Diagnostic.new(:provider_unavailable)]

  defp new_paging(repository, token, limits, limit, requested_root \\ nil) do
    %Paging{
      repository: repository,
      token: token,
      limits: limits,
      limit: limit,
      root_number: requested_root_number(requested_root),
      requested_root: requested_root
    }
  end

  defp initial_state(opts) do
    %{
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      calls: 0,
      pages: 0,
      rate_limit: %{},
      page_budget: option_or_config(opts, :page_budget, &GitHub.Config.planning_page_budget/0),
      call_budget: option_or_config(opts, :call_budget, &GitHub.Config.planning_call_budget/0)
    }
  end

  defp configured_repository(opts) do
    case Keyword.get(opts, :repository) do
      {owner, repository} when is_binary(owner) and is_binary(repository) and owner != "" and repository != "" ->
        {:ok, {owner, repository}}

      nil ->
        GitHub.Config.configured_repo()

      _ ->
        {:error, :invalid_github_repo}
    end
  end

  defp limits(opts) do
    limits = %{
      root_limit: option_or_config(opts, :root_limit, &GitHub.Config.planning_root_limit/0),
      page_budget: option_or_config(opts, :page_budget, &GitHub.Config.planning_page_budget/0),
      call_budget: option_or_config(opts, :call_budget, &GitHub.Config.planning_call_budget/0)
    }

    if valid_limits?(limits) do
      {:ok, Map.put(limits, :page_size, page_size(limits, @member_limit))}
    else
      {:error, :invalid_planning_bounds}
    end
  end

  defp valid_limits?(%{root_limit: roots, page_budget: pages, call_budget: calls}) do
    is_integer(roots) and roots in 1..@member_limit and
      is_integer(pages) and pages in 1..@max_page_budget and
      is_integer(calls) and calls in 1..@max_call_budget
  end

  defp page_size(limits, limit) do
    slots = min(limits.page_budget, limits.call_budget)
    max(1, div(limit + slots - 1, slots))
  end

  defp catalog_variables({owner, repository}, cursor, limits) do
    %{"owner" => owner, "repo" => repository, "pageSize" => page_size(limits, limits.root_limit)}
    |> Transport.maybe_put_query("cursor", cursor)
  end

  defp selected_variables({owner, repository}, number, cursor, limits) do
    %{"owner" => owner, "repo" => repository, "number" => number, "pageSize" => limits.page_size}
    |> Transport.maybe_put_query("cursor", cursor)
  end

  defp requested_root(%TrackerIdentity{} = root, repository) do
    with true <- TrackerIdentity.joinable?(root),
         true <- same_repository?(root, repository),
         {:ok, _number} <- positive_number(root.identifier) do
      {:ok, root}
    else
      _ -> {:error, :invalid_root}
    end
  end

  defp requested_root(_root, _repository), do: {:error, :invalid_root}

  defp requested_root_number(%TrackerIdentity{} = root) do
    case positive_number(root.identifier) do
      {:ok, number} -> number
      {:error, _reason} -> nil
    end
  end

  defp requested_root_number(_root), do: nil

  defp positive_number(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_root}
    end
  end

  defp positive_number(_value), do: {:error, :invalid_root}

  defp same_repository?(
         %TrackerIdentity{owner: owner, repository: repository},
         {expected_owner, expected_repository}
       ) do
    String.downcase(owner) == String.downcase(expected_owner) and
      String.downcase(repository) == String.downcase(expected_repository)
  end

  defp same_repository?(_root, _repository), do: false

  defp option_or_config(opts, key, config_fun) do
    if Keyword.has_key?(opts, key), do: Keyword.fetch!(opts, key), else: config_fun.()
  end
end
