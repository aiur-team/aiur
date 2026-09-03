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

  alias Aiur.Orchestrator.DispatchPolicy

  @max_issue_response_bytes 65_536
  # The open-issue list (`issues?state=open&per_page=100`) can be an order of
  # magnitude larger than any single issue: 44+ open issues plus their labels,
  # assignees, and bodies measured ~390 KiB, which the single-issue cap
  # truncates. The list endpoint gets its own, larger bound so a growing
  # backlog does not silently fail the candidate fetch as `{:github, :http,
  # %{status: 200}}` (#2140).
  @max_issue_list_response_bytes 1_048_576

  @spec max_issue_response_bytes() :: pos_integer()
  def max_issue_response_bytes, do: @max_issue_response_bytes

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  # #2298 item 3: the open-issue candidate/list reads are deliberately NOT
  # `ResourceStore`-backed — a repo collection has no single resource identity
  # for the store to key, and the per-cycle paths already revalidate every page
  # with their own ETag cache (`_conditional` variants). They carry `caller:` so
  # the spend is attributed rather than folded into an endpoint shape.
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

  @doc """
  Fetches one issue through `Aiur.GitHub.ResourceStore`.

  Same endpoint and same body as an unconditional `GET
  /repos/{owner}/{repo}/issues/{number}` — but addressed by the issue's identity
  rather than by the caller, so readers of that issue meet in one entry. The
  unconditional form was retired (#2326) so no new call site can pick it by coin
  flip; this conditional form is the only reader of the endpoint.

  The answer says which of three costs was paid, because "we had it" and "we
  revalidated it for free" are different claims and only one of them can be
  asserted by counting requests:

    * `:fresh` — **no request was made.** The store held the body.
    * `:not_modified` — one conditional request returned `304`. A `304` does not
      count against GitHub's primary REST rate limit, so this costs quota
      nothing; it is not free of latency.
    * `:fetched` — one full `200`. Quota was spent.

  ## Stating the staleness you tolerate

  `:freshness_ms` is how a caller says what it can accept, and there is
  deliberately no default beyond zero. A caller that states nothing gets a
  conditional request, not an arbitrarily old body: the store records
  `fetched_at_ms` per entry precisely so the *reader* decides, and inventing a
  global window here would be the silent guess the store exists to remove. A
  conditional request is the safe default because an unchanged issue answers
  `304`, which costs no primary rate limit.

  Pass `revalidate: true` to skip the no-request path outright, which is what an
  operator-initiated refresh wants: it is the cheapest way to turn "probably
  unchanged" into "provably unchanged".

  ## The rule this function obeys

  > Ask `fetch/1` before spending a request. Never treat a `304` as data.

  A stored validator does **not** imply a servable entry — the sweep keeps ETags
  purely to detect change, and a `304` carries no body. So the decision to serve
  is made by the held body alone, never by the presence of an ETag.

  ## Failing open

  A body can be absent while its validator survives — after a restart, or after
  the store's own bound evicted it — so a `304` can arrive with nothing to serve.
  That is not an error and must not surface as one: the read retries once without
  the validator, which is exactly the unconditional request the caller would have
  made anyway. Every other store fault degrades the same way, to a plain
  conditional request.
  """
  @spec fetch_issue_raw_conditional(integer() | String.t(), keyword()) ::
          {:ok, map(), :fresh | :not_modified | :fetched} | {:error, term()}
  def fetch_issue_raw_conditional(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- raw_repository(opts),
         {:ok, token} <- Transport.require_token(opts) do
      key = ResourceStore.key(:issue, owner, repo, to_string(issue_number))

      case stored_issue(key, opts) do
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
  defp stored_issue(key, opts) do
    if Keyword.get(opts, :revalidate, false) do
      nil
    else
      servable_within(ResourceStore.fetch(key), Keyword.get(opts, :freshness_ms))
    end
  end

  # The store hands back when the body was recorded; the caller says how old it
  # will accept. Comparing them here — rather than trusting whichever number the
  # store happens to prefer — is what lets two readers of the same issue with
  # different tolerances share one entry without either being served something it
  # said it could not use.
  defp servable_within({:ok, %{data: body, fetched_at_ms: fetched_at_ms}}, freshness_ms)
       when is_map(body) and is_integer(fetched_at_ms) and is_integer(freshness_ms) and freshness_ms > 0 do
    if System.system_time(:millisecond) - fetched_at_ms <= freshness_ms, do: body, else: nil
  end

  defp servable_within(_answer, _freshness_ms), do: nil

  defp revalidate_raw_issue(issue_number, owner, repo, token, key, opts, retried_without_validator?) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"
    etag = if retried_without_validator?, do: nil, else: ResourceStore.etag(key)

    request = %{method: :get, url: url, token: token, max_response_bytes: @max_issue_response_bytes, caller: "issue_raw_conditional"}
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

    put_issue_resource(context.key, body, retained, :fetch)
    {:ok, body, :fetched}
  end

  defp handle_raw_issue_response({:ok, %{status: 200}}, _context), do: {:error, :invalid_github_issue_response}

  defp handle_raw_issue_response({:ok, %{status: 304} = response}, context) do
    serve_not_modified_raw_issue(
      context.issue_number,
      context.owner,
      context.repo,
      context.token,
      context.key,
      context.opts,
      context.retried_without_validator?,
      Transport.header(Map.get(response, :headers, []), "etag") || context.etag
    )
  end

  defp handle_raw_issue_response({:ok, %{status: _status} = response}, _context) do
    {:error, Errors.github_status_error(response)}
  end

  defp handle_raw_issue_response({:error, reason}, _context), do: {:error, Errors.classify_error({:error, reason})}

  # A `304` proves the stored body is still current, which is only useful if the
  # body is still there. When it is not — a restart dropped it, or the store's
  # own bound evicted it — re-asking without the validator is the correct
  # recovery and costs one ordinary request. Reporting an error instead would turn
  # a cache miss into a page failure.
  #
  # `304` is answered from the held body regardless of the caller's freshness
  # window: GitHub has just certified that the body is current, so its age is no
  # longer evidence of anything.
  defp serve_not_modified_raw_issue(issue_number, owner, repo, token, key, opts, retried_without_validator?, retained_etag) do
    case ResourceStore.data(key) do
      body when is_map(body) ->
        # A `304` may rotate the validator, and the new one is what the next
        # conditional request has to send. Retaining it is the only write this
        # path makes — see `retain_validator/2` for why the body is left alone.
        retain_validator(key, retained_etag)
        {:ok, body, :not_modified}

      _missing when not retried_without_validator? ->
        ResourceStore.drop_data(key)
        revalidate_raw_issue(issue_number, owner, repo, token, key, opts, true)

      _missing ->
        {:error, :github_issue_not_modified_without_cached_value}
    end
  end

  # One deposit shape for both readers of this endpoint, so the poll path and the
  # detail path cannot disagree about what an issue entry contains.
  #
  # `:version` is the issue's own `updated_at`. It is what lets a later webhook
  # delivery for the same issue tell "this is the change I already hold" from
  # "this is a newer one".
  #
  # It does *not* follow that re-depositing an unchanged issue is silent: the
  # store's change test includes `:source`, and these two readers deposit under
  # different sources, so alternating readers of an unchanged issue do publish.
  # Nothing subscribes to `:issue` yet, and the honest fix belongs in the store's
  # change test rather than here, so this is named rather than worked around.
  #
  # `:processed` is deliberately never passed: fetching an issue is not the same
  # as having acted on it, and marking it handled here would suppress the wake
  # that the resource's genuine change is supposed to cause.
  defp put_issue_resource(key, body, etag, source) do
    version = issue_version(body)

    if regression?(key, version) do
      # A webhook delivery carrying a newer object beat this read. Writing anyway
      # would not merely hold an older body: `put_resource/3` stamps
      # `fetched_at_ms` with now, so the older body would be described as freshly
      # fetched and a reader asking for something no older than a window would be
      # handed state from before the change.
      :ok
    else
      ResourceStore.put_resource(key, body, source: source, version: version, etag: etag)
    end
  end

  # Refuses a strictly older version, and writes on equal or missing ones.
  #
  # Both markers are GitHub's own ISO-8601 timestamps, which sort lexically.
  # Equal versions still write because a body can legitimately differ under an
  # unchanged marker, and a missing marker on either side is not evidence that
  # anything went backwards. Same rule and same reasoning as
  # `Aiur.Events.GithubWebhook.Deposit.regression?/2` — the two must not drift.
  defp regression?(key, version) do
    case ResourceStore.fetch(key) do
      {:ok, %{version: held}} when is_binary(held) and is_binary(version) -> version < held
      _other -> false
    end
  end

  # What a `304` is allowed to write back, and — more importantly — what it is not.
  #
  # It is tempting to re-deposit the validated body so the entry's `fetched_at_ms`
  # moves and the next reader inside its window is served for nothing. That was
  # tried and is wrong, and the reason is worth keeping: the body is read, then
  # written, and a webhook delivery landing between the two makes the write
  # incoherent. `put_resource/3` and `update_resource/3` both take the version as
  # a fixed option while the body comes from the entry, so whichever one wins,
  # the pair can disagree — a body carrying one `updated_at` filed under another.
  # A concurrency test caught exactly that (`shared_resource_store_test.exs`), and
  # an entry whose body and version describe different objects is worse than a
  # stale clock: every later version comparison is then made against a marker that
  # never belonged to the body it is attached to.
  #
  # So the clock does not move, and the only thing written back is the validator,
  # through the store's own narrow `put_etag/2`. What that costs is one extra
  # conditional request the next time a reader's window has passed — and a
  # conditional request that answers `304` costs **no primary rate limit**, which
  # is the whole reason this path exists. The optimisation was saving a free
  # request at the price of a corruptible entry.
  defp retain_validator(key, etag), do: ResourceStore.put_etag(key, etag)

  # Both call sites have already matched `body` as a map, so there is deliberately
  # no non-map clause: dialyzer proves it unreachable.
  defp issue_version(body) when is_map(body) do
    case Map.get(body, "updated_at") do
      version when is_binary(version) and version != "" -> version
      _absent -> nil
    end
  end

  # A validator is only worth sending alongside the body it validates.
  #
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
        prefix: GitHub.Config.label_prefix(),
        caller: "open_issue_list_conditional"
      }

      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=open&per_page=100"
      active_states = Config.active_states() |> Enum.map(&StatePolicy.normalize_state/1) |> MapSet.new()

      case fetch_label_issue_pages_conditional(ctx, url, cache) do
        {:ok, issues, updated_cache} ->
          candidates =
            filter_and_authorize_candidates_with_degenerate(
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
    dispatchable =
      Enum.filter(issues, fn issue ->
        is_binary(issue.state) and
          MapSet.member?(active_states, StatePolicy.normalize_state(issue.state))
      end)

    authorize_dispatches(dispatchable, request_fun, token, owner, repo, prefix)
  end

  # The orchestrator's conditional open-issue poll (`?state=open&per_page=100`
  # is unfiltered, so this sees every open issue) partitions rather than
  # discards: zero- and multi-`agent:*`-label tickets are returned alongside
  # the authorized dispatch candidates so the orchestrator's repair pass can
  # heal them. Every other non-dispatchable open ticket (terminal/error
  # labels) is dropped exactly as before (#2420).
  defp filter_and_authorize_candidates_with_degenerate(issues, active_states, request_fun, token, owner, repo, prefix) do
    {dispatchable, rest} =
      Enum.split_with(issues, fn issue ->
        is_binary(issue.state) and
          MapSet.member?(active_states, StatePolicy.normalize_state(issue.state))
      end)

    authorized = authorize_dispatches(dispatchable, request_fun, token, owner, repo, prefix)
    healable = Enum.filter(rest, &degenerate_state_labels?/1)
    authorized ++ healable
  end

  defp degenerate_state_labels?(%Issue{state_labels: []}), do: true
  defp degenerate_state_labels?(%Issue{state_labels: [_, _ | _]}), do: true
  defp degenerate_state_labels?(_issue), do: false

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

    case conditional_get(ctx, url, etag, @max_issue_list_response_bytes) do
      {:ok, body, retained_etag, response} when is_list(body) ->
        page = %{
          etag: retained_etag,
          issues: normalize_issue_page(body, ctx.owner, ctx.repo, ctx.prefix, nil),
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
        prefix: GitHub.Config.label_prefix(),
        caller: "issue_by_id_conditional"
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
    case request_fun.(%{method: :get, url: url, token: token, caller: "open_issue_list"}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        revision = response_header(Map.get(response, :headers, []), "etag")

        {:ok, normalize_issue_page(body, owner, repo, prefix, revision), Transport.parse_next_page_url(Map.get(response, :headers, []))}

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
    case request_fun.(%{method: :get, url: url, token: token, caller: "issue_by_id"}) do
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
        put_issue_resource(store_key, body, retained_etag, :poll)

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
    # Same reasoning as the detail path's `304`: the shared entry's freshness clock
    # has to move when GitHub says the body is still current, or the next reader
    # pays for bytes that were just proved unchanged.
    refresh_stored_issue(ctx, issue_id, retained_etag)

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

  defp refresh_stored_issue(ctx, issue_id, retained_etag) do
    ctx.owner
    |> then(&ResourceStore.key(:issue, &1, ctx.repo, issue_id))
    |> retain_validator(retained_etag)
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

        case ResourceStore.data(store_key) do
          body when is_map(body) -> normalize_issue(body, ctx.owner, ctx.repo, ctx.prefix, retained_etag)
          _missing -> nil
        end
    end
  end

  # The response cap is the endpoint's, not the caller's. Without it here the poll
  # could deposit an issue larger than `fetch_issue_raw_conditional/2` is willing
  # to accept, and the detail path would then be served — from the shared entry —
  # a body it would have rejected had it fetched the same URL itself.
  defp conditional_get(ctx, url, etag, max_response_bytes \\ @max_issue_response_bytes) do
    request = %{method: :get, url: url, token: ctx.token, max_response_bytes: max_response_bytes, caller: Map.get(ctx, :caller, "open_issue_list_conditional")}
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

  # GitHub's issues collection includes pull requests in the shared number
  # space. Drop them while the raw discriminator is still available so they
  # cannot become zero-label tickets eligible for state-label repair.
  defp normalize_issue_page(body, owner, repo, prefix, dispatch_revision) do
    body
    |> Enum.reject(&Map.has_key?(&1, "pull_request"))
    |> Enum.map(&normalize_issue(&1, owner, repo, prefix, dispatch_revision))
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
      # `dispatch_authorized?: false` means "not verified to dispatch", and the
      # tri-state `dispatch_authorization` starts `:deferred` ("not yet checked")
      # until `authorize_dispatches` resolves it to `:authorized` or `:denied`
      # from a fetched timeline. `:deferred` must never be read as revoked, so a
      # poll that re-normalizes a running issue without (yet) re-verifying it
      # cannot terminate its agent (#2409).
      dispatch_authorized?: false,
      dispatch_authorization: :deferred,
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
  def hydrate_blocked_by(%Issue{} = issue) do
    # The dispatch gate must never be served a blocked-by list the store holds
    # that has silently gone stale — a blocker added on GitHub's side without
    # Aiur's own write or a webhook delivery must still hold dispatch. So this
    # entry point always revalidates with the stored ETag (a free 304 when
    # unchanged) instead of serving the held body blind (#2326).
    hydrate_blocked_by(issue, revalidate: true)
  end

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
    gh_issue
    |> extract_state(extract_state_labels(label_names, prefix))
  end

  # A zero-label (`[]`) ticket resolves to `nil` here — the `String | nil`
  # contract for blocker state and expected-state checks — and is told apart
  # from a multi-label ticket by the candidate filter on the `Issue.state_labels`
  # list (`degenerate_state_labels?/1`), not on atoms that never escape this
  # module (#2420). A multi-label (`[_, _ | _]`) ticket is itself resolved
  # deterministically by the clause below (#2384).
  defp extract_state(%{"state" => "closed"}, _state_labels), do: "Closed"
  defp extract_state(_gh_issue, [state]), do: state

  # A ticket carrying two `agent:*` state labels is a broken lifecycle state.
  # `extract_state` used to answer `nil` here, which made every consumer see an
  # "unknown" state — worst of all the CI lifecycle, whose terminal transition
  # would then be skipped and never clear a stale `agent:ci-wait`, stranding the
  # pair as permanently undispatchable (#2366). Resolve the pair deterministically
  # so a state-labeled ticket always has a concrete state.
  defp extract_state(_gh_issue, state_labels) when is_list(state_labels) and state_labels != [],
    do: DispatchPolicy.resolve_state_labels(state_labels)

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
