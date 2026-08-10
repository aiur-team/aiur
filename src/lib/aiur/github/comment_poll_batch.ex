defmodule Aiur.GitHub.CommentPollBatch do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.{ReviewThreads, Transport}
  alias Aiur.TicketBranch

  # Each target contributes an issueOrPullRequest alias plus up to two
  # headRefName-keyed pullRequests lookups (the generated `aiur/<id>-<slug>`
  # branch and the legacy `aiur/<id>` one), so 33 targets keeps every call at
  # or under 100 aliases without ever scanning the repository's open PR list.
  @targets_per_query 33
  @pull_requests_per_branch 5

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

  defp fetch_target_chunk(request_fun, token, owner, repo, entries, opts) do
    indexed = Enum.with_index(entries)
    query = query(indexed)
    variables = %{"owner" => owner, "repo" => repo}

    case Transport.github_graphql(request_fun, token, query, variables) do
      {:ok, body} ->
        case get_in(body, ["data", "repository"]) do
          %{} = repository -> {:ok, build_target_batch(indexed, repository, opts)}
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
      ... on Issue { comments(last: 100) { pageInfo { hasPreviousPage } nodes { #{comment_fields()} } } }
      ... on PullRequest { #{pull_request_fields()} }
    }
    #{branch_aliases}
    """
  end

  defp branch_alias(branch, index, candidate) do
    """
    branch_#{index}_#{candidate}: pullRequests(headRefName: "#{escape_graphql_string(branch)}", states: OPEN, orderBy: {field: CREATED_AT, direction: DESC}, first: #{@pull_requests_per_branch}) {
      pageInfo { hasNextPage }
      nodes { #{pull_request_fields()} }
    }
    """
  end

  defp escape_graphql_string(value) do
    value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end

  defp pull_request_fields do
    """
    number state headRefName headRefOid baseRefName reviewDecision
    commits(last: 1) { nodes { commit { committedDate } } }
    comments(last: 100) { pageInfo { hasPreviousPage } nodes { #{comment_fields()} } }
    reviewThreads(first: 100) {
      pageInfo { hasNextPage endCursor }
      nodes { id isResolved path line comments(last: 20) { nodes { #{thread_comment_fields()} } } }
    }
    """
  end

  defp comment_fields, do: "databaseId body createdAt updatedAt url author { login }"
  defp thread_comment_fields, do: "databaseId body createdAt updatedAt url author { login }"

  defp build_target_batch(indexed, repository, opts) do
    Enum.reduce(indexed, %{}, fn {entry, index}, acc ->
      direct = direct_node(repository, index)

      case pull_request_for_entry(entry, direct, repository, index) do
        {:ok, pull_request} ->
          Map.put(acc, entry.target, target_batch(entry.target, direct, pull_request, opts))

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

  defp target_batch(target, direct, pull_request, opts) do
    batch = %{open_pull_request: pull_request_payload(pull_request)}
    since = target_since(opts, target)

    batch =
      put_comments_if_complete(
        batch,
        :issue_comments,
        direct,
        target,
        "issue_comments",
        since
      )

    batch =
      put_comments_if_complete(
        batch,
        :pr_issue_comments,
        pull_request || %{},
        target,
        "pull_request_comments",
        since
      )

    if review_threads_overflow?(pull_request) do
      Logger.warning("Github comment GraphQL batch overflow: review_threads target=#{target}")
      batch
    else
      Map.put(
        batch,
        :review_thread_comments,
        if(is_map(pull_request), do: ReviewThreads.unaddressed_thread_comments(Map.get(pull_request, :review_threads, []), opts), else: [])
      )
    end
  end

  # The comments poller reads PR identity (number/head/state) from the
  # open_pull_request value; strip the batch-internal normalization keys.
  defp pull_request_payload(nil), do: nil

  defp pull_request_payload(%{} = pull_request) do
    Map.drop(pull_request, [:kind, :comments, :comments_page_info, :review_threads, :review_threads_page_info])
  end

  defp normalize_issue_or_pull_request(%{"headRefName" => _} = pull_request), do: normalize_pull_request(pull_request)

  defp normalize_issue_or_pull_request(issue) do
    %{
      kind: :issue,
      comments: normalize_comments(get_in(issue, ["comments", "nodes"])),
      comments_page_info: comments_page_info(issue)
    }
  end

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
      "review_decision" => Map.get(pull_request, "reviewDecision"),
      "head_committed_at" => head_committed_at(pull_request),
      comments: normalize_comments(get_in(pull_request, ["comments", "nodes"])),
      comments_page_info: comments_page_info(pull_request),
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

  defp normalize_comments(comments) when is_list(comments) do
    Enum.map(comments, fn comment ->
      %{
        "id" => Map.get(comment, "databaseId"),
        "body" => Map.get(comment, "body") || "",
        "created_at" => Map.get(comment, "createdAt"),
        "updated_at" => Map.get(comment, "updatedAt") || Map.get(comment, "createdAt"),
        "html_url" => Map.get(comment, "url"),
        "user" => %{"login" => get_in(comment, ["author", "login"])}
      }
    end)
  end

  defp normalize_comments(_comments), do: []

  defp review_threads_overflow?(%{review_threads_page_info: %{} = page_info}),
    do: Map.get(page_info, "hasNextPage") == true

  defp review_threads_overflow?(_pull_request), do: false

  defp put_comments_if_complete(batch, key, source, target, label, since) do
    if comments_truncated?(source, since) do
      Logger.warning("Github comment GraphQL batch overflow: #{label} target=#{target}")
      batch
    else
      Map.put(batch, key, since_filtered(Map.get(source, :comments, []), since))
    end
  end

  # The REST path passes `since` to GitHub, which filters server-side. The batch
  # always gets the newest 100, so filter here to keep both paths semantically
  # identical — otherwise every cycle republishes the whole window and relies
  # entirely on publisher dedup, which re-fires old comments once its TTL lapses.
  # Inclusive, matching REST `since`, and on `updated_at` with a `created_at`
  # fallback, matching the poller's own `comment_datetime/1`.
  defp since_filtered(comments, %DateTime{} = since) do
    Enum.filter(comments, fn comment ->
      case comment_datetime(comment) do
        nil -> true
        datetime -> DateTime.compare(datetime, since) != :lt
      end
    end)
  end

  defp comment_datetime(comment) do
    parse_datetime(Map.get(comment, "updated_at") || Map.get(comment, "created_at"))
  end

  # The batch asks for the *newest* 100 comments (`last: 100`), so a target with
  # more than 100 comments is not truncated in any way the poller cares about:
  # it only wants comments newer than its `since` cursor. The window is
  # incomplete only when older comments exist AND the window's own oldest
  # comment is still newer than `since` — i.e. more than 100 comments arrived in
  # one poll interval. Without a known cursor, stay conservative and fall back.
  # No cursor for this target means the batch cannot bound the window at all.
  # The REST path would still apply the poller's default `since` (the boot
  # cutoff), so returning the raw window here would replay a target's whole
  # comment history as fresh events after an orchestrator restart. Omit instead
  # and let REST read it.
  defp comments_truncated?(_source, nil), do: true

  defp comments_truncated?(source, since) when is_map(source) do
    Map.get(comments_page_info(source), "hasPreviousPage") == true and
      not window_covers_since?(Map.get(source, :comments, []), since)
  end

  defp window_covers_since?(comments, %DateTime{} = since) do
    case oldest_created_at(comments) do
      nil -> false
      oldest -> DateTime.compare(oldest, since) != :gt
    end
  end

  defp oldest_created_at(comments) do
    comments
    |> Enum.map(&comment_datetime/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp comments_page_info(%{comments_page_info: %{} = page_info}), do: page_info

  defp comments_page_info(source) when is_map(source) do
    case get_in(source, ["comments", "pageInfo"]) do
      %{} = page_info -> page_info
      _other -> %{}
    end
  end

  defp target_since(opts, target) do
    case Keyword.get(opts, :since) do
      %{} = since_by_target -> parse_datetime(Map.get(since_by_target, target))
      since -> parse_datetime(since)
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp positive_number?(target) do
    case Integer.parse(target) do
      {number, ""} when number > 0 -> true
      _ -> false
    end
  end
end
