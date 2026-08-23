defmodule Aiur.GitHub.Client do
  @moduledoc """
  GitHub REST API client for issue tracking via labels.
  """

  alias Aiur.{BuildOrder.GitHubGraph, BuildOrder.ProviderResult, Issue, TrackerIdentity}

  alias Aiur.GitHub.{
    AuthPreflight,
    Comments,
    CycleFetchCache,
    DependenciesApi,
    Errors,
    HumanReviewGate,
    Issues,
    IssueState,
    PullRequests,
    RepoEvents,
    ResourceFetch,
    ResourceStore,
    ReviewThreads,
    Teams,
    Transport
  }

  alias Aiur.GitHub.CiReadiness

  @spec preflight_auth(keyword()) :: :ok | {:error, term()}
  def preflight_auth(opts \\ []), do: AuthPreflight.preflight_auth(opts)

  @spec ensure_preflight(keyword()) :: :ok | {:error, term()}
  def ensure_preflight(opts \\ []), do: AuthPreflight.ensure_preflight(opts)

  @spec check_ci_readiness(keyword()) :: {:ok, CiReadiness.result()} | {:error, term()}
  def check_ci_readiness(opts \\ []), do: CiReadiness.check(opts)

  @spec format_auth_preflight_error(term()) :: String.t()
  def format_auth_preflight_error(reason), do: AuthPreflight.format_auth_preflight_error(reason)

  @type classification :: Errors.classification()

  @doc """
  Classifies a GitHub transport failure or HTTP response into the structured
  error taxonomy `{:github, classification, detail}`.

  Accepts either:

    * `{:error, reason}` — a transport failure, where `reason` is a
      `Req.TransportError`/`Mint.TransportError` (or bare reason). DNS
      (`:nxdomain`) → `:dns`; connectivity (`:timeout`/`:closed`/`:econnrefused`
      …) → `:timeout`; TLS alerts → `:tls`; anything else → `:transport`.
    * an HTTP response map `%{status: ...}` — 401 → `:auth`; a 403 carrying a
      rate-limit signal → `:rate_limited`; any other status → `:http`.

  `detail` is a map (`%{reason: ...}` for transport, `%{status: ...}` for HTTP,
  plus `:retry_after`/`:poll_interval` for rate-limit) so callers can both
  pattern-match the classification and recover the specifics.
  """
  @spec classify_error({:error, term()} | map()) :: {:github, classification(), map()}
  def classify_error(error), do: Errors.classify_error(error)

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []), do: Issues.fetch_candidate_issues(opts)

  @spec fetch_candidate_issues_conditional(map(), keyword()) ::
          {:ok, [Issue.t()], map()} | {:error, term()}
  def fetch_candidate_issues_conditional(cache, opts \\ []),
    do: Issues.fetch_candidate_issues_conditional(cache, opts)

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []), do: Issues.fetch_issues_by_states(state_names, opts)

  @spec fetch_issues_by_states_conditional([String.t()], map(), keyword()) ::
          {:ok, [Issue.t()], map()} | {:error, term()}
  def fetch_issues_by_states_conditional(state_names, cache, opts \\ []) do
    Issues.fetch_issues_by_states_conditional(state_names, cache, opts)
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []), do: Issues.fetch_issue_states_by_ids(issue_ids, opts)

  @spec fetch_issue_states_by_ids_conditional([String.t()], map(), keyword()) ::
          {:ok, [Issue.t()], map()} | {:error, term()} | {:error, term(), map()}
  def fetch_issue_states_by_ids_conditional(issue_ids, cache, opts \\ []) do
    Issues.fetch_issue_states_by_ids_conditional(issue_ids, cache, opts)
  end

  @doc "Fetches a complete, bounded Build Order root catalog without tracker-polling semantics."
  @spec fetch_build_order_catalog(keyword()) ::
          {:ok, ProviderResult.t()} | {:error, ProviderResult.t()}
  def fetch_build_order_catalog(opts \\ []), do: GitHubGraph.fetch_catalog(opts)

  @doc "Fetches one complete, bounded direct-member Build Order graph without mutating GitHub."
  @spec fetch_build_order_selected_root(TrackerIdentity.t(), keyword()) ::
          {:ok, ProviderResult.t()} | {:error, ProviderResult.t()}
  def fetch_build_order_selected_root(root, opts \\ []), do: GitHubGraph.fetch_selected_root(root, opts)

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_number, body, opts \\ []), do: Comments.create_comment(issue_number, body, opts)

  @spec fetch_repo_events(keyword()) ::
          {:ok,
           {:events, [map()], String.t() | nil, pos_integer()}
           | {:not_modified, String.t() | nil, pos_integer()}}
          | {:error, term()}
  def fetch_repo_events(opts \\ []), do: RepoEvents.fetch_repo_events(opts)

  @spec fetch_blocked_by(integer() | String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_blocked_by(issue_number, opts \\ []), do: DependenciesApi.fetch_blocked_by(issue_number, opts)

  @spec fetch_blocking(integer() | String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_blocking(issue_number, opts \\ []), do: DependenciesApi.fetch_blocking(issue_number, opts)

  @doc """
  Hydrates `blocked_by` on a GitHub `Issue.t()` from the native Issue
  Dependencies API. Only meaningful for issues that are actually being
  considered for dispatch (see `Aiur.GitHub.Issues.hydrate_blocked_by/1`).
  """
  @spec hydrate_blocked_by(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def hydrate_blocked_by(issue, opts \\ []), do: Issues.hydrate_blocked_by(issue, opts)

  @spec add_dependency(integer() | String.t(), integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_dependency(blocked_issue_number, blocker_issue_id, opts \\ []),
    do: DependenciesApi.add_dependency(blocked_issue_number, blocker_issue_id, opts)

  @spec remove_dependency(integer() | String.t(), integer(), keyword()) ::
          {:ok, :removed} | {:error, term()}
  def remove_dependency(blocked_issue_number, blocker_issue_id, opts \\ []),
    do: DependenciesApi.remove_dependency(blocked_issue_number, blocker_issue_id, opts)

  @spec fetch_issue_raw(integer() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_issue_raw(issue_number, opts \\ []), do: Issues.fetch_issue_raw(issue_number, opts)

  @spec fetch_team_members(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_team_members(org, team_slug, opts \\ []), do: Teams.fetch_team_members(org, team_slug, opts)

  @spec fetch_pull_request_changed_paths(String.t() | integer(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_pull_request_changed_paths(pr_number, opts \\ []),
    do: PullRequests.fetch_pull_request_changed_paths(pr_number, opts)

  @spec fetch_pull_request_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_pull_request_review_comments(pr_number, opts \\ []),
    do: PullRequests.fetch_pull_request_review_comments(pr_number, opts)

  @spec fetch_pull_request_reviews(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_pull_request_reviews(pr_number, opts \\ []),
    do: PullRequests.fetch_pull_request_reviews(pr_number, opts)

  @spec fetch_pull_request_reviews_conditional(String.t() | integer(), keyword()) ::
          {:ok, [map()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_pull_request_reviews_conditional(pr_number, opts \\ []),
    do: PullRequests.fetch_pull_request_reviews_conditional(pr_number, opts)

  @spec fetch_open_pull_request_for_branch(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(issue_number, opts \\ []) do
    CycleFetchCache.fetch({:open_pull_request_for_branch, to_string(issue_number)}, fn ->
      fetch_open_pull_request_for_branch_stored(issue_number, opts)
    end)
  end

  # The busiest REST call site in the daemon (#2265): the three per-cycle
  # pollers each ask "is there an open pull request for this ticket's branch"
  # once per ticket. Routing through `ResourceFetch` under the dedicated
  # `:branch_pull_request_listing` key makes every repeat read a conditional
  # revalidate — a `304` GitHub does not bill — instead of a full-price listing.
  # The key is deliberately NOT `:branch_pull_request`: that key is the *pull
  # request* resource, written by the webhook deposit and the human-review gate,
  # whose validators describe the PR body (a derived hash, or none) and would
  # clobber or be clobbered by the listing validator those three writers share
  # (#2126). The listing gets its own key so its page-1 validator survives
  # contact. The held result (the found PR, or nil) is served back on `304`,
  # which is the same page-one contract
  # `fetch_open_pull_request_for_branch_conditional/2` documents.
  defp fetch_open_pull_request_for_branch_stored(issue_number, opts) do
    key = ResourceStore.key_for_repo(:branch_pull_request_listing, repo_full_name(opts), issue_number)

    fetcher = fn fetch_opts ->
      PullRequests.fetch_open_pull_request_for_branch_conditional(
        issue_number,
        Keyword.merge(opts,
          etag: Keyword.get(fetch_opts, :etag),
          caller: "open_pull_request_for_branch"
        )
      )
    end

    case ResourceFetch.need(key, fetcher, freshness: ResourceFetch.decision(), reason: "open pull request for branch") do
      {:ok, pull_request, _meta} -> {:ok, pull_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_full_name(opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) and repo != "" ->
        repo

      _other ->
        case Transport.parse_repo() do
          {:ok, {owner, repo}} -> "#{owner}/#{repo}"
          _other -> nil
        end
    end
  end

  @spec fetch_commit_ci_status(String.t(), keyword()) ::
          {:ok, %{check_runs: [map()], commit_status: map()}} | {:error, term()}
  def fetch_commit_ci_status(sha, opts \\ []), do: PullRequests.fetch_commit_ci_status(sha, opts)

  @spec fetch_commit_timestamp(String.t(), keyword()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  def fetch_commit_timestamp(sha, opts \\ []), do: PullRequests.fetch_commit_timestamp(sha, opts)

  @spec fetch_open_pull_requests_by_label(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests_by_label(label, opts \\ []),
    do: PullRequests.fetch_open_pull_requests_by_label(label, opts)

  @spec fetch_open_pull_requests(keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests(opts \\ []),
    do: PullRequests.fetch_open_pull_requests(opts)

  @spec fetch_open_pull_requests_by_label_conditional(String.t(), keyword()) ::
          {:ok, [map()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_open_pull_requests_by_label_conditional(label, opts \\ []),
    do: PullRequests.fetch_open_pull_requests_by_label_conditional(label, opts)

  @spec fetch_recent_repo_review_comments(keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_recent_repo_review_comments(opts \\ []), do: Comments.fetch_recent_repo_review_comments(opts)

  @spec fetch_recent_repo_review_comments_conditional(keyword()) ::
          {:ok, [map()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_recent_repo_review_comments_conditional(opts \\ []), do: Comments.fetch_recent_repo_review_comments_conditional(opts)

  @spec fetch_recent_repo_issue_comments(keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_recent_repo_issue_comments(opts \\ []), do: Comments.fetch_recent_repo_issue_comments(opts)

  @spec fetch_recent_repo_issue_comments_conditional(keyword()) ::
          {:ok, [map()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_recent_repo_issue_comments_conditional(opts \\ []), do: Comments.fetch_recent_repo_issue_comments_conditional(opts)

  @spec fetch_issue_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_number, opts \\ []) do
    CycleFetchCache.fetch({:issue_comments, to_string(issue_number), comment_cursor_key(opts)}, fn ->
      Comments.fetch_issue_comments(issue_number, opts)
    end)
  end

  @spec fetch_issue_comments_conditional(String.t() | integer(), keyword()) ::
          {:ok, [map()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_issue_comments_conditional(issue_number, opts \\ []) do
    CycleFetchCache.fetch({:issue_comments_conditional, to_string(issue_number), comment_cursor_key(opts)}, fn ->
      Comments.fetch_issue_comments_conditional(issue_number, opts)
    end)
  end

  @spec fetch_pull_request_head_ref(String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_pull_request_head_ref(pr_number, opts \\ []),
    do: PullRequests.fetch_pull_request_head_ref(pr_number, opts)

  @spec fetch_open_pull_request(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request(pr_number, opts \\ []),
    do: PullRequests.fetch_open_pull_request(pr_number, opts)

  @spec ensure_pull_request_base(map(), String.t(), keyword()) ::
          {:ok, :unchanged | {:repaired, String.t()}} | {:error, term()}
  def ensure_pull_request_base(pr, expected_base, opts \\ []),
    do: PullRequests.ensure_base_branch(pr, expected_base, opts)

  @spec fetch_classified_pr_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(pr_number, opts \\ []),
    do: PullRequests.fetch_classified_pr_review_comments(pr_number, opts)

  @spec fetch_unaddressed_pr_review_thread_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_unaddressed_pr_review_thread_comments(pr_number, opts \\ []) do
    CycleFetchCache.fetch({:review_thread_comments, to_string(pr_number)}, fn ->
      ReviewThreads.fetch_unaddressed_pr_review_thread_comments(pr_number, opts)
    end)
  end

  defp comment_cursor_key(opts), do: {Keyword.get(opts, :since), Keyword.get(opts, :etag)}

  @spec reply_to_review_thread(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reply_to_review_thread(review_thread_id, body, opts \\ []),
    do: ReviewThreads.Reply.reply_to_review_thread(review_thread_id, body, opts)

  @spec resolve_review_thread(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_review_thread(review_thread_id, opts \\ []),
    do: ReviewThreads.Resolution.resolve_review_thread(review_thread_id, opts)

  @spec verify_human_review_ready(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  def verify_human_review_ready(issue_number, opts \\ []),
    do: HumanReviewGate.verify_human_review_ready(issue_number, opts)

  @spec fetch_classified_issue_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_issue_comments(issue_number, opts \\ []),
    do: Comments.fetch_classified_issue_comments(issue_number, opts)

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_number, state_name, opts \\ [])
      when is_binary(issue_number) and is_binary(state_name),
      do: IssueState.update_issue_state(issue_number, state_name, opts)

  @spec add_label(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def add_label(issue_number, label, opts \\ [])
      when is_binary(issue_number) and is_binary(label),
      do: IssueState.add_label(issue_number, label, opts)

  @spec remove_label(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove_label(issue_number, label, opts \\ [])
      when is_binary(issue_number) and is_binary(label),
      do: IssueState.remove_label(issue_number, label, opts)
end
