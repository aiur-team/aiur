defmodule Aiur.GitHub.CommentPollBatch do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.{ReviewThreads, Transport}
  alias Aiur.TicketBranch

  # Each target contributes two aliases (issueOrPullRequest + a
  # headRefName-keyed pullRequests lookup), so 50 targets keeps every call at
  # or under 100 aliases without ever scanning the repository's open PR list.
  @targets_per_query 50
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
      nil -> %{target: target, branch: TicketBranch.legacy_branch_name(target), known_branch: false}
      branch -> %{target: target, branch: branch, known_branch: true}
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

  defp target_aliases(%{target: target, branch: branch}, index) do
    """
    target_#{index}: issueOrPullRequest(number: #{target}) {
      ... on Issue { comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { #{comment_fields()} } } }
      ... on PullRequest { #{pull_request_fields()} }
    }
    branch_#{index}: pullRequests(headRefName: "#{escape_graphql_string(branch)}", states: OPEN, first: #{@pull_requests_per_branch}) {
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
    number state headRefName headRefOid baseRefName
    comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { #{comment_fields()} } }
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
    case Map.get(repository, "branch_#{index}") do
      %{"nodes" => nodes} = connection when is_list(nodes) ->
        if get_in(connection, ["pageInfo", "hasNextPage"]) == true do
          Logger.warning("Github comment GraphQL batch overflow: head_ref_pull_requests target=#{entry.target}")
          :unknown
        else
          branch_pull_request(entry, nodes)
        end

      _other ->
        Logger.warning("Github comment GraphQL batch alias missing: target=#{entry.target}")
        :unknown
    end
  end

  defp branch_pull_request(%{known_branch: false}, []), do: :unknown
  defp branch_pull_request(_entry, []), do: {:ok, nil}
  defp branch_pull_request(_entry, [node | _rest]), do: {:ok, normalize_pull_request(node)}

  defp target_batch(target, direct, pull_request, opts) do
    batch = %{open_pull_request: pull_request_payload(pull_request)}

    batch =
      put_comments_if_complete(
        batch,
        :issue_comments,
        direct,
        target,
        "issue_comments"
      )

    batch =
      put_comments_if_complete(
        batch,
        :pr_issue_comments,
        pull_request || %{},
        target,
        "pull_request_comments"
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
    Map.drop(pull_request, [:kind, :comments, :comments_overflow, :review_threads, :review_threads_page_info])
  end

  defp normalize_issue_or_pull_request(%{"headRefName" => _} = pull_request), do: normalize_pull_request(pull_request)

  defp normalize_issue_or_pull_request(issue) do
    %{
      kind: :issue,
      comments: normalize_comments(get_in(issue, ["comments", "nodes"])),
      comments_overflow: comments_overflow?(issue)
    }
  end

  defp normalize_pull_request(pull_request) do
    %{
      :kind => :pull_request,
      "number" => Map.get(pull_request, "number"),
      "state" => String.downcase(to_string(Map.get(pull_request, "state", "open"))),
      "head" => %{"ref" => Map.get(pull_request, "headRefName"), "sha" => Map.get(pull_request, "headRefOid")},
      "base" => %{"ref" => Map.get(pull_request, "baseRefName")},
      comments: normalize_comments(get_in(pull_request, ["comments", "nodes"])),
      comments_overflow: comments_overflow?(pull_request),
      review_threads: review_thread_nodes(pull_request),
      review_threads_page_info: review_thread_page_info(pull_request)
    }
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

  defp put_comments_if_complete(batch, key, source, target, label) do
    if comments_overflow?(source) do
      Logger.warning("Github comment GraphQL batch overflow: #{label} target=#{target}")
      batch
    else
      Map.put(batch, key, Map.get(source, :comments, []))
    end
  end

  defp comments_overflow?(%{comments_overflow: overflow}) when is_boolean(overflow), do: overflow

  defp comments_overflow?(source) when is_map(source) do
    get_in(source, ["comments", "pageInfo", "hasNextPage"]) == true
  end

  defp comments_overflow?(_source), do: false

  defp positive_number?(target) do
    case Integer.parse(target) do
      {number, ""} when number > 0 -> true
      _ -> false
    end
  end
end
