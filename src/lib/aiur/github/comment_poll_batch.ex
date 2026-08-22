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

  This module answers only `:open_pull_request`: the number, head/base refs,
  `reviewDecision` and head commit date. REST has no single call that returns
  review decision, and branch-to-PR discovery over REST is a `?head=` query plus
  a paginated scan of every open pull request when the branch is not the legacy
  one. Review threads are fetched after that one pull request resolves; keeping
  their connection out of this speculative document took a live 33-ticket
  query from 35 points to 1.
  """

  require Logger

  alias Aiur.GitHub.Transport
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
  @targets_per_query 33
  @pull_requests_per_branch 2

  @spec fetch([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(targets, opts \\ []) when is_list(targets) do
    targets = targets |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.filter(&positive_number?/1)

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      chunks = targets |> Enum.map(&target_entry(&1, opts)) |> Enum.chunk_every(@targets_per_query)

      if length(chunks) > 1 do
        Logger.warning("Github comment GraphQL batch alias overflow: targets=#{length(targets)} calls=#{length(chunks)}")
      end

      chunks
      |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
        reduce_comment_chunk(request_fun, token, owner, repo, chunk, acc)
      end)
    end
  end

  defp reduce_comment_chunk(request_fun, token, owner, repo, chunk, acc) do
    case fetch_target_chunk(request_fun, token, owner, repo, chunk) do
      {:ok, batch} -> {:cont, {:ok, Map.merge(acc, batch)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp target_entry(target, opts) do
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

  defp fetch_target_chunk(request_fun, token, owner, repo, entries) do
    indexed = Enum.with_index(entries)
    query = query(indexed)
    variables = %{"owner" => owner, "repo" => repo}

    case Transport.github_graphql(request_fun, token, query, variables, caller: :comment_poll_batch) do
      {:ok, body} ->
        case get_in(body, ["data", "repository"]) do
          %{} = repository -> {:ok, build_target_batch(indexed, repository)}
          _other -> {:error, :comment_poll_batch_missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
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

  defp target_aliases(%{target: target, branches: branches}, index) do
    branch_aliases =
      branches
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {branch, candidate} -> branch_alias(branch, index, candidate) end)

    """
    target_#{index}: issueOrPullRequest(number: #{target}) {
      ... on Issue { __typename }
      ... on PullRequest { #{pull_request_identity_fields()} }
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
    commits(last: 1) { nodes { commit { committedDate } } }
    """
  end

  defp build_target_batch(indexed, repository) do
    Enum.reduce(indexed, %{}, fn {entry, index}, acc ->
      direct = direct_node(repository, index)

      case pull_request_for_entry(entry, direct, repository, index) do
        {:ok, pull_request} ->
          Map.put(acc, entry.target, target_batch(pull_request))

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

  defp branch_pull_request(%{known_branch: false}, []), do: :unknown
  defp branch_pull_request(_entry, []), do: {:ok, nil}
  defp branch_pull_request(_entry, [node | _rest]), do: {:ok, normalize_pull_request(node)}

  # No `:issue_comments` or `:pr_issue_comments` key is ever emitted now, so the
  # poller's `batch_value/3` answers `:missing` for both and every comment read
  # goes through the conditional REST path. That is the inversion: the priced
  # request is no longer the default and the free one no longer the error
  # handler.
  defp target_batch(pull_request),
    do: %{open_pull_request: pull_request_payload(pull_request)}

  # The comments poller reads PR identity (number/head/state) from the
  # open_pull_request value; strip the batch-internal normalization keys.
  defp pull_request_payload(nil), do: nil

  defp pull_request_payload(%{} = pull_request) do
    Map.delete(pull_request, :kind)
  end

  defp normalize_issue_or_pull_request(%{"headRefName" => _} = pull_request),
    do: normalize_pull_request(pull_request)

  defp normalize_issue_or_pull_request(_issue), do: %{kind: :issue}

  defp normalize_pull_request(pull_request) do
    %{
      :kind => :pull_request,
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
      "head_committed_at" => head_committed_at(pull_request)
    }
  end

  defp head_committed_at(pull_request) do
    case get_in(pull_request, ["commits", "nodes"]) do
      [_ | _] = nodes -> nodes |> List.last() |> get_in(["commit", "committedDate"])
      _other -> nil
    end
  end

  defp positive_number?(target) do
    case Integer.parse(target) do
      {number, ""} when number > 0 -> true
      _ -> false
    end
  end
end
