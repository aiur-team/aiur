defmodule Aiur.GitHub.CommentPollBatch do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.{ReviewThreads, Transport}
  alias Aiur.TicketBranch

  @targets_per_query 100

  @spec fetch([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(targets, opts \\ []) when is_list(targets) do
    targets = targets |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.filter(&positive_number?/1)

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      chunks = Enum.chunk_every(targets, @targets_per_query)

      if length(chunks) > 1 do
        Logger.warning("Github comment GraphQL batch overflow: targets=#{length(targets)} pages=#{length(chunks)}")
      end

      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      chunks
      |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
        case fetch_target_chunk(request_fun, token, owner, repo, chunk, opts) do
          {:ok, batch} -> {:cont, {:ok, Map.merge(acc, batch)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp fetch_target_chunk(request_fun, token, owner, repo, targets, opts) do
    with {:ok, %{issues: issues, pull_requests: pull_requests}} <-
           fetch_pull_request_pages(request_fun, token, owner, repo, targets, nil, opts, %{issues: %{}, pull_requests: []}) do
      {:ok, build_target_batch(targets, issues, pull_requests, opts)}
    end
  end

  defp fetch_pull_request_pages(request_fun, token, owner, repo, targets, cursor, opts, acc) do
    query = query(targets, cursor)
    variables = %{"owner" => owner, "repo" => repo, "cursor" => cursor}

    case Transport.github_graphql(request_fun, token, query, variables) do
      {:ok, body} ->
        with {:ok, %{issues: issues, pull_requests: pull_requests, page_info: page_info}} <- parse_page(body) do
          acc = %{issues: Map.merge(acc.issues, issues), pull_requests: acc.pull_requests ++ pull_requests}

          if Map.get(page_info, "hasNextPage") == true do
            Logger.warning("Github comment GraphQL batch overflow: pull_requests_page=true")

            fetch_pull_request_pages(
              request_fun,
              token,
              owner,
              repo,
              [],
              Map.get(page_info, "endCursor"),
              opts,
              acc
            )
          else
            {:ok, acc}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(targets, _cursor) do
    aliases = Enum.map_join(targets, "\n", &issue_alias/1)

    """
    query AiurCommentPollBatch($owner: String!, $repo: String!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequests(first: 100, states: OPEN, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes { #{pull_request_fields()} }
        }
        #{aliases}
      }
    }
    """
  end

  defp issue_alias(target) do
    """
    target_#{target}: issueOrPullRequest(number: #{target}) {
      ... on Issue { comments(first: 100) { nodes { #{comment_fields()} } } }
      ... on PullRequest { #{pull_request_fields()} }
    }
    """
  end

  defp pull_request_fields do
    """
    number state headRefName headRefOid baseRefName
    comments(first: 100) { nodes { #{comment_fields()} } }
    reviewThreads(first: 100) {
      pageInfo { hasNextPage endCursor }
      nodes { id isResolved path line comments(last: 20) { nodes { #{thread_comment_fields()} } } }
    }
    """
  end

  defp comment_fields, do: "databaseId body createdAt updatedAt url author { login }"
  defp thread_comment_fields, do: "databaseId body createdAt updatedAt url author { login }"

  defp parse_page(body) do
    repository = get_in(body, ["data", "repository"])

    with %{} = repository <- repository,
         %{} = pull_requests <- Map.get(repository, "pullRequests"),
         pull_request_nodes when is_list(pull_request_nodes) <- Map.get(pull_requests, "nodes"),
         %{} = page_info <- Map.get(pull_requests, "pageInfo") do
      issues =
        repository
        |> Enum.flat_map(fn
          {"target_" <> target, node} when is_map(node) -> [{target, normalize_issue_or_pull_request(node)}]
          _ -> []
        end)
        |> Map.new()

      {:ok, %{issues: issues, pull_requests: Enum.map(pull_request_nodes, &normalize_pull_request/1), page_info: page_info}}
    else
      _ -> {:error, :comment_poll_batch_missing}
    end
  end

  defp build_target_batch(targets, issues, pull_requests, opts) do
    Map.new(targets, fn target ->
      direct = Map.get(issues, target, %{})
      pull_request = pull_request_for_target(target, direct, pull_requests)

      batch = %{
        issue_comments: Map.get(direct, :comments, []),
        open_pull_request: pull_request,
        pr_issue_comments: if(is_map(pull_request), do: Map.get(pull_request, :comments, []), else: [])
      }

      batch =
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

      {target, batch}
    end)
  end

  defp pull_request_for_target(_target, %{kind: :pull_request} = direct, _pull_requests), do: direct

  defp pull_request_for_target(target, _direct, pull_requests) do
    Enum.find(pull_requests, fn pull_request ->
      TicketBranch.ticket_branch?(Map.get(pull_request, "head", %{}) |> Map.get("ref"), target)
    end)
  end

  defp normalize_issue_or_pull_request(%{"headRefName" => _} = pull_request), do: normalize_pull_request(pull_request)

  defp normalize_issue_or_pull_request(issue) do
    %{kind: :issue, comments: normalize_comments(get_in(issue, ["comments", "nodes"]))}
  end

  defp normalize_pull_request(pull_request) do
    %{
      :kind => :pull_request,
      "number" => Map.get(pull_request, "number"),
      "state" => String.downcase(to_string(Map.get(pull_request, "state", "open"))),
      "head" => %{"ref" => Map.get(pull_request, "headRefName"), "sha" => Map.get(pull_request, "headRefOid")},
      "base" => %{"ref" => Map.get(pull_request, "baseRefName")},
      comments: normalize_comments(get_in(pull_request, ["comments", "nodes"])),
      review_threads: Map.get(get_in(pull_request, ["reviewThreads"]), "nodes", []),
      review_threads_page_info: Map.get(get_in(pull_request, ["reviewThreads"]), "pageInfo", %{})
    }
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

  defp positive_number?(target) do
    case Integer.parse(target) do
      {number, ""} when number > 0 -> true
      _ -> false
    end
  end
end
