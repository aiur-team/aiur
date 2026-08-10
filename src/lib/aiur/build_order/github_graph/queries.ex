defmodule Aiur.BuildOrder.GitHubGraph.Queries do
  @moduledoc false

  # `rateLimit` reports what the query itself spent against the 5,000-point
  # hourly GraphQL budget. That is a different ceiling from the per-request node
  # budget, and only the response body reports it — the HTTP headers carry the
  # remaining balance but never the cost of the call that produced them.
  @rate_limit "rateLimit { limit cost remaining resetAt }"

  # The catalog's `subIssues` selection carries lifecycle only, deliberately.
  # GraphQL point cost bills a connection per *parent*, not per requested item,
  # so a nested `labels` connection here costs 25 roots x 100 sub-issues =
  # 2,500 of the page's 2,551 request-units. Measured against this repository,
  # that took the page from 1 point to 26, and the recurring catalog poll from
  # ~240 to ~6,240 points/hour against a 5,000/hour ceiling (#1766).
  # `state`/`stateReason` are all the catalog's progress figure needs. Lane and
  # phase counts stay on the selected-root path, whose query already runs for a
  # single root and can afford the labels.
  @catalog """
  query AiurBuildOrderCatalog($owner: String!, $repo: String!, $cursor: String, $pageSize: Int!) {
    #{@rate_limit}
    repository(owner: $owner, name: $repo) {
      issues(first: $pageSize, after: $cursor, labels: ["build-order"]) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          id databaseId number title url state stateReason createdAt updatedAt
          repository { name owner { login } }
          parent { id databaseId number url repository { name owner { login } } }
          labels(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { name } }
          subIssues(first: 100) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes { state stateReason }
          }
        }
      }
    }
  }
  """

  @selected """
  query AiurBuildOrderSelectedRoot($owner: String!, $repo: String!, $number: Int!, $cursor: String, $pageSize: Int!) {
    #{@rate_limit}
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

  @spec catalog() :: String.t()
  def catalog, do: @catalog

  @spec selected() :: String.t()
  def selected, do: @selected
end
