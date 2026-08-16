defmodule Aiur.BuildOrder.GitHubGraph.Queries do
  @moduledoc false

  # `rateLimit` reports what the query itself spent against the 5,000-point
  # hourly GraphQL budget. That is a different ceiling from the per-request node
  # budget, and only the response body reports it — the HTTP headers carry the
  # remaining balance but never the cost of the call that produced them.
  @rate_limit "rateLimit { limit cost remaining resetAt }"

  # The catalog's `subIssues` selection carries lifecycle only by default,
  # deliberately. GraphQL point cost bills a connection per *parent*, not per
  # requested item, so a nested `labels` connection here costs 25 roots x 100
  # sub-issues = 2,500 of the page's 2,551 request-units. Measured against this
  # repository, that took the page from 1 point to 26. The catalog poll is
  # recurring, so that per-poll figure multiplies against a 5,000-points/hour
  # ceiling: at the 5s interval in force when the budget was exhausted, ~720
  # polls/hour x 26 = ~18,720 points/hour, and even at a 30s interval ~120 x 26
  # = ~3,120 would spend most of the hourly budget on this one poller (#1766).
  # Reducing `labels(first: N)` does not help — the cost is per connection, not
  # per requested node.
  #
  # `state`/`stateReason` are all the catalog's progress figure needs, so the
  # default variant stays at 1 point. Lane and phase counts are label-derived,
  # so they need the labelled variant; `GraphProjection` buys it on a slow,
  # separate cadence (default every 10 minutes) rather than on every poll, and
  # carries the resolved counts forward across the cheap polls in between.
  #
  # Those figures are per *page*, and a catalog read paginates: at the default
  # 100-root limit and 25 roots per page a full read is up to 4 pages, so a
  # labelled read costs up to ~104 points and a cheap one up to ~4. At the 60s
  # catalog default that is 6 labelled + 54 cheap reads per hour = 6 x 104 +
  # 54 x 4 = ~840 points/hour, ~17% of the budget — against 60 x 104 = ~6,240
  # (over the entire hourly budget) if every poll bought the labels, which is
  # how #1766 exhausted it. `Settings` caps the labelled variant's page size
  # independently so its node estimate also stays inside GitHub's per-request
  # ceiling.
  #
  # Both variants read `subIssues(first: 100)`, so a root with more than 100
  # members still reports unresolved counts on the catalog even on a labelled
  # read; the selected-root path paginates members and resolves those.
  @catalog_member_labels "labels(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { name } }"

  @catalog_template """
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
            nodes { state stateReason__MEMBER_LABELS__ }
          }
        }
      }
    }
  }
  """

  @catalog String.replace(@catalog_template, "__MEMBER_LABELS__", "")
  @catalog_labelled String.replace(@catalog_template, "__MEMBER_LABELS__", " " <> @catalog_member_labels)

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
  def catalog, do: catalog([])

  # `member_labels?: true` is the expensive variant and is opt-in per read. Any
  # caller that opts in owns the cadence — see the cost note above (#1766).
  @spec catalog(keyword()) :: String.t()
  def catalog(opts) when is_list(opts) do
    if Keyword.get(opts, :member_labels?, false), do: @catalog_labelled, else: @catalog
  end

  @spec selected() :: String.t()
  def selected, do: @selected
end
