defmodule Aiur.BuildOrder.GitHubGraph.Dependencies do
  @moduledoc false

  alias Aiur.{BuildOrder.Dependency, BuildOrder.Diagnostic, BuildOrder.Member, TrackerIdentity}
  alias Aiur.BuildOrder.GitHubGraph.{Connection, Endpoint}

  @connection_limit 100

  @spec from_node(map(), String.t(), {String.t(), String.t()}, TrackerIdentity.t() | nil, atom()) ::
          {[Dependency.t()], non_neg_integer(), Diagnostic.t() | nil}
  def from_node(node, key, repository, configured_identity, direction) do
    connection = Map.get(node, key)
    total = Connection.total(connection)

    with {:ok, connection} <- Connection.value(connection),
         {:ok, nodes, total, page_info} <- Connection.parse(connection) do
      from_connection(nodes, total, page_info, repository, configured_identity, direction)
    else
      {:error, _reason} -> {[], total, Diagnostic.new(:connection_overflow)}
    end
  end

  @spec validate_internal([Member.t()], term()) :: [Member.t()]
  def validate_internal(members, root) do
    locators = canonical_locators(root, members)
    Enum.map(members, &validate_member(&1, locators))
  end

  defp from_connection(nodes, total, page_info, repository, configured_identity, direction)
       when total <= @connection_limit and not page_info.has_next? and length(nodes) == total do
    {dependencies, malformed?} =
      Enum.map_reduce(nodes, false, fn endpoint, malformed? ->
        {identity, identity_diagnostic} = Endpoint.endpoint_identity(endpoint, repository)

        dependency =
          Dependency.new(configured_identity, identity, Map.get(endpoint, "url"), direction)
          |> append_diagnostics([identity_diagnostic])

        {dependency, malformed? or invalid?(dependency, identity_diagnostic)}
      end)

    diagnostic =
      cond do
        malformed? -> Diagnostic.new(:invalid_dependency)
        duplicate?(dependencies) -> Diagnostic.new(:duplicate_identity)
        true -> nil
      end

    {dependencies, total, diagnostic}
  end

  defp from_connection(_nodes, total, _page_info, _repository, _configured_identity, _direction),
    do: {[], total, Diagnostic.new(:connection_overflow)}

  defp validate_member(%Member{} = member, locators) do
    {dependencies, diagnostics} =
      Enum.map_reduce(member.dependencies, [], fn dependency, diagnostics ->
        case status(dependency, locators) do
          :ok ->
            {dependency, diagnostics}

          :unresolved ->
            {dependency, [Diagnostic.new(:unresolved_internal_dependency) | diagnostics]}

          :contradictory ->
            dependency = append_diagnostics(dependency, [Diagnostic.new(:invalid_endpoint_locator)])
            {dependency, [Diagnostic.new(:invalid_endpoint_locator) | diagnostics]}
        end
      end)

    %{member | dependencies: dependencies}
    |> append_diagnostics(diagnostics |> Enum.reverse() |> Enum.uniq())
  end

  defp status(%Dependency{kind: :native, identity: identity, url: url}, locators) do
    case Map.fetch(locators, Endpoint.key(identity)) do
      {:ok, canonical} -> if(Endpoint.locator_matches?(identity, url, canonical), do: :ok, else: :contradictory)
      :error -> :unresolved
    end
  end

  defp status(_dependency, _locators), do: :ok

  defp canonical_locators(root, members) do
    [root | members]
    |> Enum.reduce(%{}, fn record, locators ->
      case Endpoint.key(record.identity) do
        nil -> locators
        key -> Map.put_new(locators, key, %{identity: record.identity, url: record.url})
      end
    end)
  end

  defp invalid?(%Dependency{kind: :native, diagnostics: diagnostics}, _diagnostic),
    do: Enum.any?(diagnostics, &(&1.code == :invalid_url))

  defp invalid?(%Dependency{kind: :external, identity: identity}, diagnostic),
    do: not is_nil(diagnostic) or not TrackerIdentity.joinable?(identity)

  defp invalid?(%Dependency{kind: :unknown}, _diagnostic), do: true
  defp invalid?(_dependency, _diagnostic), do: true

  defp duplicate?(dependencies) do
    keys =
      dependencies
      |> Enum.filter(&(&1.kind in [:native, :external]))
      |> Enum.map(&Endpoint.key(&1.identity))
      |> Enum.reject(&is_nil/1)

    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp append_diagnostics(%{diagnostics: diagnostics} = record, additions) do
    %{record | diagnostics: diagnostics ++ Enum.reject(additions, &is_nil/1)}
  end
end
