defmodule Aiur.GitHub.DependenciesApi do
  @moduledoc """
  GitHub native Issue Dependencies REST API domain.
  """

  alias Aiur.GitHub.{Access, WriteThrough}

  # ---------------------------------------------------------------------------
  # Issue Dependencies REST API helpers
  # ---------------------------------------------------------------------------
  #
  # GitHub's Issue Dependencies endpoints require the newer `2026-03-10`
  # API version header. The other client functions can continue using
  # `2022-11-28` since the issue/comment surfaces they hit are stable.

  @dependencies_api_version "2026-03-10"
  @max_dependency_pages 10

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

  GitHub documents 422 as a validation failure or spam response, not a
  cycle-specific status. Callers should pre-check with BFS through
  `fetch_blocking/2` and preserve other upstream 422 causes.
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
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)

      url =
        "#{Access.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/dependencies/#{kind}?per_page=100"

      fetch_dependency_pages(request_fun, token, url, [], 0)
    end
  end

  # The blocked_by read is store-backed. Aiur writes the edge itself
  # (`dependency_mutate/4`) and learns it free over the `issue_dependencies`
  # webhook, so a held list answers the "did my write land?" confirming reads in
  # `Aiur.GitHub.IssueDependencies` with zero upstream calls.
  #
  # A held body is served as-is unless `revalidate: true` is passed — the
  # dispatch gate (`Aiur.GitHub.BoundedBlockedBy`) passes it once the held edges
  # or a blocker's `:issue` record is older than its bound, so a blocker added
  # outside Aiur's own writes, or one that closed since the list was stored,
  # cannot be missed for longer than that bound (fail-closed). See
  # `revalidation_etag/2` for why that read cannot be a conditional one.
  defp blocked_by_get(issue_number, opts) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      key = Access.key(:issue_blocked_by, owner, repo, issue_number)
      request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
      url = "#{Access.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/dependencies/blocked_by?per_page=100"
      blocked_by_serve(key, request_fun, token, url, opts)
    end
  end

  # A held list answers unless the caller demands freshness (`revalidate: true`,
  # which the dispatch gate passes so a blocker added outside Aiur's own writes
  # cannot be silently missed).
  defp blocked_by_serve(key, request_fun, token, url, opts) do
    if served_blocked_by?(key, opts) do
      {:ok, Access.data(key)}
    else
      blocked_by_request(key, request_fun, token, url, revalidation_etag(key, opts))
    end
  end

  defp served_blocked_by?(key, opts) do
    not is_nil(key) and not Keyword.get(opts, :revalidate, false) and is_list(Access.data(key))
  end

  # `revalidate: true` means "I need the truth", and on this endpoint the stored
  # validator cannot supply it. GitHub's ETag for
  # `/issues/:n/dependencies/blocked_by` tracks the *blocked* issue, not the
  # blocker objects the response embeds: a blocker that merged and closed, a
  # blocker relabelled `agent:done`, and an edge deleted outright all leave the
  # endpoint answering `304`, and the held body — carrying each blocker's
  # original state — is then served in its place. The dispatch gate derives
  # blocker state from exactly those embedded labels, so the whole fleet stalls
  # against blockers that closed hours earlier and only `ResourceStore.forget/1`
  # clears it (#2550, #2552).
  #
  # So a revalidating read is sent unconditionally. It is bounded by dispatch
  # attempts rather than by tracker size (see `Issues.hydrate_blocked_by/1`),
  # and the #2326 confirming reads — which do not ask for freshness — still
  # answer from the held body with no request at all, validator included.
  defp revalidation_etag(key, opts) do
    if Keyword.get(opts, :revalidate, false), do: nil, else: stored_etag(key)
  end

  defp stored_etag(key), do: if(is_nil(key), do: nil, else: Access.etag(key))

  # One GET, conditional only when a validator was handed in (see
  # `revalidation_etag/2`). A `304` is served from the held body; a `304` with no
  # body to serve (a validator that survived a restart) discards the stale
  # validator and retries once unconditionally — the same fail-open recovery the
  # issue conditional reader uses.
  defp blocked_by_request(key, request_fun, token, url, etag) do
    request = %{method: :get, url: url, token: token, api_version: @dependencies_api_version}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request

    case request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        blocked_by_success(key, request_fun, token, etag, body, response)

      {:ok, %{status: 304}} ->
        blocked_by_not_modified(key, request_fun, token, url, etag)

      {:ok, %{status: _status} = response} ->
        {:error, Access.github_status_error(response)}

      {:error, reason} ->
        {:error, Access.classify_error({:error, reason})}
    end
  end

  defp blocked_by_success(key, request_fun, token, etag, body, response) do
    next = Access.parse_next_page_url(Map.get(response, :headers, []))

    # A prior build may have cached only page one. Remove that body and validator
    # before following pagination so failures cannot leave a truncated list to
    # be served by a later reader.
    if next do
      Access.drop_data(key)
      Access.drop_etag(key)
    end

    with {:ok, complete_body} <- fetch_dependency_pages(request_fun, token, next, body, 1) do
      cache_blocked_by(key, next, complete_body, response, etag)
      {:ok, complete_body}
    end
  end

  defp cache_blocked_by(key, nil, body, response, etag) when not is_nil(key) do
    retained = Access.header(Map.get(response, :headers, []), "etag") || etag
    Access.deposit_unless_older(key, body, source: :fetch, etag: retained, version: blocked_by_version(body))
  end

  defp cache_blocked_by(key, next, body, _response, _etag) when not is_nil(key) and is_binary(next) do
    Access.deposit_unless_older(key, body, source: :fetch, etag: nil, version: blocked_by_version(body))
  end

  defp cache_blocked_by(_key, _next, _body, _response, _etag), do: :ok

  defp fetch_dependency_pages(_request_fun, _token, nil, acc, _pages_fetched), do: {:ok, acc}

  defp fetch_dependency_pages(_request_fun, _token, _url, _acc, pages_fetched)
       when pages_fetched >= @max_dependency_pages,
       do: {:error, :dependency_page_limit_exceeded}

  defp fetch_dependency_pages(request_fun, token, url, acc, pages_fetched) do
    request = %{method: :get, url: url, token: token, api_version: @dependencies_api_version}

    case request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        next = Access.parse_next_page_url(Map.get(response, :headers, []))
        fetch_dependency_pages(request_fun, token, next, acc ++ body, pages_fetched + 1)

      {:ok, %{status: _status} = response} ->
        {:error, Access.github_status_error(response)}

      {:error, reason} ->
        {:error, Access.classify_error({:error, reason})}
    end
  end

  # `:issue_blocked_by` is order-sensitive (`ResourceStore.@order_sensitive_types`):
  # this full read, the dependency mutation and the `issue_dependencies` webhook
  # edge deposit all write the key, and a late `blocked_by_added` landing after a
  # removal would re-add an edge GitHub has already dropped. The guard compares
  # markers on *both* sides, so a version-less deposit does not weaken it — it
  # switches it off, which is what the store warned about on every deposit from
  # here (#2552).
  #
  # The endpoint's list carries no marker of its own, so the marker is the newest
  # `updated_at` among the blockers it names: the same clock the edge deposits
  # version themselves with (`Deposit.blocked_by_edge_deposits/3`), so the two
  # writers are comparable. A list naming nothing has no marker to derive and
  # answers `nil` — there is no edge for a late delivery to roll back to.
  defp blocked_by_version(body) when is_list(body) do
    case Enum.flat_map(body, &blocker_updated_at/1) do
      [] -> nil
      markers -> Enum.max(markers)
    end
  end

  defp blocker_updated_at(blocker) when is_map(blocker) do
    case Map.get(blocker, "updated_at") do
      updated_at when is_binary(updated_at) and updated_at != "" -> [updated_at]
      _absent -> []
    end
  end

  defp blocker_updated_at(_not_a_map), do: []

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
    case Access.data(key) do
      body when is_list(body) -> {:ok, body}
      _other -> :missing
    end
  end

  defp retry_blocked_by(key, request_fun, token, url, etag) when not is_nil(etag) do
    if not is_nil(key), do: Access.drop_etag(key)
    blocked_by_request(key, request_fun, token, url, nil)
  end

  defp retry_blocked_by(_key, _request_fun, _token, _url, _etag),
    do: {:error, :github_blocked_by_not_modified_without_cached_value}

  @spec dependency_mutate(integer() | String.t(), integer(), atom(), keyword()) ::
          {:ok, map() | :removed} | {:error, term()}
  def dependency_mutate(blocked_number, blocker_id, method, opts) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)

      collection_url =
        "#{Access.base_url()}/repos/#{owner}/#{repo}/issues/#{blocked_number}/dependencies/blocked_by"

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
          Access.drop_data(Access.key(:issue_blocked_by, owner, repo, blocked_number))
          {:ok, :removed}

        {:ok, %{status: status, body: body}} when status in [200, 201] and is_map(body) ->
          # A dependency add answers with the blocking issue itself. Deposited
          # only when it really is an issue — the endpoint is newer than the
          # rest of this client and its shape is not something to assume.
          WriteThrough.issue(body)
          record_blocked_edge(blocked_number, body, owner, repo)
          {:ok, body}

        {:ok, %{status: _status} = response} ->
          {:error, Access.github_status_error(response)}

        {:error, reason} ->
          {:error, Access.classify_error({:error, reason})}
      end
    end
  end

  # The mutation response is the blocker issue itself, never the blocked issue's
  # full dependency list, so the edge is merged into whatever the store already
  # holds for the blocked issue rather than claimed as a full answer. The declare
  # path has already fetched the list to check idempotency, so in production the
  # merge lands on a full list and the next `fetch_blocked_by` is served without
  # a confirming read (#2326). A cold entry is left alone, never started from a
  # single edge: the merge must not fabricate the very list it was asked to grow
  # (review #2332). The write carries the blocker's own marker and derives a
  # content validator so a revalidating read stays free.
  defp record_blocked_edge(blocked_number, blocker_issue, owner, repo) do
    case Access.key(:issue_blocked_by, owner, repo, blocked_number) do
      nil ->
        :ok

      key ->
        Access.update_resource(
          key,
          &merge_blocked_edge(&1, blocker_issue),
          source: :mutation,
          version: Map.get(blocker_issue, "updated_at"),
          etag: :derive
        )

        :ok
    end
  end

  defp merge_blocked_edge(held, blocker_issue) when is_list(held) do
    if Enum.any?(held, &(Map.get(&1, "id") == Map.get(blocker_issue, "id"))),
      do: :unchanged,
      else: held ++ [blocker_issue]
  end

  defp merge_blocked_edge(_absent, _blocker_issue), do: :unchanged
end
