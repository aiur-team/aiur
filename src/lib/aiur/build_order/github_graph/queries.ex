defmodule Aiur.BuildOrder.GitHubGraph.Queries do
  @moduledoc false

  @catalog """
  query AiurBuildOrderCatalog($owner: String!, $repo: String!, $cursor: String, $pageSize: Int!) {
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
            nodes {
              state stateReason
              labels(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { name } }
            }
          }
        }
      }
    }
  }
  """

  @selected """
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

  @spec catalog() :: String.t()
  def catalog, do: @catalog

  @spec selected() :: String.t()
  def selected, do: @selected
end
