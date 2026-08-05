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
    ReviewThreads,
    Teams
  }

  alias Aiur.GitHub.CiReadiness

  @spec preflight_auth(keyword()) :: :ok | {:error, term()}
  def preflight_auth(opts \\ []), do: AuthPreflight.preflight_auth(opts)

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

  @spec fetch_open_pull_request_for_branch(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(issue_number, opts \\ []),
    do:
      CycleFetchCache.fetch({:open_pull_request_for_branch, to_string(issue_number)}, fn ->
        PullRequests.fetch_open_pull_request_for_branch(issue_number, opts)
      end)

  @spec fetch_commit_ci_status(String.t(), keyword()) ::
          {:ok, %{check_runs: [map()], commit_status: map()}} | {:error, term()}
  def fetch_commit_ci_status(sha, opts \\ []), do: PullRequests.fetch_commit_ci_status(sha, opts)

  @spec fetch_open_pull_requests_by_label(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests_by_label(label, opts \\ []),
    do: PullRequests.fetch_open_pull_requests_by_label(label, opts)

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
