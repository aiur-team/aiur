defmodule Aiur.GitHub.DependenciesApi do
  @moduledoc """
  GitHub native Issue Dependencies REST API domain.
  """

  alias Aiur.GitHub.{Errors, ResourceStore, Transport, WriteThrough}

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
  def dependency_get(issue_number, "blocked_by", opts), do: blocked_by_get(issue_number, opts)

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

  # The blocked_by read is store-backed. Aiur writes the edge itself
  # (`dependency_mutate/4`) and learns it free over the `issue_dependencies`
  # webhook, so a held list answers the "did my write land?" confirming reads in
  # `Aiur.GitHub.IssueDependencies` with zero upstream calls, and a stale list
  # costs a free `304` to revalidate against the response ETag.
  #
  # A held body is served as-is unless `revalidate: true` is passed — the
  # dispatch gate's `hydrate_blocked_by` passes it so a blocker added outside
  # Aiur's own writes cannot be silently missed for a cycle (fail-closed).
  defp blocked_by_get(issue_number, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      key = ResourceStore.key(:issue_blocked_by, owner, repo, issue_number)
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/dependencies/blocked_by"
      blocked_by_serve(key, request_fun, token, url, opts)
    end
  end

  # A held list answers unless the caller demands freshness (`revalidate: true`,
  # which the dispatch gate passes so a blocker added outside Aiur's own writes
  # cannot be silently missed). Revalidation sends the stored ETag, so an
  # unchanged list costs a free `304` rather than a full read.
  defp blocked_by_serve(key, request_fun, token, url, opts) do
    if served_blocked_by?(key, opts) do
      {:ok, ResourceStore.data(key)}
    else
      blocked_by_request(key, request_fun, token, url, stored_etag(key))
    end
  end

  defp served_blocked_by?(key, opts) do
    not is_nil(key) and not Keyword.get(opts, :revalidate, false) and is_list(ResourceStore.data(key))
  end

  defp stored_etag(key), do: if(is_nil(key), do: nil, else: ResourceStore.etag(key))

  # One conditional GET. A `304` is served from the held body; a `304` with no
  # body to serve (a validator that survived a restart) discards the stale
  # validator and retries once unconditionally — the same fail-open recovery the
  # issue conditional reader uses.
  defp blocked_by_request(key, request_fun, token, url, etag) do
    request = %{method: :get, url: url, token: token, api_version: @dependencies_api_version}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request

    case request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        retained = Transport.header(Map.get(response, :headers, []), "etag") || etag
        if not is_nil(key), do: ResourceStore.put_resource(key, body, source: :fetch, etag: retained)
        {:ok, body}

      {:ok, %{status: 304}} ->
        blocked_by_not_modified(key, request_fun, token, url, etag)

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  # A `304` answers "nothing changed"; serve the held body when there is one. A
  # validator that outlived its body (restart, eviction) is discarded and the
  # read is retried once without it; without a held validator this `304` is
  # unanswerable.
  defp blocked_by_not_modified(key, request_fun, token, url, etag) do
    case held_blocked_by(key) do
      {:ok, body} -> {:ok, body}
      :missing -> retry_blocked_by(key, request_fun, token, url, etag)
    end
  end

  defp held_blocked_by(nil), do: :missing

  defp held_blocked_by(key) do
    case ResourceStore.data(key) do
      body when is_list(body) -> {:ok, body}
      _other -> :missing
    end
  end

  defp retry_blocked_by(key, request_fun, token, url, etag) when not is_nil(etag) do
    if not is_nil(key), do: ResourceStore.drop_etag(key)
    blocked_by_request(key, request_fun, token, url, nil)
  end

  defp retry_blocked_by(_key, _request_fun, _token, _url, _etag),
    do: {:error, :github_blocked_by_not_modified_without_cached_value}

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
          # The edge GitHub just removed is still listed in the held
          # `:issue_blocked_by` body. Serving that stale list to the caller's own
          # post-write check would report `:dependency_still_present` for an edge
          # that is gone, so the entry is invalidated and the confirming read
          # revalidates instead.
          ResourceStore.drop_data(ResourceStore.key(:issue_blocked_by, owner, repo, blocked_number))
          {:ok, :removed}

        {:ok, %{status: status, body: body}} when status in [200, 201] and is_map(body) ->
          # A dependency add answers with the blocking issue itself. Deposited
          # only when it really is an issue — the endpoint is newer than the
          # rest of this client and its shape is not something to assume.
          WriteThrough.issue(body)
          record_blocked_edge(blocked_number, body, owner, repo)
          {:ok, body}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  # The mutation response is the blocker issue itself, never the blocked issue's
  # full dependency list, so the edge is merged into whatever the store already
  # holds for the blocked issue rather than claimed as a full answer. The declare
  # path has already fetched the list to check idempotency, so in production the
  # merge lands on a full list and the next `fetch_blocked_by` is served without
  # a confirming read (#2326).
  defp record_blocked_edge(blocked_number, blocker_issue, owner, repo) do
    case ResourceStore.key(:issue_blocked_by, owner, repo, blocked_number) do
      nil ->
        :ok

      key ->
        ResourceStore.update_resource(key, &merge_blocked_edge(&1, blocker_issue), source: :mutation)
        :ok
    end
  end

  defp merge_blocked_edge(held, blocker_issue) when is_list(held) do
    if Enum.any?(held, &(Map.get(&1, "id") == Map.get(blocker_issue, "id"))),
      do: :unchanged,
      else: held ++ [blocker_issue]
  end

  defp merge_blocked_edge(_absent, blocker_issue), do: [blocker_issue]
end
