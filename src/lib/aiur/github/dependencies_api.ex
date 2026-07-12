defmodule Aiur.GitHub.DependenciesApi do
  @moduledoc """
  GitHub native Issue Dependencies REST API domain.
  """

  alias Aiur.GitHub.{Errors, Transport}

  # ---------------------------------------------------------------------------
  # Issue Dependencies REST API helpers
  # ---------------------------------------------------------------------------
  #
  # GitHub's Issue Dependencies endpoints require the newer `2026-03-10`
  # API version header. The other client functions can continue using
  # `2022-11-28` since the issue/comment surfaces they hit are stable.

  @dependencies_api_version "2026-03-10"

  @doc """
  Fetches the issues `issue_number` is currently blocked by, using the
  GitHub native Issue Dependencies REST API.
  """
  @spec fetch_blocked_by(integer() | String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_blocked_by(issue_number, opts \\ []) do
    dependency_get(issue_number, "blocked_by", opts)
  end

  @doc """
  Fetches the issues `issue_number` is blocking.
  """
  @spec fetch_blocking(integer() | String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_blocking(issue_number, opts \\ []) do
    dependency_get(issue_number, "blocking", opts)
  end

  @doc """
  Declares that `blocked_issue_number` is blocked by `blocker_issue_id`
  (note: the API takes the blocker's *internal numeric id*, not its
  issue number — fetch it via `fetch_issue/2` first if needed).

  422 errors typically mean a cycle was detected by GitHub; the caller
  is responsible for pre-checking via BFS through `fetch_blocked_by/2`.
  """
  @spec add_dependency(integer() | String.t(), integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_dependency(blocked_issue_number, blocker_issue_id, opts \\ [])
      when is_integer(blocker_issue_id) do
    dependency_mutate(blocked_issue_number, blocker_issue_id, :post, opts)
  end

  @spec remove_dependency(integer() | String.t(), integer(), keyword()) ::
          {:ok, :removed} | {:error, term()}
  def remove_dependency(blocked_issue_number, blocker_issue_id, opts \\ [])
      when is_integer(blocker_issue_id) do
    dependency_mutate(blocked_issue_number, blocker_issue_id, :delete, opts)
  end

  @spec dependency_get(integer() | String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def dependency_get(issue_number, kind, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/dependencies/#{kind}"

      case request_fun.(%{
             method: :get,
             url: url,
             token: token,
             api_version: @dependencies_api_version
           }) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          {:ok, body}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  @spec dependency_mutate(integer() | String.t(), integer(), atom(), keyword()) ::
          {:ok, map() | :removed} | {:error, term()}
  def dependency_mutate(blocked_number, blocker_id, method, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      collection_url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{blocked_number}/dependencies/blocked_by"

      url = if method == :delete, do: "#{collection_url}/#{blocker_id}", else: collection_url

      req = %{
        method: method,
        url: url,
        token: token,
        api_version: @dependencies_api_version
      }

      req = if method == :post, do: Map.put(req, :body, %{"issue_id" => blocker_id}), else: req

      case request_fun.(req) do
        {:ok, %{status: 204}} when method == :delete ->
          {:ok, :removed}

        {:ok, %{status: status, body: body}} when status in [200, 201] and is_map(body) ->
          {:ok, body}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end
end
