defmodule Aiur.BuildOrder.GitHubGraph.Normalizer do
  @moduledoc false

  alias Aiur.{BuildOrder.Diagnostic, BuildOrder.Lifecycle, BuildOrder.Member, BuildOrder.RootSummary}
  alias Aiur.BuildOrder.GitHubGraph.{Connection, Dependencies, Endpoint}

  @connection_limit 100
  @root_label "build-order"

  @spec root(map(), {String.t(), String.t()}) :: RootSummary.t()
  def root(node, repository) do
    {identity, identity_diagnostic} = Endpoint.node_identity(node, repository)
    {parent, parent_diagnostic} = Endpoint.parent_identity(node, repository)
    {labels, labels_diagnostic} = labels(node)
    {created_at, created_diagnostic} = timestamp(node, "createdAt")
    {updated_at, updated_diagnostic} = timestamp(node, "updatedAt")

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
    |> append_diagnostics([
      identity_diagnostic,
      parent_diagnostic,
      lifecycle_diagnostic(node),
      labels_diagnostic,
      created_diagnostic,
      updated_diagnostic
    ])
    |> validate_root_label()
  end

  @spec member(map(), {String.t(), String.t()}, RootSummary.t()) :: Member.t()
  def member(node, repository, root) do
    {identity, identity_diagnostic} = Endpoint.node_identity(node, repository)
    {parent, parent_diagnostic} = Endpoint.parent_identity(node, repository)
    {labels, labels_diagnostic} = labels(node)
    {created_at, created_diagnostic} = timestamp(node, "createdAt")
    {updated_at, updated_diagnostic} = timestamp(node, "updatedAt")

    {blocked_by, blocked_count, blocked_diagnostic} =
      Dependencies.from_node(node, "blockedBy", repository, identity, :blocked_by)

    {blocking, blocking_count, blocking_diagnostic} =
      Dependencies.from_node(node, "blocking", repository, identity, :blocking)

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
      Endpoint.direct_parent_diagnostic(parent, Map.get(node, "parent"), root),
      lifecycle_diagnostic(node),
      labels_diagnostic,
      created_diagnostic,
      updated_diagnostic,
      blocked_diagnostic,
      blocking_diagnostic
    ])
  end

  @spec labels(term()) :: {[String.t()], Diagnostic.t() | nil}
  def labels(node) do
    with {:ok, connection} <- Map.fetch(node, "labels"),
         {:ok, nodes, total, page_info} <- Connection.parse(connection) do
      cond do
        total > @connection_limit or page_info.has_next? -> {[], Diagnostic.new(:labels_overflow)}
        length(nodes) != total -> {[], Diagnostic.new(:incomplete_labels)}
        Enum.all?(nodes, &is_binary(Map.get(&1, "name"))) -> {Enum.map(nodes, &Map.fetch!(&1, "name")), nil}
        true -> {[], Diagnostic.new(:invalid_label_connection)}
      end
    else
      _ -> {[], Diagnostic.new(:invalid_label_connection)}
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

  defp lifecycle_diagnostic(node) do
    lifecycle = Lifecycle.from_github(Map.get(node, "state"), Map.get(node, "stateReason"))

    if Map.has_key?(node, "state") and Map.has_key?(node, "stateReason") and Lifecycle.valid?(lifecycle) do
      nil
    else
      Diagnostic.new(:invalid_lifecycle)
    end
  end

  defp validate_root_label(%{labels: labels} = root) do
    if @root_label in labels, do: root, else: append_diagnostics(root, [Diagnostic.new(:missing_root_label)])
  end

  defp append_diagnostics(%{diagnostics: diagnostics} = record, additions) do
    %{record | diagnostics: diagnostics ++ Enum.reject(additions, &is_nil/1)}
  end
end
