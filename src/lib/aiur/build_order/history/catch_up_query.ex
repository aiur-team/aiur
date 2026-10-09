defmodule Aiur.BuildOrder.History.CatchUpQuery do
  @moduledoc "Closed-issue catch-up query and repository-qualified history facts."
  alias Aiur.BuildOrder.History.{Feed, IssueNode, Row}

  @spec document() :: String.t()
  def document do
    """
    query HistoryCatchUp($owner:String!, $name:String!, $since:DateTime!, $after:String) {
      repository(owner:$owner, name:$name) {
        issues(first:100, after:$after, states:[CLOSED],
          filterBy:{since:$since}, orderBy:{field:UPDATED_AT, direction:ASC}) {
          pageInfo { hasNextPage endCursor }
          nodes { id number title state stateReason createdAt closedAt updatedAt
            labels(first:30) { totalCount nodes { name } }
            parent { number repository { name owner { login } } }
            blockedBy(first:100) { pageInfo { hasNextPage endCursor } nodes { number repository { name owner { login } } } } }
        }
      }
    }
    """
  end

  @spec node_to_event(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def node_to_event(node, opts) do
    now = Keyword.fetch!(opts, :observed_at)
    held = Keyword.get(opts, :held)

    with true <- node["state"] == "CLOSED",
         {:ok, issue} <- IssueNode.from_graphql(node) do
      fields = issue.fields
      labels = if fields.labels_complete, do: fields.labels, else: :truncated
      label_fields = Feed.label_fields(held, labels, fields.updated_at)
      fields = Map.drop(fields, [:labels, :labels_complete, :blocked_by_complete, :last_closed_at])
      fields = Map.merge(fields, label_fields)
      fields = if fields.closed_at == :none, do: %{fields | closed_at: :unknown}, else: fields
      lifecycle = fields.lifecycle
      fields = if lifecycle.state_reason == :none, do: %{fields | lifecycle: %{lifecycle | state_reason: :unknown}}, else: fields
      fields = Map.put(fields, :parent_version, DateTime.to_iso8601(now))
      fields = blocker_fields(fields, issue.fields.blocked_by_complete, now)
      Row.validate_event(%{number: issue.number, fields: fields, source: :catch_up, observed_at: now})
    else
      _other -> {:error, :invalid_catch_up_node}
    end
  end

  defp blocker_fields(fields, true, now), do: Map.put(fields, :blocked_by_version, DateTime.to_iso8601(now))
  defp blocker_fields(fields, false, _now), do: Map.delete(fields, :blocked_by)
end
