defmodule Aiur.GitHub.Issues do
  @moduledoc """
  GitHub issue fetch and normalization domain.
  """

  require Logger
  alias Aiur.{BuildOrder.Bounded, Config, GitHub, Issue, TrackerIdentity}

  alias Aiur.GitHub.{
    CycleFetchCache,
    DependenciesApi,
    DispatchAuthorization,
    Errors,
    Labels,
    ResourceStore,
    StatePolicy,
    Transport
  }

  @max_issue_response_bytes 65_536

  @spec max_issue_response_bytes() :: pos_integer()
  def max_issue_response_bytes, do: @max_issue_response_bytes

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    if Config.active_states() == [], do: {:ok, []}, else: do_fetch_candidate_issues(opts)
  end

  @spec fetch_candidate_issues_conditional(map(), keyword()) ::
          {:ok, [Issue.t()], map()} | {:error, term()}
  def fetch_candidate_issues_conditional(cache, opts \\ []) when is_map(cache) do
    if Config.active_states() == [] do
      {:ok, [], cache}
    else
      do_fetch_candidate_issues_conditional(cache, opts)
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    if state_names == [], do: {:ok, []}, else: do_fetch_issues_by_states(state_names, opts)
  end

  @doc """
  Fetches issue lists conditionally, retaining one ETag and materialized page
  per label/page URL. A 304 therefore reuses the complete cached list instead
  of treating the first page as a complete result.
  """
  @spec fetch_issues_by_states_conditional([String.t()], map(), keyword()) ::
          {:ok, [Issue.t()], map()} | {:error, term()}
  def fetch_issues_by_states_conditional(state_names, cache, opts \\ [])
      when is_list(state_names) and is_map(cache) do
    if state_names == [] do
      {:ok, [], cache}
    else
      do_fetch_issues_by_states_conditional(state_names, cache, opts)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    if issue_ids == [], do: {:ok, []}, else: do_fetch_issue_states_by_ids(issue_ids, opts)
  end

  @doc """
  Fetches individual issues conditionally, retaining the last ETag and
  materialized issue under a stable issue-id key.
  """
  @spec fetch_issue_states_by_ids_conditional([String.t()], map(), keyword()) ::
          {:ok, [Issue.t()], map()} | {:error, term()} | {:error, term(), map()}
  def fetch_issue_states_by_ids_conditional(issue_ids, cache, opts \\ [])
      when is_list(issue_ids) and is_map(cache) do
    if issue_ids == [] do
      {:ok, [], cache}
    else
      do_fetch_issue_states_by_ids_conditional(issue_ids, cache, opts)
    end
  end

  @spec fetch_issue_raw(integer() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_issue_raw(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- raw_repository(opts),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"

      case request_fun.(%{
             method: :get,
             url: url,
             token: token,
             max_response_bytes: @max_issue_response_bytes
           }) do
        {:ok, %{private: %{aiur_response_too_large: true}, status: status} = response}
        when status != 200 ->
          {:error, Errors.github_status_error(response)}

        {:ok, %{private: %{aiur_response_too_large: true}}} ->
          {:error, :github_issue_response_too_large}

        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, body}

        {:ok, %{status: 200}} ->
          {:error, :invalid_github_issue_response}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  @doc """
  Fetches one issue through `Aiur.GitHub.ResourceStore`.

  Same endpoint and same body as `fetch_issue_raw/2` — `GET
  /repos/{owner}/{repo}/issues/{number}` — but addressed by the issue's identity
  rather than by the caller, so every reader of that issue meets in one entry.
  That is the point: the orchestrator's per-issue reconciliation poll, the Build
  Order ticket-detail pane and the dashboard's ticket panel were each reading
  this exact URL on their own schedule into their own cache.

  The answer says which of three costs was paid, because "we had it" and "we
  revalidated it for free" are different claims and only one of them can be
  asserted by counting requests:

    * `:fresh` — **no request was made.** The store held the body.
    * `:not_modified` — one conditional request returned `304`. A `304` does not
      count against GitHub's primary REST rate limit, so this costs quota
      nothing; it is not free of latency.
    * `:fetched` — one full `200`. Quota was spent.

  Pass `revalidate: true` to skip the no-request path and force a conditional
  request, which is what an operator-initiated refresh wants: it is the cheapest
  way to turn "probably unchanged" into "provably unchanged", and on an unchanged
  issue it still costs no primary rate limit.

  ## The rule this function obeys

  > Ask `payload/1` before spending a request. Never treat a `304` as data.

  A stored validator does **not** imply a servable entry — the sweep keeps ETags
  purely to detect change, and a `304` carries no body. So the decision to serve
  is made by `payload/1` alone, never by the presence of an ETag.

  ## Failing open

  A body can be absent while its validator survives — after a restart, or after
  the store's own bound evicted it — so a `304` can arrive with nothing to serve.
  That is not an error and must not surface as one: the read retries once without
  the validator, which is exactly the unconditional request the caller would have
  made anyway. Every other store fault degrades the same way, to
  `fetch_issue_raw/2`'s behaviour.
  """
  @spec fetch_issue_raw_conditional(integer() | String.t(), keyword()) ::
          {:ok, map(), :fresh | :not_modified | :fetched} | {:error, term()}
  def fetch_issue_raw_conditional(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- raw_repository(opts),
         {:ok, token} <- Transport.require_token(opts) do
      key = ResourceStore.key(:issue, owner, repo, to_string(issue_number))

      case stored_issue(key, Keyword.get(opts, :revalidate, false)) do
        body when is_map(body) ->
          {:ok, body, :fresh}

        nil ->
          revalidate_raw_issue(issue_number, owner, repo, token, key, opts, false)
      end
    end
  end

  # An explicit revalidation deliberately ignores a held body: the caller is
  # asking to be *sure*, and the conditional request that answers that is free
  # when nothing changed.
  defp stored_issue(_key, true), do: nil
  defp stored_issue(key, _revalidate), do: ResourceStore.payload(key)

  defp revalidate_raw_issue(issue_number, owner, repo, token, key, opts, retried_without_validator?) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"
    etag = if retried_without_validator?, do: nil, else: ResourceStore.etag(key)

    request = %{method: :get, url: url, token: token, max_response_bytes: @max_issue_response_bytes}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request

    context = %{
      issue_number: issue_number,
      owner: owner,
      repo: repo,
      token: token,
      key: key,
      opts: opts,
      etag: etag,
      retried_without_validator?: retried_without_validator?
    }

    request |> request_fun.() |> handle_raw_issue_response(context)
  end

  defp handle_raw_issue_response({:ok, %{private: %{aiur_response_too_large: true}, status: status} = response}, _context)
       when status != 200 do
    {:error, Errors.github_status_error(response)}
  end

  defp handle_raw_issue_response({:ok, %{private: %{aiur_response_too_large: true}}}, _context) do
    {:error, :github_issue_response_too_large}
  end

  defp handle_raw_issue_response({:ok, %{status: 200, body: body} = response}, context) when is_map(body) do
    retained = Transport.header(Map.get(response, :headers, []), "etag") || context.etag

    ResourceStore.put_payload(context.key, body, retained)
    {:ok, body, :fetched}
  end

  defp handle_raw_issue_response({:ok, %{status: 200}}, _context), do: {:error, :invalid_github_issue_response}

  defp handle_raw_issue_response({:ok, %{status: 304}}, context) do
    serve_not_modified_raw_issue(
      context.issue_number,
      context.owner,
      context.repo,
      context.token,
      context.key,
      context.opts,
      context.retried_without_validator?
    )
  end

  defp handle_raw_issue_response({:ok, %{status: _status} = response}, _context) do
    {:error, Errors.github_status_error(response)}
  end

  defp handle_raw_issue_response({:error, reason}, _context), do: {:error, Errors.classify_error({:error, reason})}

  # A `304` proves the stored body is still current, which is only useful if the
  # body is still there. When it is not — a restart dropped it, or the payload
  # table evicted it — re-asking without the validator is the correct recovery
  # and costs one ordinary request. Reporting an error instead would turn a cache
  # miss into a page failure.
  defp serve_not_modified_raw_issue(issue_number, owner, repo, token, key, opts, retried_without_validator?) do
    case ResourceStore.payload(key) do
      body when is_map(body) ->
        {:ok, body, :not_modified}

      _missing when not retried_without_validator? ->
        ResourceStore.drop_payload(key)
        revalidate_raw_issue(issue_number, owner, repo, token, key, opts, true)

      _missing ->
        {:error, :github_issue_not_modified_without_cached_value}
    end
  end

  defp raw_repository(opts) do
    case Keyword.fetch(opts, :repository) do
      {:ok, {owner, repo}} ->
        repository_components(owner, repo)

      {:ok, _invalid_repository} ->
        {:error, :invalid_github_repository}

      :error ->
        with {:ok, {owner, repo}} <- Transport.parse_repo() do
          repository_components(owner, repo)
        end
    end
  end

  defp repository_components(owner, repo) do
    case Bounded.github_repository_components(owner, repo) do
      {:ok, repository} -> {:ok, repository}
      :error -> {:error, :invalid_github_repository}
    end
  end

  defp do_fetch_candidate_issues(opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=open&per_page=100"
      active_states = Config.active_states() |> Enum.map(&StatePolicy.normalize_state/1) |> MapSet.new()

      with {:ok, issues} <- fetch_label_issue_pages(request_fun, url, token, owner, repo, prefix, []) do
        {:ok, filter_and_authorize_candidates(issues, active_states, request_fun, token, owner, repo, prefix)}
      end
    end
  end

  defp do_fetch_candidate_issues_conditional(cache, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      ctx = %{
        request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
        token: token,
        owner: owner,
        repo: repo,
        prefix: GitHub.Config.label_prefix()
      }

      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=open&per_page=100"
      active_states = Config.active_states() |> Enum.map(&StatePolicy.normalize_state/1) |> MapSet.new()

      case fetch_label_issue_pages_conditional(ctx, url, cache) do
        {:ok, issues, updated_cache} ->
          candidates =
            filter_and_authorize_candidates(
              issues,
              active_states,
              ctx.request_fun,
              ctx.token,
              ctx.owner,
              ctx.repo,
              ctx.prefix
            )

          {:ok, candidates, updated_cache}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp filter_and_authorize_candidates(issues, active_states, request_fun, token, owner, repo, prefix) do
    candidates =
      Enum.filter(issues, fn issue ->
        is_binary(issue.state) and
          MapSet.member?(active_states, StatePolicy.normalize_state(issue.state))
      end)

    authorize_dispatches(candidates, request_fun, token, owner, repo, prefix)
  end

  @spec fetch_issues_for_each_label(
          [String.t()],
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix) do
    Enum.reduce_while(labels, {:ok, %{}}, fn label, {:ok, acc} ->
      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(label)}&state=open&per_page=100"

      reduce_label_issues(request_fun, url, token, owner, repo, prefix, acc)
    end)
    |> case do
      {:ok, map} -> {:ok, Map.values(map)}
      error -> error
    end
  end

  @spec reduce_label_issues(
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  def reduce_label_issues(request_fun, url, token, owner, repo, prefix, acc) do
    case fetch_label_issue_pages(request_fun, url, token, owner, repo, prefix, []) do
      {:ok, issues} ->
        merged = Map.merge(acc, Map.new(issues, &{&1.id, &1}), fn _k, v, _new -> v end)
        {:cont, {:ok, merged}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  @spec do_fetch_issues_by_states([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issues_by_states(state_names, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      labels = Enum.map(state_names, &StatePolicy.state_label(prefix, &1))

      with {:ok, issues} <-
             fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix) do
        {:ok, authorize_dispatches(issues, request_fun, token, owner, repo, prefix)}
      end
    end
  end

  defp do_fetch_issues_by_states_conditional(state_names, cache, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      ctx = %{
        request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
        token: token,
        owner: owner,
        repo: repo,
        prefix: GitHub.Config.label_prefix()
      }

      state_names
      |> Enum.map(&StatePolicy.state_label(ctx.prefix, &1))
      |> Enum.reduce_while({:ok, %{}, cache}, &reduce_conditional_label(ctx, &1, &2))
      |> finish_conditional_fetch(ctx)
    end
  end

  defp reduce_conditional_label(ctx, label, {:ok, issues_by_id, cache}) do
    # Percent-encode reserved characters (":" -> "%3A") so the locally built
    # first-page URL matches GitHub's Link-header pagination URLs, which key
    # the conditional page cache.
    url =
      "#{Transport.base_url()}/repos/#{ctx.owner}/#{ctx.repo}/issues" <>
        "?labels=#{URI.encode(label, &URI.char_unreserved?/1)}&state=open&per_page=100"

    case fetch_label_issue_pages_conditional(ctx, url, Map.get(cache, label, %{})) do
      {:ok, issues, label_cache} ->
        merged = Map.merge(issues_by_id, Map.new(issues, &{&1.id, &1}), fn _key, old, _new -> old end)
        {:cont, {:ok, merged, Map.put(cache, label, label_cache)}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp finish_conditional_fetch({:ok, issues_by_id, updated_cache}, ctx) do
    # `normalize_issue/5` defaults `dispatch_authorized?: false`, so this step
    # is load-bearing, not an optimization: without it
    # `DispatchPolicy.candidate_issue?/3` rejects every issue and the daemon
    # dispatches nothing. Must mirror the unconditional path.
    issues = authorize_dispatches(Map.values(issues_by_id), ctx.request_fun, ctx.token, ctx.owner, ctx.repo, ctx.prefix)

    {:ok, issues, updated_cache}
  end

  defp finish_conditional_fetch(error, _ctx), do: error

  defp fetch_label_issue_pages_conditional(ctx, first_url, label_cache) do
    fetch_conditional_page(ctx, first_url, Map.get(label_cache, :pages, %{}), %{}, [])
  end

  defp fetch_conditional_page(ctx, url, cached_pages, next_pages, acc) do
    cached_page = Map.get(cached_pages, url, %{})
    etag = Map.get(cached_page, :etag)

    case conditional_get(ctx, url, etag) do
      {:ok, body, retained_etag, response} when is_list(body) ->
        page = %{
          etag: retained_etag,
          issues: Enum.map(body, &normalize_issue(&1, ctx.owner, ctx.repo, ctx.prefix)),
          next_url: Transport.parse_next_page_url(Map.get(response, :headers, []))
        }

        continue_conditional_pages(ctx, cached_pages, Map.put(next_pages, url, page), acc ++ page.issues, page.next_url)

      {:not_modified, _retained_etag} ->
        not_modified_page(ctx, url, cached_page, cached_pages, next_pages, acc)

      {:http_error, response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, reason}

      {:ok, _body, _retained_etag, response} ->
        {:error, Errors.github_status_error(response)}
    end
  end

  defp not_modified_page(ctx, url, %{issues: issues} = cached_page, cached_pages, next_pages, acc) when is_list(issues) do
    continue_conditional_pages(
      ctx,
      cached_pages,
      Map.put(next_pages, url, cached_page),
      acc ++ issues,
      Map.get(cached_page, :next_url)
    )
  end

  # A process restart should not turn a conditional response into an
  # incomplete list. Retry once without the stale ETag.
  defp not_modified_page(ctx, url, _cached_page, cached_pages, next_pages, acc) do
    fetch_conditional_page(ctx, url, Map.delete(cached_pages, url), next_pages, acc)
  end

  defp continue_conditional_pages(_ctx, _cached_pages, pages, issues, nil), do: {:ok, issues, %{pages: pages}}

  defp continue_conditional_pages(ctx, cached_pages, pages, issues, next_url) do
    fetch_conditional_page(ctx, next_url, cached_pages, pages, issues)
  end

  @spec do_fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issue_states_by_ids(issue_ids, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      with {:ok, issues} <-
             do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix) do
        {:ok, authorize_dispatches(issues, request_fun, token, owner, repo, prefix)}
      end
    end
  end

  @spec do_fetch_issue_states_by_ids_conditional([String.t()], map(), keyword()) ::
          {:ok, [Issue.t()], map()} | {:error, term()} | {:error, term(), map()}
  def do_fetch_issue_states_by_ids_conditional(issue_ids, cache, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      ctx = %{
        request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
        token: token,
        owner: owner,
        repo: repo,
        prefix: GitHub.Config.label_prefix()
      }

      stable_ids = Enum.map(issue_ids, &to_string/1)
      cache = Map.take(cache, stable_ids)

      result =
        Enum.reduce_while(stable_ids, {:ok, [], cache}, &reduce_fetch_issue_conditional(ctx, &1, &2))

      case result do
        {:ok, issues, updated_cache} -> {:ok, Enum.reverse(issues), updated_cache}
        {:error, reason, updated_cache} -> {:error, reason, updated_cache}
      end
    end
  end

  @spec do_list_issues(function(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def do_list_issues(request_fun, url, token, owner, repo, prefix) do
    with {:ok, issues, _next_url} <-
           fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
      {:ok, issues}
    end
  end

  defp fetch_label_issue_pages(request_fun, url, token, owner, repo, prefix, acc) do
    with {:ok, issues, next_url} <-
           fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
      case next_url do
        nil ->
          {:ok, acc ++ issues}

        next_url ->
          fetch_label_issue_pages(
            request_fun,
            next_url,
            token,
            owner,
            repo,
            prefix,
            acc ++ issues
          )
      end
    end
  end

  defp fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        revision = response_header(Map.get(response, :headers, []), "etag")

        {:ok, Enum.map(body, &normalize_issue(&1, owner, repo, prefix, revision)), Transport.parse_next_page_url(Map.get(response, :headers, []))}

      {:ok, %{status: status} = response} ->
        Logger.error("GitHub API request failed status=#{status}")
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec do_fetch_issues_by_id_list(
          [String.t()],
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix) do
    result =
      Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, acc} ->
        url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_id}"
        reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc)
      end)

    case result do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec reduce_fetch_issue(
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [Issue.t()]
        ) :: {:cont, {:ok, [Issue.t()]}} | {:halt, {:error, term()}}
  def reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body} = response} when is_map(body) ->
        revision = response_header(Map.get(response, :headers, []), "etag")
        {:cont, {:ok, [normalize_issue(body, owner, repo, prefix, revision) | acc]}}

      {:ok, %{status: 404}} ->
        {:cont, {:ok, acc}}

      {:ok, %{status: _status} = response} ->
        {:halt, {:error, Errors.github_status_error(response)}}

      {:error, reason} ->
        {:halt, {:error, Errors.classify_error({:error, reason})}}
    end
  end

  defp reduce_fetch_issue_conditional(ctx, issue_id, {:ok, issues, cache}) do
    fetch_conditional_issue(ctx, issue_id, issues, cache, false)
  end

  defp fetch_conditional_issue(ctx, issue_id, issues, cache, retried_without_cache?) do
    url = "#{Transport.base_url()}/repos/#{ctx.owner}/#{ctx.repo}/issues/#{issue_id}"
    cached_entry = Map.get(cache, issue_id, %{})
    store_key = ResourceStore.key(:issue, ctx.owner, ctx.repo, issue_id)

    # The poll's own cache still wins when it has an entry, so the existing
    # behaviour is unchanged for the steady state. The store is consulted only
    # where the poll had nothing and would otherwise have spent a full read —
    # which is the case where some other reader of this same issue, typically the
    # Build Order page, has already paid for it.
    etag = Map.get(cached_entry, :etag) || store_validator(store_key, retried_without_cache?)

    case conditional_get(ctx, url, etag) do
      {:ok, body, retained_etag, _response} when is_map(body) ->
        # Publish the raw body, not the normalized `Issue`. Other readers of this
        # issue want different projections of it — the detail pane wants the
        # description and assignees the dispatch struct throws away — so the
        # shared entry has to be the response, with normalization left to each
        # reader.
        ResourceStore.put_payload(store_key, body, retained_etag)

        issue =
          body
          |> normalize_issue(ctx.owner, ctx.repo, ctx.prefix, retained_etag)
          |> authorize_issue(ctx.request_fun, ctx.token, ctx.owner, ctx.repo, ctx.prefix)

        entry = %{etag: retained_etag, issue: issue}
        {:cont, {:ok, [issue | issues], Map.put(cache, issue_id, entry)}}

      {:not_modified, retained_etag} ->
        materialize_not_modified_issue(
          ctx,
          issue_id,
          issues,
          cache,
          cached_entry,
          retained_etag,
          retried_without_cache?
        )

      {:http_error, %{status: 404}} ->
        {:cont, {:ok, issues, Map.delete(cache, issue_id)}}

      {:http_error, response} ->
        {:halt, {:error, Errors.github_status_error(response), cache}}

      {:error, reason} ->
        {:halt, {:error, reason, cache}}

      {:ok, _body, _retained_etag, response} ->
        {:halt, {:error, Errors.github_status_error(response), cache}}
    end
  end

  defp materialize_not_modified_issue(
         ctx,
         issue_id,
         issues,
         cache,
         cached_entry,
         retained_etag,
         retried_without_cache?
       ) do
    case materialized_issue(ctx, issue_id, cached_entry, retained_etag) do
      %Issue{} = issue ->
        issue =
          authorize_issue(
            issue,
            ctx.request_fun,
            ctx.token,
            ctx.owner,
            ctx.repo,
            ctx.prefix
          )

        entry = %{etag: retained_etag, issue: issue}
        {:cont, {:ok, [issue | issues], Map.put(cache, issue_id, entry)}}

      _missing_materialized_issue when not retried_without_cache? ->
        fetch_conditional_issue(ctx, issue_id, issues, Map.delete(cache, issue_id), true)

      _missing_materialized_issue ->
        {:halt, {:error, :github_issue_not_modified_without_cached_value, cache}}
    end
  end

  # Only reached when the poll's own cache had no validator, so borrowing the
  # store's is never a downgrade: without it the request is unconditional.
  defp store_validator(_store_key, true), do: nil
  defp store_validator(store_key, false), do: ResourceStore.etag(store_key)

  # A `304` answered against a borrowed validator has no locally materialized
  # `Issue` to return, so normalize the shared body instead. Without this the
  # poll would fall through to a second, unconditional request for bytes the
  # store was already holding — the trap where sharing a validator without the
  # body makes things worse rather than better.
  defp materialized_issue(ctx, issue_id, cached_entry, retained_etag) do
    case Map.get(cached_entry, :issue) do
      %Issue{} = issue ->
        issue

      _missing ->
        store_key = ResourceStore.key(:issue, ctx.owner, ctx.repo, issue_id)

        case ResourceStore.payload(store_key) do
          body when is_map(body) -> normalize_issue(body, ctx.owner, ctx.repo, ctx.prefix, retained_etag)
          _missing -> nil
        end
    end
  end

  defp conditional_get(ctx, url, etag) do
    request = %{method: :get, url: url, token: ctx.token}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request

    case ctx.request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} ->
        retained_etag = Transport.header(Map.get(response, :headers, []), "etag") || etag
        {:ok, body, retained_etag, response}

      {:ok, %{status: 304} = response} ->
        retained_etag = Transport.header(Map.get(response, :headers, []), "etag") || etag
        {:not_modified, retained_etag}

      {:ok, %{status: _status} = response} ->
        {:http_error, response}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp authorize_issue(issue, request_fun, token, owner, repo, prefix) do
    DispatchAuthorization.authorize(
      issue,
      owner,
      repo,
      prefix,
      request_fun: request_fun,
      token: token
    )
  end

  @spec normalize_issue(map(), String.t(), String.t(), String.t()) :: Issue.t()
  def normalize_issue(gh_issue, owner, repo, prefix) when is_map(gh_issue) do
    normalize_issue(gh_issue, owner, repo, prefix, nil)
  end

  defp normalize_issue(gh_issue, owner, repo, prefix, dispatch_revision) when is_map(gh_issue) do
    number = gh_issue["number"]
    labels = gh_issue["labels"] || []
    label_names = Enum.map(labels, &(&1["name"] || ""))
    state_labels = extract_state_labels(label_names, prefix)

    %Issue{
      id: to_string(number),
      identifier: to_string(number),
      tracker_identity: tracker_identity(gh_issue, owner, repo),
      title: gh_issue["title"],
      description: gh_issue["body"],
      priority: extract_priority(label_names),
      state: extract_state(gh_issue, state_labels),
      state_labels: state_labels,
      branch_name: nil,
      url: gh_issue["html_url"],
      assignee_id: get_in(gh_issue, ["assignee", "login"]),
      creator_login: get_in(gh_issue, ["user", "login"]),
      dispatch_revision: dispatch_revision,
      dispatch_authorized?: false,
      paused: paused_label?(label_names, prefix),
      parked: parked_label?(label_names, prefix),
      labels: Enum.map(label_names, &String.downcase/1),
      assigned_to_worker: true,
      created_at: parse_datetime(gh_issue["created_at"]),
      updated_at: parse_datetime(gh_issue["updated_at"])
    }
  end

  @doc """
  Hydrates `blocked_by` on a GitHub `Issue.t()` from the native Issue
  Dependencies REST API, reusing the read side already consumed by
  `Aiur.GitHub.IssueDependencies`.

  The GitHub list poll never populates `blocked_by` (each dependency read is a
  separate REST call, so per-issue hydration on the poll path would blow the
  #1388 read budget). This function is deliberately called only for the issue
  actually being considered for dispatch, so the cost is bounded by dispatch
  attempts rather than by tracker size, and results are memoized in the
  per-cycle fetch cache so repeated dispatch attempts of the same issue reuse
  the same dependency snapshot.

  Returns `{:error, reason}` when the dependency read fails; callers treat that
  as *unknown* blockers and hold dispatch (fail-closed), because dispatching on
  unknown blockers would reintroduce exactly the "dispatches work GitHub knows
  is blocked" defect this gate exists to prevent.
  """
  @spec hydrate_blocked_by(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def hydrate_blocked_by(%Issue{} = issue), do: hydrate_blocked_by(issue, [])

  @spec hydrate_blocked_by(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def hydrate_blocked_by(%Issue{blocked_by: blockers} = issue, _opts) when blockers != [] do
    {:ok, issue}
  end

  def hydrate_blocked_by(%Issue{id: id} = issue, opts) when is_binary(id) and id != "" do
    case CycleFetchCache.fetch({:blocked_by, id}, fn ->
           DependenciesApi.fetch_blocked_by(id, opts)
         end) do
      {:ok, blockers} when is_list(blockers) ->
        {:ok, %{issue | blocked_by: normalize_blockers(blockers, GitHub.Config.label_prefix())}}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected, other}}
    end
  end

  def hydrate_blocked_by(%Issue{} = issue, _opts), do: {:ok, issue}

  # Reduces GitHub's native dependency issue objects to the same `blocked_by`
  # shape Linear's normalize_issue produces (`%{id, identifier, state, url}`)
  # so the dispatch gate (`DispatchPolicy.todo_issue_blocked_by_non_terminal?`)
  # and the blocker event machinery consume them unchanged. Blocker state comes
  # from the same source as the issue itself: `agent:*` labels, with a raw
  # `state: "closed"` resolving to the terminal "Closed". A blocker with no
  # derivable state keeps `state: nil`, which the gate treats as non-terminal
  # (blocking) — fail-closed on incomplete payloads.
  defp normalize_blockers(blockers, prefix) when is_list(blockers) do
    Enum.map(blockers, &normalize_blocker(&1, prefix))
  end

  defp normalize_blocker(blocker, prefix) when is_map(blocker) do
    number = Map.get(blocker, "number")
    labels = Map.get(blocker, "labels") || []
    label_names = Enum.map(labels, &(&1["name"] || ""))

    %{
      id: to_string(number),
      identifier: to_string(number),
      state: extract_state(blocker, label_names, prefix),
      url: Map.get(blocker, "html_url")
    }
  end

  defp normalize_blocker(_blocker, _prefix), do: %{id: "", identifier: "", state: nil, url: nil}

  @spec extract_state(map(), [String.t()], String.t()) :: String.t() | nil
  def extract_state(gh_issue, label_names, prefix) do
    extract_state(gh_issue, extract_state_labels(label_names, prefix))
  end

  defp extract_state(%{"state" => "closed"}, _state_labels), do: "Closed"
  defp extract_state(_gh_issue, [state]), do: state
  defp extract_state(_gh_issue, _state_labels), do: nil

  @spec extract_state_labels([String.t()], String.t()) :: [String.t()]
  def extract_state_labels(label_names, prefix) do
    prefix_colon = normalize_label_name("#{prefix}:")

    label_names
    |> Enum.map(&state_label_suffix(&1, prefix_colon))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec extract_priority([String.t()]) :: integer() | nil
  def extract_priority(label_names), do: Enum.find_value(label_names, &parse_priority_label/1)

  @spec parse_priority_label(String.t()) :: integer() | nil
  def parse_priority_label(name) do
    case Regex.run(~r/^priority:(\d+)$/, name) do
      [_, n] -> parse_priority_int(n)
      _ -> nil
    end
  end

  @spec parse_priority_int(String.t()) :: integer() | nil
  def parse_priority_int(n) do
    case Integer.parse(n) do
      {priority, _} -> priority
      :error -> nil
    end
  end

  @spec parse_datetime(String.t() | nil) :: DateTime.t() | nil
  def parse_datetime(nil), do: nil

  def parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp state_label_suffix(name, prefix_colon) do
    normalized = normalize_label_name(name)

    if String.starts_with?(normalized, prefix_colon) do
      normalized
      |> String.replace_prefix(prefix_colon, "")
      |> state_suffix_unless_preserved()
    end
  end

  defp state_suffix_unless_preserved(suffix),
    do: unless(Labels.marker_suffix?(suffix), do: suffix)

  defp paused_label?(label_names, prefix) when is_list(label_names) do
    paused_label = normalize_label_name("#{prefix}:paused")

    Enum.any?(label_names, fn name ->
      normalize_label_name(name) == paused_label
    end)
  end

  defp parked_label?(label_names, prefix) when is_list(label_names) do
    parked_label = normalize_label_name("#{prefix}:parked")

    Enum.any?(label_names, fn name ->
      normalize_label_name(name) == parked_label
    end)
  end

  defp normalize_label_name(label) when is_binary(label),
    do: String.downcase(String.trim(label))

  defp normalize_label_name(_label), do: ""

  defp response_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: header_value(value)

      _ ->
        nil
    end)
  end

  defp response_header(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: header_value(value)
    end)
  end

  defp response_header(_headers, _name), do: nil

  defp header_value([value | _]), do: header_value(value)
  defp header_value(value) when is_binary(value), do: value
  defp header_value(_value), do: nil

  defp authorize_dispatches(issues, request_fun, token, owner, repo, prefix) do
    Enum.map(issues, fn issue ->
      authorize_issue(issue, request_fun, token, owner, repo, prefix)
    end)
  end

  defp tracker_identity(gh_issue, owner, repo) do
    case GitHub.Config.configured_repo() do
      {:ok, {configured_owner, configured_repo}} ->
        case TrackerIdentity.from_github(
               gh_issue,
               {configured_owner, configured_repo},
               {owner, repo}
             ) do
          {:ok, identity} ->
            identity

          {:error, reason} ->
            TrackerIdentity.unjoinable(reason,
              owner: configured_owner,
              repository: configured_repo,
              identifier: Map.get(gh_issue, "number")
            )
        end

      {:error, reason} ->
        TrackerIdentity.unjoinable(reason, identifier: Map.get(gh_issue, "number"))
    end
  end
end
