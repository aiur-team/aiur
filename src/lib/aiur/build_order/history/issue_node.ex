defmodule Aiur.BuildOrder.History.IssueNode do
  @moduledoc "Issue-level GraphQL facts shared by history readers."
  alias Aiur.BuildOrder.Lifecycle

  @spec from_graphql(term()) :: {:ok, map()} | {:error, :invalid_issue_node}
  def from_graphql(%{"number" => number} = node) when is_integer(number) and number > 0 do
    with {:ok, created} <- datetime(node["createdAt"]),
         {:ok, updated} <- datetime(node["updatedAt"]),
         {:ok, closed} <- nullable_datetime(node["closedAt"]),
         {:ok, labels, labels_complete} <- labels(node["labels"]),
         {:ok, parent} <- reference(node["parent"]),
         {:ok, blockers, info} <- blockers(node["blockedBy"]) do
      fields = %{
        node_id: node["id"],
        title: node["title"],
        lifecycle: Lifecycle.from_github(node["state"], node["stateReason"]),
        created_at: created,
        updated_at: updated,
        closed_at: closed,
        labels: labels,
        labels_complete: labels_complete,
        parent: parent,
        blocked_by: blockers,
        blocked_by_complete: not info["hasNextPage"]
      }

      fields = if closed == :none, do: fields, else: Map.put(fields, :last_closed_at, closed)
      {:ok, %{number: number, fields: fields}}
    else
      _error -> {:error, :invalid_issue_node}
    end
  end

  def from_graphql(_node), do: {:error, :invalid_issue_node}

  @spec datetime(term()) :: {:ok, DateTime.t()} | {:error, :invalid_datetime}
  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _error -> {:error, :invalid_datetime}
    end
  end

  def datetime(_value), do: {:error, :invalid_datetime}
  defp nullable_datetime(nil), do: {:ok, :none}
  defp nullable_datetime(value), do: datetime(value)

  @spec reference(term()) :: {:ok, map() | :none} | {:error, :invalid_reference}
  def reference(nil), do: {:ok, :none}

  def reference(%{"number" => number, "repository" => %{"name" => repo, "owner" => %{"login" => owner}}})
      when is_integer(number) and number > 0 and is_binary(repo) and repo != "" and is_binary(owner) and owner != "",
      do: {:ok, %{owner: owner, repository: repo, number: number}}

  def reference(_value), do: {:error, :invalid_reference}

  @spec blockers(term()) :: {:ok, [map()], map()} | {:error, :invalid_blockers}
  def blockers(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => next} = info}) when is_list(nodes) and is_boolean(next) do
    with true <- not next or (is_binary(info["endCursor"]) and info["endCursor"] != ""), {:ok, refs} <- references(nodes), do: {:ok, refs, info}, else: (_error -> {:error, :invalid_blockers})
  end

  def blockers(_value), do: {:error, :invalid_blockers}

  defp references(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, refs} ->
      case reference(node) do
        {:ok, %{} = ref} -> {:cont, {:ok, refs ++ [ref]}}
        _error -> {:halt, {:error, :invalid_reference}}
      end
    end)
  end

  defp labels(%{"nodes" => nodes, "totalCount" => count}) when is_list(nodes) and is_integer(count) and count >= 0 do
    names = Enum.map(nodes, fn node -> if is_map(node), do: node["name"] end)
    if Enum.all?(names, &is_binary/1), do: {:ok, names, count == length(nodes)}, else: {:error, :invalid_labels}
  end

  defp labels(_value), do: {:error, :invalid_labels}
end
