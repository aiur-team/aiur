defmodule Aiur.GitHub.Comments do
  @moduledoc """
  GitHub issue and pull request comment domain.
  """

  require Logger
  alias Aiur.Codeowners
  alias Aiur.GitHub.{Errors, Transport}

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_number, body, opts \\ [])
      when is_binary(issue_number) and is_binary(body) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"

      case request_fun.(%{method: :post, url: url, token: token, body: %{"body" => body}}) do
        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: status} = response} ->
          Logger.error("GitHub create_comment failed status=#{status}")
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  @spec fetch_recent_repo_review_comments(keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_recent_repo_review_comments(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      query = repo_comment_stream_query(opts)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/comments?#{query}"
      fetch_repo_comment_stream(request_fun, token, url, [])
    end
  end

  @spec fetch_recent_repo_issue_comments(keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_recent_repo_issue_comments(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      query = repo_comment_stream_query(opts)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/comments?#{query}"
      fetch_repo_comment_stream(request_fun, token, url, [])
    end
  end

  @spec fetch_issue_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      query = comment_query(opts)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments?#{query}"

      Transport.fetch_json_list(request_fun, token, url)
    end
  end

  @spec fetch_classified_issue_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_issue_comments(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments?per_page=100"
      context = Codeowners.repo_ownership(opts)

      case Transport.fetch_json_list(request_fun, token, url) do
        {:ok, comments} ->
          {:ok, Enum.map(comments, &Codeowners.classify_comment(&1, context, opts))}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @spec repo_comment_stream_query(keyword()) :: String.t()
  def repo_comment_stream_query(opts) do
    %{"sort" => "updated", "direction" => "desc", "per_page" => "100"}
    |> Transport.maybe_put_query("since", Keyword.get(opts, :since))
    |> URI.encode_query()
  end

  @spec fetch_repo_comment_stream(function(), String.t(), String.t() | nil, [map()]) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_repo_comment_stream(_request_fun, _token, nil, acc), do: {:ok, acc}

  def fetch_repo_comment_stream(request_fun, token, url, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        next = Transport.parse_next_page_url(headers)
        fetch_repo_comment_stream(request_fun, token, next, acc ++ body)

      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, acc ++ body}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec comment_query(keyword()) :: String.t()
  def comment_query(opts) do
    %{"per_page" => Keyword.get(opts, :per_page, 100), "page" => Keyword.get(opts, :page, 1)}
    |> Transport.maybe_put_query("since", Keyword.get(opts, :since))
    |> URI.encode_query()
  end
end
