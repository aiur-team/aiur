defmodule Aiur.BuildOrder.History.BackfillQuery do
  @moduledoc "One repository walk, with timeline facts and explicit connection completeness."
  alias Aiur.BuildOrder.History.{IssueNode, Row, Timing}

  @spec query() :: String.t()
  def query do
    """
    query AiurBuildOrderHistoryBackfill($owner: String!, $repo: String!, $cursor: String) {
      rateLimit { limit cost remaining resetAt }
      repository(owner: $owner, name: $repo) {
        issues(first: 100, after: $cursor, orderBy: {field: CREATED_AT, direction: ASC}) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes {
            id number title state stateReason createdAt updatedAt closedAt
            parent { number repository { name owner { login } } }
            labels(first: 100) { totalCount nodes { name } }
            blockedBy(first: 100) { totalCount pageInfo { hasNextPage endCursor }
              nodes { number repository { name owner { login } } } }
            timelineItems(first: 100, itemTypes: [LABELED_EVENT, UNLABELED_EVENT,
              CONNECTED_EVENT, CLOSED_EVENT, SUB_ISSUE_ADDED_EVENT]) {
              pageInfo { hasNextPage }
              nodes {
                __typename
                ... on LabeledEvent { createdAt actor { login } label { name } }
                ... on UnlabeledEvent { createdAt actor { login } label { name } }
                ... on ConnectedEvent { createdAt subject { ... on PullRequest { number mergedAt } } }
                ... on ClosedEvent { createdAt closer { ... on PullRequest { number mergedAt } } }
                ... on SubIssueAddedEvent { createdAt subIssue { number repository { name owner { login } } } }
              }
            }
          }
        }
      }
    }
    """
  end

  @spec blocked_by_query() :: String.t()
  def blocked_by_query do
    """
    query AiurBuildOrderHistoryBackfillBlockedBy($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
      rateLimit { limit cost remaining resetAt }
      repository(owner: $owner, name: $repo) {
        issue(number: $number) {
          blockedBy(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor }
            nodes { number repository { name owner { login } } } }
        }
      }
    }
    """
  end

  @spec variables(String.t(), String.t(), String.t() | nil) :: map()
  def variables(owner, repo, cursor), do: %{"owner" => owner, "repo" => repo, "cursor" => cursor}

  @spec blocked_by_events(term()) :: {:ok, [map()], map()} | {:error, :invalid_backfill_page}
  def blocked_by_events(%{"data" => %{"repository" => %{"issue" => %{"blockedBy" => connection}}}}) do
    case IssueNode.blockers(connection) do
      {:ok, refs, info} -> {:ok, refs, info}
      _error -> {:error, :invalid_backfill_page}
    end
  end

  def blocked_by_events(_body), do: {:error, :invalid_backfill_page}

  @spec events(term(), map(), String.t(), DateTime.t()) :: {:ok, [Row.event()], map()} | {:error, :invalid_backfill_page}
  def events(%{"data" => %{"repository" => %{"issues" => %{"nodes" => nodes, "totalCount" => total, "pageInfo" => %{"hasNextPage" => next} = info}}}}, _repo, prefix, observed)
      when is_list(nodes) and is_integer(total) and total >= 0 and is_boolean(next) do
    with true <- not next or (is_binary(info["endCursor"]) and info["endCursor"] != ""),
         {:ok, events} <- normalize_nodes(nodes, prefix, observed) do
      pending = for node <- nodes, node["blockedBy"]["pageInfo"]["hasNextPage"], do: pending_blocker(node, observed)
      {:ok, events, Map.merge(info, %{"total" => total, "pending_blockers" => pending})}
    else
      _error -> {:error, :invalid_backfill_page}
    end
  end

  def events(_body, _repo, _prefix, _observed), do: {:error, :invalid_backfill_page}

  defp normalize_nodes(nodes, prefix, observed) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, events} ->
      with {:ok, issue} <- IssueNode.from_graphql(node),
           {:ok, fields} <- timeline(issue.fields, node["timelineItems"], prefix),
           {:ok, event} <- Row.validate_event(%{number: issue.number, observed_at: observed, source: :backfill, fields: fields}) do
        {:cont, {:ok, events ++ [event]}}
      else
        _error -> {:halt, {:error, :invalid_backfill_page}}
      end
    end)
  end

  defp pending_blocker(node, observed) do
    %{
      "number" => node["number"],
      "cursor" => node["blockedBy"]["pageInfo"]["endCursor"],
      "refs" => node["blockedBy"]["nodes"],
      "updated_at" => node["updatedAt"],
      "observed_at" => DateTime.to_iso8601(observed)
    }
  end

  defp timeline(fields, %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => next}}, prefix) when is_list(nodes) and is_boolean(next) do
    with {:ok, facts} <- timeline_facts(nodes, prefix) do
      fields = Map.merge(fields, %{label_events: facts.labels, sub_issues_added: facts.children, timeline_complete: not next})
      fields = Timing.merge(fields, facts.labels, prefix)
      {:ok, put_merge(fields, facts, not next)}
    end
  end

  defp timeline(_fields, _timeline, _prefix), do: {:error, :invalid_timeline}

  defp timeline_facts(nodes, prefix) do
    Enum.reduce_while(nodes, {:ok, %{labels: [], children: [], closed: [], connected: []}}, fn node, {:ok, facts} ->
      with %{"__typename" => type, "createdAt" => value} <- node,
           {:ok, at} <- IssueNode.datetime(value),
           {:ok, facts} <- timeline_item(type, node, at, prefix, facts) do
        {:cont, {:ok, facts}}
      else
        _error -> {:halt, {:error, :invalid_timeline}}
      end
    end)
  end

  defp timeline_item(type, %{"label" => %{"name" => label}} = node, at, prefix, facts) when type in ["LabeledEvent", "UnlabeledEvent"] and is_binary(label) do
    if String.starts_with?(label, "feature:") or label == prefix <> ":in-progress" do
      event = %{label: label, action: if(type == "LabeledEvent", do: :labeled, else: :unlabeled), at: at, actor: get_in(node, ["actor", "login"]) || :unknown}
      {:ok, %{facts | labels: facts.labels ++ [event]}}
    else
      {:ok, facts}
    end
  end

  defp timeline_item("SubIssueAddedEvent", node, at, _prefix, facts) do
    case IssueNode.reference(node["subIssue"]) do
      {:ok, %{} = ref} -> {:ok, %{facts | children: facts.children ++ [%{ref: ref, at: at}]}}
      _error -> {:error, :invalid_sub_issue}
    end
  end

  defp timeline_item(type, node, at, _prefix, facts) when type in ["ClosedEvent", "ConnectedEvent"] do
    key = if type == "ClosedEvent", do: :closed, else: :connected
    pr = node[if(type == "ClosedEvent", do: "closer", else: "subject")]

    case pr do
      %{"number" => n, "mergedAt" => value} when is_integer(n) and n > 0 and is_binary(value) ->
        with {:ok, merged} <- IssueNode.datetime(value), do: {:ok, Map.update!(facts, key, &[%{at: at, merged: merged, number: n} | &1])}

      _other ->
        {:ok, facts}
    end
  end

  defp timeline_item(_type, _node, _at, _prefix, _facts), do: {:error, :invalid_timeline_item}

  defp put_merge(%{lifecycle: %{state: :closed}} = fields, facts, true) do
    case facts.closed ++ if(facts.closed == [], do: facts.connected, else: []) do
      [] ->
        Map.merge(fields, %{merged_at: :none, pr_number: :none})

      candidates ->
        pr = Enum.max_by(candidates, &DateTime.to_unix(&1.at, :microsecond))
        Map.merge(fields, %{merged_at: pr.merged, pr_number: pr.number})
    end
  end

  defp put_merge(fields, _facts, _complete), do: fields
end
