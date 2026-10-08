defmodule Aiur.BuildOrder.History.CatchUpQuery do
  @moduledoc "Closed-issue catch-up query and repository-qualified history facts."
  alias Aiur.BuildOrder.History.Feed

  @spec document() :: String.t()
  def document do
    """
    query HistoryCatchUp($owner:String!, $name:String!, $since:DateTime!, $after:String) {
      repository(owner:$owner, name:$name) {
        issues(first:100, after:$after, states:[CLOSED],
          filterBy:{since:$since}, orderBy:{field:UPDATED_AT, direction:ASC}) {
          pageInfo { hasNextPage endCursor }
          nodes { id number title state stateReason createdAt closedAt updatedAt
            labels(first:30) { pageInfo { hasNextPage } nodes { name } }
            parent { number }
            blockedBy(first:100) { pageInfo { hasNextPage } nodes { number } } }
        }
      }
    }
    """
  end

  @spec node_to_event(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def node_to_event(node, opts) do
    repo = Keyword.fetch!(opts, :repository)
    now = Keyword.fetch!(opts, :observed_at)
    held = Keyword.get(opts, :held)

    with n when not is_nil(n) <- Feed.number(node["number"]),
         %DateTime{} <- Feed.date(node["updatedAt"]),
         true <- node["state"] == "CLOSED",
         {:ok, labels} <- connection(node["labels"], "name"),
         {:ok, blockers} <- connection(node["blockedBy"], "number"),
         {:ok, parent} <- parent(node["parent"], repo) do
      body = %{
        "number" => n,
        "title" => node["title"],
        "state" => node["state"],
        "state_reason" => node["stateReason"],
        "created_at" => node["createdAt"],
        "closed_at" => node["closedAt"],
        "updated_at" => node["updatedAt"],
        "labels" => labels
      }

      [event] = Feed.issue(held, body, now, :catch_up)
      fields = Map.merge(event.fields, %{node_id: node["id"], parent: parent, parent_version: DateTime.to_iso8601(now)})
      fields = if blockers == :truncated, do: fields, else: Map.merge(fields, %{blocked_by: Enum.map(blockers, &Feed.ref(repo, &1)), blocked_by_version: DateTime.to_iso8601(now)})
      event = %{event | fields: fields}
      Aiur.BuildOrder.History.Row.validate_event(event)
    else
      _other -> {:error, :invalid_catch_up_node}
    end
  end

  defp connection(%{"pageInfo" => %{"hasNextPage" => true}}, _key), do: {:ok, :truncated}

  defp connection(%{"pageInfo" => %{"hasNextPage" => false}, "nodes" => nodes}, key) when is_list(nodes) do
    values = Enum.map(nodes, fn node -> if is_map(node), do: Map.get(node, key), else: nil end)
    valid? = if key == "name", do: Enum.all?(values, &is_binary/1), else: Enum.all?(values, &(is_integer(&1) and &1 > 0))
    if valid?, do: {:ok, values}, else: {:error, :invalid_connection}
  end

  defp connection(_value, _key), do: {:error, :invalid_connection}
  defp parent(nil, _repo), do: {:ok, :none}
  defp parent(%{"number" => n}, repo) when is_integer(n) and n > 0, do: {:ok, Feed.ref(repo, n)}
  defp parent(_parent, _repo), do: {:error, :invalid_parent}
end
