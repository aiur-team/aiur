defmodule Aiur.GitHub.Issues do
  @moduledoc """
  GitHub issue fetch and normalization domain.
  """

  alias Aiur.{Config, GitHub, Issue, TestTicketScope}
  alias Aiur.GitHub.{Access, OpenIssueListing, StateLabels, StatePolicy}
  alias Aiur.GitHub.Issues.{IdList, LabelPages, Normalize, RawIssue, Request}
  import Aiur.GitHub.Issues.DispatchAuthorization, only: [authorize_dispatches: 6]

  import Aiur.GitHub.Issues.LabelPages,
    only: [do_fetch_issues_by_states_conditional: 3, fetch_label_issue_pages: 7, fetch_label_issue_pages_conditional: 3]

  @spec max_issue_response_bytes() :: pos_integer()
  defdelegate max_issue_response_bytes(), to: Request

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
  defdelegate fetch_issue_raw_conditional(issue_number, opts \\ []), to: RawIssue

  defp do_fetch_candidate_issues(opts) do
    listed_from = DateTime.utc_now()

    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
      url = "#{Access.base_url()}/repos/#{owner}/#{repo}/issues?state=open&per_page=100"
      active_states = Config.active_states() |> Enum.map(&StatePolicy.normalize_state/1) |> MapSet.new()

      with {:ok, issues} <- fetch_label_issue_pages(request_fun, url, token, owner, repo, prefix, []) do
        record_open_issues(owner, repo, issues, listed_from)
        {:ok, filter_and_authorize_candidates(issues, active_states, request_fun, token, owner, repo, prefix)}
      end
    end
  end

  @doc "Conditionally lists and records every open issue without selecting or authorizing dispatch candidates."
  @spec refresh_open_issues(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh_open_issues(cache, opts \\ []) when is_map(cache) do
    with {:ok, _issues, _ctx, updated_cache} <- list_open_issues_conditional(cache, [caller: "build_queue_open_issue_list"] ++ opts), do: {:ok, updated_cache}
  end

  defp do_fetch_candidate_issues_conditional(cache, opts) do
    with {:ok, issues, ctx, updated_cache} <- list_open_issues_conditional(cache, opts) do
      active_states = Config.active_states() |> Enum.map(&StatePolicy.normalize_state/1) |> MapSet.new()
      {:ok, filter_and_authorize_candidates_with_degenerate(issues, active_states, ctx.request_fun, ctx.token, ctx.owner, ctx.repo, ctx.prefix, cache), updated_cache}
    end
  end

  defp list_open_issues_conditional(cache, opts) do
    listed_from = DateTime.utc_now()

    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      ctx = %{
        request_fun: Keyword.get(opts, :request_fun, &Access.default_request_fun/1),
        token: token,
        owner: owner,
        repo: repo,
        prefix: GitHub.Config.label_prefix(),
        caller: Keyword.get(opts, :caller, "open_issue_list_conditional")
      }

      url = "#{Access.base_url()}/repos/#{owner}/#{repo}/issues?state=open&per_page=100"

      with {:ok, issues, updated_cache} <- fetch_label_issue_pages_conditional(ctx, url, cache) do
        record_open_issues(owner, repo, issues, listed_from)
        {:ok, issues, ctx, updated_cache}
      end
    end
  end

  defp record_open_issues(owner, repo, issues, listed_from), do: OpenIssueListing.record(owner, repo, issues, listed_from)

  defp filter_and_authorize_candidates(issues, active_states, request_fun, token, owner, repo, prefix) do
    dispatchable =
      Enum.filter(issues, fn issue ->
        is_binary(issue.state) and
          MapSet.member?(active_states, StatePolicy.normalize_state(issue.state))
      end)

    authorize_dispatches(dispatchable, request_fun, token, owner, repo, prefix)
  end

  # Keep fresh non-dispatchable workflow states as evidence for next-poll label repair.
  # Only dispatchable candidates go through authorization; terminal tickets remain excluded.
  defp filter_and_authorize_candidates_with_degenerate(issues, active_states, request_fun, token, owner, repo, prefix, cache) do
    {dispatchable, rest} =
      Enum.split_with(issues, fn issue ->
        is_binary(issue.state) and
          MapSet.member?(active_states, StatePolicy.normalize_state(issue.state))
      end)

    authorized = GitHub.CandidateAuthorization.authorize(dispatchable, cache, &authorize_dispatches(&1, request_fun, token, owner, repo, prefix))

    healable =
      rest
      |> StateLabels.filter_candidate_repair_labels(prefix, active_states)
      |> TestTicketScope.filter_issues()

    authorized ++ healable
  end

  @spec fetch_issues_for_each_label(
          [String.t()],
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  defdelegate fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix), to: LabelPages

  @spec reduce_label_issues(
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defdelegate reduce_label_issues(request_fun, url, token, owner, repo, prefix, acc), to: LabelPages

  @spec do_fetch_issues_by_states([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  defdelegate do_fetch_issues_by_states(state_names, opts), to: LabelPages

  @spec do_fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  defdelegate do_fetch_issue_states_by_ids(issue_ids, opts), to: IdList

  @spec do_fetch_issue_states_by_ids_conditional([String.t()], map(), keyword()) ::
          {:ok, [Issue.t()], map()} | {:error, term()} | {:error, term(), map()}
  defdelegate do_fetch_issue_states_by_ids_conditional(issue_ids, cache, opts), to: IdList

  @spec do_list_issues(function(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  defdelegate do_list_issues(request_fun, url, token, owner, repo, prefix), to: LabelPages

  @spec do_fetch_issues_by_id_list(
          [String.t()],
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  defdelegate do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix), to: IdList

  @spec reduce_fetch_issue(
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [Issue.t()]
        ) :: {:cont, {:ok, [Issue.t()]}} | {:halt, {:error, term()}}
  defdelegate reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc), to: IdList

  @spec normalize_issue(map(), String.t(), String.t(), String.t()) :: Issue.t()
  defdelegate normalize_issue(gh_issue, owner, repo, prefix), to: Normalize

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

  Across cycles, the edge list and each blocker's state are served from the
  store while younger than `Aiur.GitHub.BoundedBlockedBy.max_age_ms/0`, and
  re-read unconditionally only once either is older (#2714).

  Returns `{:error, reason}` when the dependency read fails; callers treat that
  as *unknown* blockers and hold dispatch (fail-closed), because dispatching on
  unknown blockers would reintroduce exactly the "dispatches work GitHub knows
  is blocked" defect this gate exists to prevent.
  """
  @spec hydrate_blocked_by(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  defdelegate hydrate_blocked_by(issue), to: Normalize

  @spec hydrate_blocked_by(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  defdelegate hydrate_blocked_by(issue, opts), to: Normalize

  @spec extract_state(map(), [String.t()], String.t()) :: String.t() | nil
  defdelegate extract_state(gh_issue, label_names, prefix), to: Normalize

  @spec extract_state_labels([String.t()], String.t()) :: [String.t()]
  defdelegate extract_state_labels(label_names, prefix), to: Normalize

  @spec extract_priority([String.t()]) :: integer() | nil
  defdelegate extract_priority(label_names), to: Normalize

  @spec parse_priority_label(String.t()) :: integer() | nil
  defdelegate parse_priority_label(name), to: Normalize

  @spec parse_priority_int(String.t()) :: integer() | nil
  defdelegate parse_priority_int(n), to: Normalize

  @spec parse_datetime(String.t() | nil) :: DateTime.t() | nil
  defdelegate parse_datetime(raw), to: Normalize
end
