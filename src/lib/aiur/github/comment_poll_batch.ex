defmodule Aiur.GitHub.CommentPollBatch do
  @moduledoc """
  GraphQL batch for the comment poll's **pull request discovery**.

  This used to fetch comments too, and that is what made it the daemon's single
  largest GraphQL consumer. The cost was not in reading comments for pull
  requests the poller cares about; it was in reading them for pull requests it
  had not identified yet. Each target contributes up to two `headRefName`
  lookups asking for `first: 5` candidate pull requests, and every one of those
  candidates carried the full field set — `comments(last: 100)` plus
  `reviewThreads(first: 100) { comments(last: 20) }`, about 2,100 nodes each.
  Discovering one pull request therefore paid for the complete contents of up to
  ten, and GitHub's GraphQL budget is scored on nodes requested, not on nodes
  used.

  So the two jobs are now separated by cost. Identity is cheap and speculative:
  branch candidates ask for numbers and review context only. Content is
  expensive and never speculative: comments come from
  `Aiur.GitHub.Comments.fetch_issue_comments_conditional/2`, where an unchanged
  list answers `304` and costs nothing against the primary REST limit, and
  review threads are fetched for the one pull request that actually resolved.

  What this module still answers, and why each has to stay here:

    * `:open_pull_request` — the number, head/base refs, `reviewDecision` and
      head commit date. REST has no single call that returns review decision,
      and branch-to-PR discovery over REST is a `?head=` query plus a paginated
      scan of every open pull request when the branch is not the legacy one.
    * `:review_thread_comments` — resolution state per inline thread, which the
      REST review-comment endpoints do not expose. Emitted only for a target
      whose threads were actually part of the query; a target discovered
      through a branch alias omits the key entirely so the poller falls back to
      a per-pull-request read rather than mistaking "not asked for" for "none".

  ## A free side effect: the comment→thread map

  Every thread this document parses also deposits its comment→thread mapping
  (`:pr_review_comment_thread`, keyed by comment `databaseId`) into the shared
  store. A `pull_request_review_comment` webhook delivery consults that map
  before paying for a GraphQL node lookup (`Aiur.Events.GithubWebhook.ThreadResolver`),
  so a comment the batch has already seen never costs a point on delivery
  (#2326). A comment's thread is immutable, so the mapping never goes stale and
  a repeat deposit of the same value is declined inside the store's swap.
  """

  require Logger

  alias Aiur.GitHub.{DeliveredPullRequest, PollSnapshots, ResourceStore, ReviewThreads, Transport}
  alias Aiur.TicketBranch

  # Each target contributes an issueOrPullRequest alias plus up to two
  # headRefName-keyed pullRequests lookups (the generated `aiur/<id>-<slug>`
  # branch and the legacy `aiur/<id>` one), so 33 targets keeps every call at
  # or under 100 aliases without ever scanning the repository's open PR list.
  #
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
  # `reviewThreads(first: 100) { comments(last: 20) }` is deliberately NOT
  # reduced. Measured against GitHub's own reported `rateLimit { cost }` this
  # document costs **10-11 points per call**, not the ~660 a naive nodes/100
  # estimate predicts, and a smaller thread page would push every busy pull
  # request onto the paginated fallback each cycle. There is no budget worth
  # buying with review-comment risk.
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
  @targets_per_query 33
  @pull_requests_per_branch 2

  @spec fetch([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(targets, opts \\ []) when is_list(targets) do
    targets = targets |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.filter(&positive_number?/1)

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      repo_identity = owner <> "/" <> repo
      started_at_ms = System.system_time(:millisecond)

      chunks =
        targets
        |> Enum.map(&target_entry(&1, owner, repo, opts, repo_identity, started_at_ms))
        |> Enum.chunk_every(@targets_per_query)

      if length(chunks) > 1 do
        Logger.warning("Github comment GraphQL batch alias overflow: targets=#{length(targets)} calls=#{length(chunks)}")
      end

      chunks
      |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
        reduce_comment_chunk(request_fun, token, owner, repo, chunk, opts, acc)
      end)
    end
  end

  defp reduce_comment_chunk(request_fun, token, owner, repo, chunk, opts, acc) do
    case fetch_target_chunk(request_fun, token, owner, repo, chunk, opts) do
      {:ok, batch} -> {:cont, {:ok, Map.merge(acc, batch)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # DeliveredPullRequest owns exact identity freshness. The review-thread
  # snapshot composes onto that result, or onto the already-known PR number
  # supplied by orchestration when delivery identity is unavailable.
  defp target_entry(target, owner, repo, opts, repo_identity, started_at_ms) do
    entry =
      case DeliveredPullRequest.number_for_target(target, owner, repo, opts) do
        number when is_integer(number) -> %{target: target, pull_request_number: number}
        nil -> branch_target_entry(target, opts)
      end

    snapshot_pr_number = Map.get(entry, :pull_request_number) || known_pull_request_number(target, opts)

    cached_threads =
      case PollSnapshots.review_threads(repo_identity, snapshot_pr_number, opts) do
        {:ok, threads} -> threads
        :miss -> nil
      end

    Map.merge(entry, %{
      cached_threads: cached_threads,
      repo_identity: repo_identity,
      expected_head_repo: repo_identity,
      snapshot_pr_number: snapshot_pr_number,
      started_at_ms: started_at_ms
    })
  end

  defp known_pull_request_number(target, opts) do
    case opts |> Keyword.get(:open_pull_requests_by_target, %{}) |> Map.get(target) do
      %{"number" => number} when not is_nil(number) -> number
      # No known PR for this target. The ticket id is *not* a substitute: it
      # would key the snapshot of whichever pull request happens to carry that
      # number. `cached_threads_match?/2` re-checks the number before use, so
      # the wrong key only wasted a lookup, but a nil key cannot be wrong.
      _other -> nil
    end
  end

  defp branch_target_entry(target, opts) do
    case known_branch(target, opts) do
      nil -> %{target: target, branches: guessed_branches(target, opts), known_branch: false}
      branch -> %{target: target, branches: [branch], known_branch: true}
    end
  end

  # GitHub issues carry no branch name (`Issues.normalize_issue/5` sets
  # `branch_name: nil`), so without the title-derived candidate every target
  # whose PR is not already known would guess the legacy `aiur/<id>` branch and
  # miss the real `aiur/<id>-<slug>` one.
  defp guessed_branches(target, opts) do
    title = opts |> Keyword.get(:titles_by_target, %{}) |> Map.get(target)
    legacy = TicketBranch.legacy_branch_name(target)

    case TicketBranch.branch_name(target, title) do
      ^legacy -> [legacy]
      generated -> [generated, legacy]
    end
  end

  defp known_branch(target, opts) do
    branch =
      opts |> Keyword.get(:branch_names_by_target, %{}) |> Map.get(target) ||
        opts |> Keyword.get(:open_pull_requests_by_target, %{}) |> open_pull_request_head_ref(target)

    if is_binary(branch) and branch != "", do: branch, else: nil
  end

  defp open_pull_request_head_ref(%{} = open_pull_requests, target) do
    case Map.get(open_pull_requests, target) do
      %{} = pull_request -> get_in(pull_request, ["head", "ref"])
      _other -> nil
    end
  end

  defp open_pull_request_head_ref(_open_pull_requests, _target), do: nil

  defp fetch_target_chunk(request_fun, token, owner, repo, entries, opts) do
    indexed = Enum.with_index(entries)
    query = query(indexed)
    variables = %{"owner" => owner, "repo" => repo}

    case Transport.github_graphql(request_fun, token, query, variables, caller: :comment_poll_batch) do
      {:ok, body} ->
        case get_in(body, ["data", "repository"]) do
          %{} = repository ->
            deposit_comment_thread_map(owner, repo, repository)
            {:ok, build_target_batch(indexed, repository, opts)}

          _other ->
            {:error, :comment_poll_batch_missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # This document parses `reviewThreads { comments { databaseId } }` on every
  # cycle — the same fact a `pull_request_review_comment` webhook delivery pays a
  # GraphQL point to learn (`Aiur.Events.GithubWebhook.ThreadResolver`). Depositing
  # the comment→thread mapping here means the delivery resolves from the store
  # instead (#2326). The nodes are only the ones this document actually included
  # (delivered-number and issueOrPullRequest aliases); a comment's thread is
  # immutable, so a stored mapping never goes stale.
  defp deposit_comment_thread_map(owner, repo, repository) do
    repository
    |> Enum.flat_map(fn {_alias, node} -> batch_threads(node) end)
    |> Enum.each(&deposit_thread_mapping(owner, repo, &1))
  end

  defp batch_threads(%{"reviewThreads" => %{"nodes" => nodes}}) when is_list(nodes), do: nodes
  defp batch_threads(_node), do: []

  defp deposit_thread_mapping(owner, repo, thread) do
    with thread_id when is_binary(thread_id) and thread_id != "" <- Map.get(thread, "id"),
         nodes when is_list(nodes) <- get_in(thread, ["comments", "nodes"]) do
      Enum.each(nodes, &deposit_thread_comment(owner, repo, thread_id, &1))
    else
      _other -> :ok
    end
  end

  defp deposit_thread_comment(owner, repo, thread_id, comment) do
    with database_id when is_integer(database_id) <- Map.get(comment, "databaseId"),
         key when not is_nil(key) <- ResourceStore.key(:pr_review_comment_thread, owner, repo, database_id) do
      remember_comment_thread(key, thread_id)
    else
      _other -> :ok
    end
  end

  # The mapping is a constant fact, so a repeat deposit of the same value is
  # declined inside the store's swap rather than re-stamped every cycle.
  defp remember_comment_thread(key, thread_id) do
    ResourceStore.update_resource(
      key,
      fn
        ^thread_id -> :unchanged
        _held -> thread_id
      end,
      source: :poll
    )
  end

  defp query(indexed) do
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
    number state headRefName headRefOid baseRefName reviewDecision
    headRepository { nameWithOwner }
    commits(last: 1) { nodes { commit { committedDate } } }
    """
  end

  defp pull_request_fields(%{cached_threads: threads}) when is_list(threads), do: pull_request_identity_fields()

  defp pull_request_fields(_entry) do
    """
    #{pull_request_identity_fields()}
    reviewThreads(first: 100) {
      pageInfo { hasNextPage endCursor }
      nodes { id isResolved path line comments(last: 20) { nodes { #{thread_comment_fields()} } } }
    }
    """
  end

  defp thread_comment_fields, do: "databaseId body createdAt updatedAt url author { login }"

  defp build_target_batch(indexed, repository, opts) do
    Enum.reduce(indexed, %{}, fn {entry, index}, acc ->
      direct = direct_node(repository, index)

      case pull_request_for_entry(entry, direct, repository, index) do
        {:ok, pull_request} ->
          Map.put(acc, entry.target, target_batch(entry, direct, pull_request, opts))

        :unknown ->
          # The PR lookup was inconclusive (overflowed branch listing or a
          # legacy-branch guess with no match). Leave the target out entirely
          # so the poller falls back to complete REST reads for it.
          acc
      end
    end)
  end

  defp direct_node(repository, index) do
    case Map.get(repository, "target_#{index}") do
      %{} = node -> normalize_issue_or_pull_request(node)
      _other -> %{}
    end
  end

  defp pull_request_for_entry(_entry, %{kind: :pull_request} = direct, _repository, _index), do: {:ok, direct}

  # The delivered number is an identity claim, and this is where GitHub either
  # confirms it or does not. A pull request that has since closed is *not*
  # answered as "no open pull request for this ticket" — a closed one is exactly
  # the state in which a newer one may exist — so the target falls out to the
  # poller's own lookup for this cycle. The next `pull_request` delivery
  # overwrites the store entry with `"state" => "closed"` and the identity stops
  # being offered at all.
  defp pull_request_for_entry(%{pull_request_number: _number} = entry, _direct, repository, index) do
    case Map.get(repository, "delivered_#{index}") do
      %{"headRefName" => _ref} = node ->
        if open_pull_request_node?(node) and same_head_repo?(node, entry.expected_head_repo),
          do: {:ok, normalize_pull_request(node, Map.has_key?(node, "reviewThreads"))},
          else: :unknown

      _other ->
        Logger.warning("Github comment GraphQL batch alias missing: target=#{entry.target}")
        :unknown
    end
  end

  defp pull_request_for_entry(entry, _direct, repository, index) do
    connections =
      entry.branches
      |> Enum.with_index()
      |> Enum.map(fn {_branch, candidate} -> Map.get(repository, "branch_#{index}_#{candidate}") end)

    if Enum.all?(connections, &match?(%{"nodes" => nodes} when is_list(nodes), &1)) do
      branch_pull_request_from_candidates(entry, connections)
    else
      Logger.warning("Github comment GraphQL batch alias missing: target=#{entry.target}")
      :unknown
    end
  end

  # The first candidate branch that resolves to an open PR wins; an overflowed
  # connection is inconclusive and must not be trusted.
  defp branch_pull_request_from_candidates(entry, connections) do
    cond do
      Enum.any?(connections, &(get_in(&1, ["pageInfo", "hasNextPage"]) == true)) ->
        Logger.warning("Github comment GraphQL batch overflow: head_ref_pull_requests target=#{entry.target}")
        :unknown

      connection = Enum.find(connections, fn %{"nodes" => nodes} -> nodes != [] end) ->
        branch_pull_request(entry, Map.get(connection, "nodes"))

      true ->
        branch_pull_request(entry, [])
    end
  end

  defp open_pull_request_node?(node), do: node |> Map.get("state") |> to_string() |> String.downcase() == "open"

  # Fork pull requests that reuse the ticket branch name are filtered out before
  # the first-match decision, so a contributor's fork cannot be read as the
  # ticket's own open pull request.
  defp branch_pull_request(entry, nodes) do
    nodes = Enum.filter(nodes, &same_head_repo?(&1, entry.expected_head_repo))

    case {entry.known_branch, nodes} do
      {false, []} -> :unknown
      {true, []} -> {:ok, nil}
      {_known_branch, [node | _rest]} -> {:ok, normalize_pull_request(node, false)}
    end
  end

  defp same_head_repo?(pull_request, expected) when is_map(pull_request) and is_binary(expected) do
    case get_in(pull_request, ["headRepository", "nameWithOwner"]) do
      actual when is_binary(actual) -> String.downcase(actual) == String.downcase(expected)
      _other -> false
    end
  end

  defp same_head_repo?(_pull_request, _expected), do: false

  # No `:issue_comments` or `:pr_issue_comments` key is ever emitted now, so the
  # poller's `batch_value/3` answers `:missing` for both and every comment read
  # goes through the conditional REST path. That is the inversion: the priced
  # request is no longer the default and the free one no longer the error
  # handler.
  defp target_batch(entry, _direct, pull_request, opts) do
    batch = %{open_pull_request: pull_request_payload(pull_request)}

    cond do
      cached_threads_match?(entry, pull_request) ->
        Map.put(batch, :review_thread_comments, ReviewThreads.unaddressed_thread_comments(entry.cached_threads, opts))

      not threads_included?(pull_request) ->
        # Identity came from a branch alias, which does not carry threads.
        # Omitting the key is the whole point: an empty list here would read as
        # "this pull request has no unaddressed threads" and silently drop
        # every inline review comment on it.
        batch

      review_threads_overflow?(pull_request) ->
        Logger.warning("Github comment GraphQL batch overflow: review_threads target=#{entry.target}")
        batch

      true ->
        PollSnapshots.put_review_threads(
          entry.repo_identity,
          Map.get(pull_request, "number"),
          Map.get(pull_request, :review_threads, []),
          started_at_ms: entry.started_at_ms
        )

        Map.put(
          batch,
          :review_thread_comments,
          ReviewThreads.unaddressed_thread_comments(Map.get(pull_request, :review_threads, []), opts)
        )
    end
  end

  defp cached_threads_match?(%{cached_threads: threads, snapshot_pr_number: pr_number}, %{} = pull_request) when is_list(threads) do
    to_string(Map.get(pull_request, "number")) == to_string(pr_number)
  end

  defp cached_threads_match?(_entry, _pull_request), do: false

  defp threads_included?(%{threads_included?: true}), do: true
  defp threads_included?(_pull_request), do: false

  # The comments poller reads PR identity (number/head/state) from the
  # open_pull_request value; strip the batch-internal normalization keys.
  defp pull_request_payload(nil), do: nil

  defp pull_request_payload(%{} = pull_request) do
    Map.drop(pull_request, [:kind, :threads_included?, :review_threads, :review_threads_page_info])
  end

  defp normalize_issue_or_pull_request(%{"headRefName" => _} = pull_request),
    do: normalize_pull_request(pull_request, Map.has_key?(pull_request, "reviewThreads"))

  defp normalize_issue_or_pull_request(_issue), do: %{kind: :issue}

  defp normalize_pull_request(pull_request, threads_included?) do
    %{
      :kind => :pull_request,
      :threads_included? => threads_included?,
      "number" => Map.get(pull_request, "number"),
      "state" => String.downcase(to_string(Map.get(pull_request, "state", "open"))),
      "head" => %{"ref" => Map.get(pull_request, "headRefName"), "sha" => Map.get(pull_request, "headRefOid")},
      "base" => %{"ref" => Map.get(pull_request, "baseRefName")},
      # Review-staleness context for the rework gate (#1756). `reviewDecision`
      # is nil until the first review lands; `head_committed_at` is the commit
      # date of the head commit the reviews are (or are not) talking about.
      # Both stay on the identity field set, so a branch-discovered pull request
      # keeps full review-freshness context and the gate never goes inert
      # because of the comment inversion.
      "review_decision" => Map.get(pull_request, "reviewDecision"),
      "head_committed_at" => head_committed_at(pull_request),
      review_threads: review_thread_nodes(pull_request),
      review_threads_page_info: review_thread_page_info(pull_request)
    }
  end

  defp head_committed_at(pull_request) do
    case get_in(pull_request, ["commits", "nodes"]) do
      [_ | _] = nodes -> nodes |> List.last() |> get_in(["commit", "committedDate"])
      _other -> nil
    end
  end

  defp review_thread_nodes(pull_request) do
    case Map.get(pull_request, "reviewThreads") do
      %{} = threads -> Map.get(threads, "nodes", [])
      _other -> []
    end
  end

  defp review_thread_page_info(pull_request) do
    case Map.get(pull_request, "reviewThreads") do
      %{} = threads -> Map.get(threads, "pageInfo", %{})
      _other -> %{}
    end
  end

  defp review_threads_overflow?(%{review_threads_page_info: %{} = page_info}),
    do: Map.get(page_info, "hasNextPage") == true

  defp review_threads_overflow?(_pull_request), do: false

  defp positive_number?(target) do
    case Integer.parse(target) do
      {number, ""} when number > 0 -> true
      _ -> false
    end
  end
end
