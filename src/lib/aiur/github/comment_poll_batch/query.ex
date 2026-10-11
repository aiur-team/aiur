defmodule Aiur.GitHub.CommentPollBatch.Query do
  @moduledoc """
  GraphQL document for one comment poll batch: one alias group per target.
  """

  # `@pull_requests_per_branch` is 2 rather than 5 because the branch aliases
  # are identity only and have exactly one consumer: `branch_pull_request/2`
  # reads `[node | _rest]` and discards the rest, so the newest is the answer
  # and the second slot is margin.
  #
  # This is correctness-preserving but NOT semantics-preserving. GitHub permits
  # one open pull request per head/*base* pair, so three open pull requests on
  # a single head branch is legal. At `first: 5` GraphQL answered; at `first: 2`
  # `branch_pull_request_from_candidates/2` answers `:unknown` on the overflowed
  # connection and the poller falls back to complete REST reads — every cycle,
  # and at a cost rather than a saving. The answer stays correct; the path to it
  # changes.
  #
  # That case is rare enough here to accept, but do not read this as free.
  #
  # The thread page is `first: 20`, and that is the measured cost lever. GitHub
  # prices requested thread-page capacity: over a 33-target batch of this
  # repository's open pull requests, `reviewThreads(first: 100)` billed **35
  # points** per call against real `rateLimit { cost }`, and `first: 20` bills
  # **8** (#2355). The repository's open pull requests currently carry **zero**
  # review threads (measured via `reviewThreads { totalCount }`), so `first: 20`
  # keeps twenty times the headroom the busiest pull request needs; a pull
  # request that genuinely exceeds twenty threads overflows
  # `review_threads_overflow?/1` and falls back to the complete paginated
  # per-pull-request read (`ReviewThreads`, `after: $cursor`) — correct, at the
  # cost of that target taking the 1-point-floor fallback for the cycle.
  #
  # The comment page is `comments(last: 1)` because the only consumer of these
  # threads — `ReviewThreads.unaddressed_thread_comments` — reads the last
  # comment of unresolved threads and nothing else. Measured against GitHub's
  # own reported `rateLimit { cost }`, `last: 20` and `last: 1` bill identically
  # (35 points on the same 33-target batch), so the cut buys payload and
  # node-limit headroom, not points; it is kept because it is exactly what the
  # consumer reads.
  #
  # A target whose pull request a **webhook delivery already identified**
  # (`Aiur.GitHub.DeliveredPullRequest`) skips the speculation entirely: it
  # contributes one `pullRequest(number:)` alias instead of an
  # `issueOrPullRequest` alias plus up to two `pullRequests(headRefName:)`
  # connections. Three aliases become one, and because the surviving alias is a
  # pull request rather than a maybe-issue it carries `reviewThreads` that are
  # actually used, so the poller's separate per-pull-request
  # `review_threads_unaddressed` call for that target does not happen at all.
  # Nothing whose staleness could mislead the daemon is taken from the store —
  # only the number.
  @pull_requests_per_branch 2

  @doc "Builds the batch document for `{entry, index}` pairs."
  @spec build([{map(), non_neg_integer()}]) :: String.t()
  def build(indexed) do
    aliases = Enum.map_join(indexed, "\n", fn {entry, index} -> target_aliases(entry, index) end)

    """
    query AiurCommentPollBatch($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        #{aliases}
      }
    }
    """
  end

  # A delivery already named the pull request, so the speculative half of the
  # document goes away. The `issueOrPullRequest` alias goes with it: it exists to
  # catch a target that is itself a pull request, and a target the store holds a
  # `:branch_pull_request` body for is a *ticket* — GitHub numbers issues and
  # pull requests in one sequence, so the pull request opened for ticket N always
  # has a number greater than N and can never be N itself.
  defp target_aliases(%{pull_request_number: number} = entry, index) when is_integer(number) do
    """
    delivered_#{index}: pullRequest(number: #{number}) { #{pull_request_fields(entry)} }
    """
  end

  defp target_aliases(%{target: target, branches: branches} = entry, index) do
    branch_aliases =
      branches
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {branch, candidate} -> branch_alias(branch, index, candidate) end)

    """
    target_#{index}: issueOrPullRequest(number: #{target}) {
      ... on Issue { __typename }
      ... on PullRequest { #{pull_request_fields(entry)} }
    }
    #{branch_aliases}
    """
  end

  # Identity only. These candidates are speculative — at most one of up to ten
  # is the pull request the target actually has — so asking each of them for its
  # comments and review threads is paying for content that will be discarded.
  defp branch_alias(branch, index, candidate) do
    """
    branch_#{index}_#{candidate}: pullRequests(headRefName: "#{escape_graphql_string(branch)}", states: OPEN, orderBy: {field: CREATED_AT, direction: DESC}, first: #{@pull_requests_per_branch}) {
      pageInfo { hasNextPage }
      nodes { #{pull_request_identity_fields()} }
    }
    """
  end

  defp escape_graphql_string(value) do
    value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end

  defp pull_request_identity_fields do
    """
    number state headRefName headRefOid baseRefName isDraft reviewDecision
    commits(last: 1) { nodes { commit { committedDate } } }
    """
  end

  defp pull_request_fields(%{cached_threads: threads}) when is_list(threads), do: pull_request_identity_fields()

  defp pull_request_fields(_entry) do
    """
    #{pull_request_identity_fields()}
    reviewThreads(first: 20) {
      pageInfo { hasNextPage endCursor }
      nodes { id isResolved path line comments(last: 1) { nodes { #{thread_comment_fields()} } } }
    }
    """
  end

  defp thread_comment_fields, do: "databaseId body createdAt updatedAt url author { login }"
end
