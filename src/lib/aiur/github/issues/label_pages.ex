defmodule Aiur.GitHub.Issues.LabelPages do
  @moduledoc false

  require Logger
  alias Aiur.{GitHub, Issue}
  alias Aiur.GitHub.{Access, StatePolicy}
  import Aiur.GitHub.Issues.DispatchAuthorization, only: [authorize_dispatches: 6]
  import Aiur.GitHub.Issues.Normalize, only: [normalize_issue_page: 5]
  import Aiur.GitHub.Issues.Request, only: [conditional_get: 4, response_header: 2]

  # The open-issue list (`issues?state=open&per_page=100`) can be an order of
  # magnitude larger than any single issue: 44+ open issues plus their labels,
  # assignees, and bodies measured ~390 KiB (#2140), and a backlog whose ticket
  # bodies are full specifications measured 2.9 MiB across 45 issues (#2533).
  # The bound is sized to the endpoint's real ceiling rather than an observed
  # backlog: GitHub caps a page at 100 issues and a body at 64 KiB, so one page
  # of maximal bodies plus metadata stays under 16 MiB. A response that still exceeds it
  # is reported as `:response_too_large` by `conditional_get/4` instead of the self-contradictory `{:github, :http, %{status: 200}}`.
  @max_issue_list_response_bytes 16_777_216

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
        "#{Access.base_url()}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(label)}&state=open&per_page=100"

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
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
      labels = Enum.map(state_names, &StatePolicy.state_label(prefix, &1))

      with {:ok, issues} <-
             fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix) do
        {:ok, authorize_dispatches(issues, request_fun, token, owner, repo, prefix)}
      end
    end
  end

  @spec do_fetch_issues_by_states_conditional([String.t()], map(), keyword()) :: tuple()
  def do_fetch_issues_by_states_conditional(state_names, cache, opts) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      ctx = %{
        request_fun: Keyword.get(opts, :request_fun, &Access.default_request_fun/1),
        token: token,
        owner: owner,
        repo: repo,
        prefix: GitHub.Config.label_prefix(),
        caller: "open_issue_list_conditional"
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
      "#{Access.base_url()}/repos/#{ctx.owner}/#{ctx.repo}/issues" <>
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

  @spec fetch_label_issue_pages_conditional(map(), String.t(), map()) :: tuple()
  def fetch_label_issue_pages_conditional(ctx, first_url, label_cache) do
    fetch_conditional_page(ctx, first_url, Map.get(label_cache, :pages, %{}), %{}, [])
  end

  defp fetch_conditional_page(ctx, url, cached_pages, next_pages, acc) do
    cached_page = Map.get(cached_pages, url, %{})
    etag = Map.get(cached_page, :etag)

    case conditional_get(ctx, url, etag, @max_issue_list_response_bytes) do
      {:ok, body, retained_etag, response} when is_list(body) ->
        page = %{
          etag: retained_etag,
          issues: normalize_issue_page(body, ctx.owner, ctx.repo, ctx.prefix, nil),
          next_url: Access.parse_next_page_url(Map.get(response, :headers, []))
        }

        continue_conditional_pages(ctx, cached_pages, Map.put(next_pages, url, page), acc ++ page.issues, page.next_url)

      {:not_modified, _retained_etag} ->
        not_modified_page(ctx, url, cached_page, cached_pages, next_pages, acc)

      {:http_error, response} ->
        {:error, Access.github_status_error(response)}

      {:error, reason} ->
        {:error, reason}

      {:ok, _body, _retained_etag, response} ->
        {:error, Access.github_status_error(response)}
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

  @spec do_list_issues(function(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def do_list_issues(request_fun, url, token, owner, repo, prefix) do
    with {:ok, issues, _next_url} <-
           fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
      {:ok, issues}
    end
  end

  @spec fetch_label_issue_pages(function(), String.t(), String.t(), String.t(), String.t(), String.t(), [Issue.t()]) :: tuple()
  def fetch_label_issue_pages(request_fun, url, token, owner, repo, prefix, acc) do
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
    case request_fun.(%{method: :get, url: url, token: token, caller: "open_issue_list"}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        revision = response_header(Map.get(response, :headers, []), "etag")

        {:ok, normalize_issue_page(body, owner, repo, prefix, revision), Access.parse_next_page_url(Map.get(response, :headers, []))}

      {:ok, %{status: status} = response} ->
        Logger.error("GitHub API request failed status=#{status}")
        {:error, Access.github_status_error(response)}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")
        {:error, Access.classify_error({:error, reason})}
    end
  end
end
