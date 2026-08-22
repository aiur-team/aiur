defmodule Aiur.GitHub.ReviewThreads do
  @moduledoc """
  Review-thread reads for GitHub pull requests.

  This module owns the paginated GraphQL fetch for unaddressed review-thread
  comments, CODEOWNERS classification for thread comments, and the
  resolution-required marker for unresolved agent replies.
  """

  alias Aiur.Codeowners
  alias Aiur.GitHub.{BotIdentity, PollSnapshots, Transport}

  @review_thread_query """
  query AiurReviewThread($id: ID!) {
    node(id: $id) {
      ... on PullRequestReviewThread {
        id
        isResolved
        path
        line
        comments(last: 20) {
          nodes {
            id
            databaseId
            body
            createdAt
            updatedAt
            url
            author {
              login
            }
          }
        }
      }
    }
  }
  """

  @unaddressed_review_threads_query """
  query AiurUnaddressedReviewThreads($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            isResolved
            path
            line
            comments(last: 20) {
              nodes {
                databaseId
                body
                createdAt
                updatedAt
                url
                author {
                  login
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @spec fetch_unaddressed_pr_review_thread_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_unaddressed_pr_review_thread_comments(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, number} <- normalize_pr_number(pr_number) do
      repo_identity = owner <> "/" <> repo

      case PollSnapshots.review_threads(repo_identity, number, opts) do
        {:ok, threads} ->
          unaddressed_thread_comments_result(threads, opts)

        :miss ->
          with {:ok, token} <- Transport.require_token(opts),
               request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
               started_at_ms = System.system_time(:millisecond),
               {:ok, threads} <- fetch_unaddressed_review_thread_pages(request_fun, token, owner, repo, number, nil, []) do
            PollSnapshots.put_review_threads(repo_identity, number, threads, started_at_ms: started_at_ms)
            unaddressed_thread_comments_result(threads, opts)
          end
      end
    end
  end

  @spec normalize_pr_number(term()) :: {:ok, pos_integer()} | {:error, {:invalid_pr_number, term()}}
  def normalize_pr_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  def normalize_pr_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, {:invalid_pr_number, number}}
    end
  end

  def normalize_pr_number(number), do: {:error, {:invalid_pr_number, number}}

  defp fetch_unaddressed_review_thread_pages(
         request_fun,
         token,
         owner,
         repo,
         number,
         cursor,
         acc
       ) do
    variables =
      %{"owner" => owner, "repo" => repo, "number" => number}
      |> Transport.maybe_put_query("cursor", cursor)

    case Transport.github_graphql(request_fun, token, @unaddressed_review_threads_query, variables, caller: :review_threads_unaddressed) do
      {:ok, body} ->
        with {:ok, {threads, page_info}} <- review_threads_page(body) do
          continue_unaddressed_review_thread_pages(
            request_fun,
            token,
            owner,
            repo,
            number,
            page_info,
            [threads | acc]
          )
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp continue_unaddressed_review_thread_pages(
         request_fun,
         token,
         owner,
         repo,
         number,
         page_info,
         acc
       ) do
    if Map.get(page_info, "hasNextPage") == true do
      fetch_unaddressed_review_thread_pages(
        request_fun,
        token,
        owner,
        repo,
        number,
        Map.get(page_info, "endCursor"),
        acc
      )
    else
      {:ok, acc |> Enum.reverse() |> List.flatten()}
    end
  end

  defp review_threads_page(body) when is_map(body) do
    threads = get_in(body, ["data", "repository", "pullRequest", "reviewThreads", "nodes"])
    page_info = get_in(body, ["data", "repository", "pullRequest", "reviewThreads", "pageInfo"])

    if is_list(threads) and is_map(page_info) do
      {:ok, {threads, page_info}}
    else
      {:error, :review_threads_missing}
    end
  end

  @doc false
  @spec unaddressed_thread_comments([map()], keyword()) :: [map()]
  def unaddressed_thread_comments(threads, opts) when is_list(threads) do
    threads
    |> Enum.flat_map(&unaddressed_thread_comment(&1, opts))
  end

  def unaddressed_thread_comments(_threads, _opts), do: []

  defp unaddressed_thread_comments_result(threads, opts) do
    threads
    |> Enum.reduce_while({:ok, []}, fn thread, {:ok, acc} ->
      comments = unaddressed_thread_comment(thread, opts)

      case Enum.find(comments, &(Map.get(&1, :authoritative) == nil)) do
        nil -> {:cont, {:ok, Enum.reverse(comments, acc)}}
        comment -> {:halt, {:error, get_in(comment, [:codeowners, :reason]) || :codeowners_ownership_unavailable}}
      end
    end)
    |> case do
      {:ok, comments} -> {:ok, Enum.reverse(comments)}
      {:error, _reason} = error -> error
    end
  end

  defp unaddressed_thread_comment(%{"isResolved" => false} = thread, opts) do
    thread
    |> thread_comments()
    |> List.last()
    |> classify_thread_comment(thread, opts)
    |> case do
      %{authoritative: true} = comment ->
        [comment]

      %{authoritative: nil} = comment ->
        [comment]

      %{} = comment ->
        if unresolved_agent_review_thread_reply?(comment, opts),
          do: [mark_review_thread_resolution_required(comment)],
          else: []

      _ ->
        []
    end
  end

  defp unaddressed_thread_comment(_thread, _opts), do: []
  @spec thread_comments(map()) :: [map()]
  def thread_comments(thread) when is_map(thread) do
    case get_in(thread, ["comments", "nodes"]) do
      comments when is_list(comments) -> comments
      _ -> []
    end
  end

  defp classify_thread_comment(nil, _thread, _opts), do: nil

  defp classify_thread_comment(comment, thread, opts) when is_map(comment) and is_map(thread) do
    normalized = normalize_thread_comment(comment, thread)
    classification_opts = BotIdentity.codeowners_classification_opts(opts)
    context = thread_ownership_context(normalized, classification_opts)
    Codeowners.classify_comment(normalized, context, classification_opts)
  end

  defp normalize_thread_comment(comment, thread) do
    path = Map.get(thread, "path")

    %{
      "id" => Map.get(comment, "databaseId"),
      "review_thread_id" => Map.get(thread, "id"),
      "body" => Map.get(comment, "body") || "",
      "created_at" => Map.get(comment, "createdAt"),
      "updated_at" => Map.get(comment, "updatedAt") || Map.get(comment, "createdAt"),
      "html_url" => Map.get(comment, "url"),
      "path" => path,
      "line" => Map.get(thread, "line"),
      "user" => %{"login" => get_in(comment, ["author", "login"])}
    }
  end

  @spec thread_ownership_context(map(), keyword()) :: term()
  def thread_ownership_context(%{"path" => path}, opts) when is_binary(path) and path != "" do
    Codeowners.ownership_for_path(path, opts)
  end

  def thread_ownership_context(_comment, opts), do: Codeowners.repo_ownership(opts)

  defp unresolved_agent_review_thread_reply?(comment, opts) when is_map(comment) do
    comment
    |> get_in(["user", "login"])
    |> BotIdentity.agent_login?(opts)
  end

  defp mark_review_thread_resolution_required(comment) do
    comment
    |> Map.put(:authoritative, true)
    |> Map.put("review_thread_resolution_required", true)
  end

  @spec fetch_review_thread(function(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_review_thread(request_fun, token, thread_id) do
    Transport.github_graphql(request_fun, token, @review_thread_query, %{"id" => thread_id}, caller: :review_threads_verify)
  end

  @spec review_thread_from_body(map()) :: map()
  def review_thread_from_body(body) when is_map(body) do
    case get_in(body, ["data", "node"]) do
      %{"id" => _id} = thread -> thread
      _ -> %{}
    end
  end

  @spec normalize_verified_thread_comment(map()) :: map()
  def normalize_verified_thread_comment(comment) when is_map(comment) do
    %{
      "id" => Map.get(comment, "databaseId") || Map.get(comment, "id"),
      "node_id" => Map.get(comment, "id"),
      "body" => Map.get(comment, "body") || "",
      "created_at" => Map.get(comment, "createdAt"),
      "updated_at" => Map.get(comment, "updatedAt") || Map.get(comment, "createdAt"),
      "html_url" => Map.get(comment, "url"),
      "user" => %{"login" => get_in(comment, ["author", "login"])}
    }
  end
end
