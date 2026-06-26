defmodule Aiur.GitHub.Client do
  @moduledoc """
  GitHub REST API client for issue tracking via labels.
  """

  require Logger
  alias Aiur.{Codeowners, Config, GitHub, Issue}

  @base_url "https://api.github.com"
  @graphql_url "#{@base_url}/graphql"

  @reply_review_thread_mutation """
  mutation AiurReplyReviewThread($threadId: ID!, $body: String!) {
    addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
      comment {
        id
        databaseId
        body
        createdAt
        updatedAt
        url
        author {
          login
        }
      }
    }
  }
  """

  @resolve_review_thread_mutation """
  mutation AiurResolveReviewThread($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread {
        id
        isResolved
      }
    }
  }
  """

  @review_thread_query """
  query AiurReviewThread($id: ID!) {
    node(id: $id) {
      ... on PullRequestReviewThread {
        id
        isResolved
        path
        line
        comments(last: 20) {
          nodes {
            id
            databaseId
            body
            createdAt
            updatedAt
            url
            author {
              login
            }
          }
        }
      }
    }
  }
  """

  @viewer_login_query """
  query AiurViewerLogin {
    viewer {
      login
    }
  }
  """

  @unaddressed_review_threads_query """
  query AiurUnaddressedReviewThreads($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            isResolved
            path
            line
            comments(last: 20) {
              nodes {
                databaseId
                body
                createdAt
                updatedAt
                url
                author {
                  login
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @spec preflight_auth(keyword()) :: :ok | {:error, term()}
  def preflight_auth(opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      gh_auth_status_fun = Keyword.get(opts, :gh_auth_status_fun, &default_gh_auth_status_fun/0)

      owner
      |> preflight_checks(repo)
      |> run_preflight_checks(request_fun, token, owner, repo)
      |> finalize_preflight_result(gh_auth_status_fun)
    end
  end

  defp finalize_preflight_result(result, gh_auth_status_fun) do
    case result do
      :ok ->
        :ok

      {:error, diagnostic} ->
        {:error, {:github_auth_preflight_failed, enrich_auth_diagnostic(diagnostic, gh_auth_status_fun)}}
    end
  end

  @spec format_auth_preflight_error(term()) :: String.t()
  def format_auth_preflight_error({:github_auth_preflight_failed, diagnostic})
      when is_map(diagnostic) do
    Map.get(diagnostic, :message) || Map.get(diagnostic, "message") || inspect(diagnostic)
  end

  def format_auth_preflight_error(reason), do: inspect(reason)

  @typedoc """
  The error classification produced by `classify_error/1`. Operators must be
  able to tell these apart to fix flaky GitHub access (#617): a DNS outage and
  an expired token need entirely different remediation.
  """
  @type classification ::
          :dns | :timeout | :tls | :transport | :auth | :rate_limited | :http

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
  def classify_error({:error, reason}), do: classify_transport(reason)

  def classify_error(%{status: status} = response) when is_integer(status) do
    classify_status(status, response)
  end

  defp classify_transport(%{__struct__: struct, reason: reason})
       when struct in [Req.TransportError, Mint.TransportError] do
    classify_transport_reason(reason)
  end

  defp classify_transport(reason), do: classify_transport_reason(reason)

  defp classify_transport_reason(:nxdomain), do: {:github, :dns, %{reason: :nxdomain}}

  defp classify_transport_reason(reason)
       when reason in [:timeout, :closed, :econnrefused, :ehostunreach, :enetunreach, :econnreset],
       do: {:github, :timeout, %{reason: reason}}

  defp classify_transport_reason(reason)
       when reason in [:protocol_not_negotiated],
       do: {:github, :tls, %{reason: reason}}

  defp classify_transport_reason({tag, _} = reason)
       when tag in [:tls_alert, :bad_alpn_protocol, :ssl_error],
       do: {:github, :tls, %{reason: reason}}

  defp classify_transport_reason(reason), do: {:github, :transport, %{reason: reason}}

  defp classify_status(401, response),
    do: {:github, :auth, %{status: 401, message: response_message(response)}}

  defp classify_status(403, response) do
    if rate_limited_response?(response, :unknown) do
      {:github, :rate_limited,
       %{
         status: 403,
         retry_after: retry_after(response),
         poll_interval: rate_limit_poll_interval(response)
       }}
    else
      {:github, :http, %{status: 403}}
    end
  end

  defp classify_status(429, response) do
    {:github, :rate_limited,
     %{
       status: 429,
       retry_after: retry_after(response),
       poll_interval: rate_limit_poll_interval(response)
     }}
  end

  defp classify_status(status, _response), do: {:github, :http, %{status: status}}

  defp github_status_error(%{status: status} = response) do
    if rate_limited_response?(response, :unknown) do
      classify_error(response)
    else
      {:github_api_status, status}
    end
  end

  defp response_message(%{body: %{"message" => message}}) when is_binary(message), do: message
  defp response_message(_response), do: nil

  defp retry_after(%{headers: headers}) do
    case header(headers, "retry-after") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp retry_after(_response), do: nil

  defp rate_limit_poll_interval(%{headers: headers}) do
    case header(headers, "x-poll-interval") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp rate_limit_poll_interval(_response), do: nil

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    fetch_issues_by_states(Config.active_states(), opts)
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    if state_names == [], do: {:ok, []}, else: do_fetch_issues_by_states(state_names, opts)
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    if issue_ids == [], do: {:ok, []}, else: do_fetch_issue_states_by_ids(issue_ids, opts)
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_number, body, opts \\ [])
      when is_binary(issue_number) and is_binary(body) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"

      case request_fun.(%{method: :post, url: url, token: token, body: %{"body" => body}}) do
        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: status}} ->
          Logger.error("GitHub create_comment failed status=#{status}")
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, classify_error({:error, reason})}
      end
    end
  end

  @doc """
  Fetches `/repos/{owner}/{repo}/events` (the GitHub firehose for the
  current repo). Honors `If-None-Match` via the optional `etag:` option,
  and the `X-Poll-Interval` response header for next-poll scheduling.

  Returns:

    * `{:ok, {:not_modified, etag, poll_interval}}` on 304
    * `{:ok, {:events, list, etag, poll_interval}}` on 200
    * `{:error, reason}` on transport or 4xx/5xx errors

  `poll_interval` is in seconds, defaulting to 60 when GitHub omits the
  header.

  Options:

    * `:page` — GitHub events page to fetch, defaulting to 1
    * `:per_page` — events per page, defaulting to 30
  """
  @spec fetch_repo_events(keyword()) ::
          {:ok,
           {:events, [map()], String.t() | nil, pos_integer()}
           | {:not_modified, String.t() | nil, pos_integer()}}
          | {:error, term()}
  def fetch_repo_events(opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      etag = Keyword.get(opts, :etag)
      page = Keyword.get(opts, :page, 1)
      per_page = Keyword.get(opts, :per_page, 30)

      query = URI.encode_query(%{"page" => page, "per_page" => per_page})
      url = "#{@base_url}/repos/#{owner}/#{repo}/events?#{query}"

      case request_fun.(%{
             method: :get,
             url: url,
             token: token,
             etag: etag
           }) do
        {:ok, %{status: 304, headers: headers}} ->
          {:ok, {:not_modified, header(headers, "etag") || etag, poll_interval(headers)}}

        {:ok, %{status: 200, headers: headers, body: body}} when is_list(body) ->
          # Mirror the 304 path: preserve the prior etag if GitHub
          # omits the response header (rare but observed behind some
          # caching proxies). Dropping it would force a non-conditional
          # GET on the next poll, re-translating the same page of events.
          {:ok, {:events, body, header(headers, "etag") || etag, poll_interval(headers)}}

        {:ok, %{status: _status} = response} ->
          {:error, github_status_error(response)}

        {:error, reason} ->
          {:error, classify_error({:error, reason})}
      end
    end
  end

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
          {:ok, map()} | {:error, term()}
  def remove_dependency(blocked_issue_number, blocker_issue_id, opts \\ [])
      when is_integer(blocker_issue_id) do
    dependency_mutate(blocked_issue_number, blocker_issue_id, :delete, opts)
  end

  @doc """
  Fetches the raw GitHub issue body by number (not the Aiur-normalized
  shape). Used by `Aiur.GitHub.IssueDependencies` to resolve a blocker's
  numeric `id` (required by the Dependencies REST API).
  """
  @spec fetch_issue_raw(integer() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_issue_raw(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
        {:error, reason} -> {:error, classify_error({:error, reason})}
      end
    end
  end

  @doc """
  Lists the logins of every member of `team_slug` inside `org`. Used by
  `Aiur.GitHub.CodeOwners` to expand `@org/team` entries.

  Requires the GitHub token to have `read:org` scope; 403 is returned
  otherwise and the caller logs + falls back.
  """
  @spec fetch_team_members(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_team_members(org, team_slug, opts \\ []) do
    with {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/orgs/#{org}/teams/#{team_slug}/members?per_page=100"
      fetch_member_logins(request_fun, token, url, [])
    end
  end

  defp fetch_member_logins(_request_fun, _token, nil, acc), do: {:ok, acc}

  defp fetch_member_logins(request_fun, token, url, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        new_logins = Enum.flat_map(body, &member_login_list/1)
        next = parse_next_page_url(headers)
        fetch_member_logins(request_fun, token, next, acc ++ new_logins)

      {:ok, %{status: _status} = response} ->
        {:error, github_status_error(response)}

      {:error, reason} ->
        {:error, classify_error({:error, reason})}
    end
  end

  defp member_login_list(%{"login" => login}) when is_binary(login), do: [login]
  defp member_login_list(_), do: []

  defp parse_next_page_url(headers) do
    case header(headers, "link") do
      value when is_binary(value) ->
        Regex.run(~r/<([^>]+)>;\s*rel="next"/, value)
        |> case do
          [_, next_url] -> next_url
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec fetch_pull_request_changed_paths(String.t() | integer(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_pull_request_changed_paths(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls/#{pr_number}/files?per_page=100"

      case fetch_json_list(request_fun, token, url) do
        {:ok, files} ->
          {:ok, files |> Enum.map(&Map.get(&1, "filename")) |> Enum.reject(&is_nil/1)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @spec fetch_pull_request_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_pull_request_review_comments(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      query = comment_query(opts)
      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls/#{pr_number}/comments?#{query}"

      fetch_json_list(request_fun, token, url)
    end
  end

  @doc """
  Fetches the open pull request whose head branch is the canonical Aiur
  branch for `issue_number` (`<owner>:aiur/<issue_number>`).
  """
  @spec fetch_open_pull_request_for_branch(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)

      query =
        URI.encode_query(%{
          "state" => "open",
          "head" => "#{owner}:aiur/#{issue_number}",
          "per_page" => "10"
        })

      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls?#{query}"

      case fetch_json_list(request_fun, token, url) do
        {:ok, [first | _]} -> {:ok, first}
        {:ok, []} -> {:ok, nil}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Fetches the OPEN pull requests carrying `label` (e.g. `"agent:watch"`),
  repo-wide, for opt-in PR comment watching.

  Lists open PRs (`GET /pulls?state=open`) — which return full PR objects
  including `number`, `head.ref`, and `labels` — and filters by label name
  client-side, since the `/pulls` endpoint does not support a server-side
  label filter. Each returned PR map carries at least the PR number and head
  ref so the comment poller can key on the PR number and skip
  `fetch_open_pull_request_for_branch/2` (no branch derivation for watched PRs).
  """
  @spec fetch_open_pull_requests_by_label(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests_by_label(label, opts \\ []) when is_binary(label) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      query = URI.encode_query(%{"state" => "open", "per_page" => "100"})
      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls?#{query}"
      fetch_labeled_open_pull_requests(request_fun, token, url, label, [])
    end
  end

  # Follows the GitHub `Link` `rel="next"` pagination (mirrors
  # `fetch_member_logins/4`) so a repo with more than 100 open PRs cannot
  # silently hide a watched PR past the first page — silent truncation here
  # would drop a watched PR's comments, the exact failure this feature prevents.
  defp fetch_labeled_open_pull_requests(_request_fun, _token, nil, _label, acc), do: {:ok, acc}

  defp fetch_labeled_open_pull_requests(request_fun, token, url, label, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        matched = Enum.filter(body, &pull_request_has_label?(&1, label))
        next = parse_next_page_url(headers)
        fetch_labeled_open_pull_requests(request_fun, token, next, label, acc ++ matched)

      {:ok, %{status: _status} = response} ->
        {:error, github_status_error(response)}

      {:error, reason} ->
        {:error, classify_error({:error, reason})}
    end
  end

  defp pull_request_has_label?(%{"labels" => labels}, label) when is_list(labels) do
    Enum.any?(labels, fn
      %{"name" => name} when is_binary(name) -> name == label
      name when is_binary(name) -> name == label
      _ -> false
    end)
  end

  defp pull_request_has_label?(_pull_request, _label), do: false

  @doc """
  Fetches recent PR REVIEW (line) comments across ALL pull requests in the
  repo, for the per-comment command scan (the one-off `/aiur`/bot-mention
  trigger).

  Lists `GET /repos/{owner}/{repo}/pulls/comments?sort=updated&direction=desc`
  with a `since` cursor (`:since`). This is a repo-wide comment STREAM, not a
  per-PR fetch — a `/aiur` left as a review comment does NOT reliably bump the
  PR's `updated_at`, so scanning by PR freshness would silently miss it; the
  comment stream surfaces it directly. Each review comment carries
  `pull_request_url` so the caller can derive the PR number. Paginates the
  `Link` `rel="next"` header (like `fetch_labeled_open_pull_requests/5`) so a
  burst within one cursor window cannot silently truncate.
  """
  @spec fetch_recent_repo_review_comments(keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_recent_repo_review_comments(opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      query = repo_comment_stream_query(opts)
      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls/comments?#{query}"
      fetch_repo_comment_stream(request_fun, token, url, [])
    end
  end

  @doc """
  Fetches recent ISSUE/PR-conversation comments across ALL issues and PRs in
  the repo, for the per-comment command scan.

  Lists `GET /repos/{owner}/{repo}/issues/comments?sort=updated&direction=desc`
  with a `since` cursor (`:since`). The endpoint returns comments for both
  plain issues and PR conversations; the caller filters to PR comments (the
  `html_url` contains `/pull/`) and derives the PR number from `issue_url`.
  Paginates the `Link` `rel="next"` header so a burst within one cursor window
  cannot silently truncate.
  """
  @spec fetch_recent_repo_issue_comments(keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_recent_repo_issue_comments(opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      query = repo_comment_stream_query(opts)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/comments?#{query}"
      fetch_repo_comment_stream(request_fun, token, url, [])
    end
  end

  defp repo_comment_stream_query(opts) do
    %{"sort" => "updated", "direction" => "desc", "per_page" => "100"}
    |> maybe_put_query("since", Keyword.get(opts, :since))
    |> URI.encode_query()
  end

  defp fetch_repo_comment_stream(_request_fun, _token, nil, acc), do: {:ok, acc}

  defp fetch_repo_comment_stream(request_fun, token, url, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        next = parse_next_page_url(headers)
        fetch_repo_comment_stream(request_fun, token, next, acc ++ body)

      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, acc ++ body}

      {:ok, %{status: _status} = response} ->
        {:error, github_status_error(response)}

      {:error, reason} ->
        {:error, classify_error({:error, reason})}
    end
  end

  @doc """
  Fetches raw issue conversation comments for one issue or PR conversation.
  """
  @spec fetch_issue_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      query = comment_query(opts)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments?#{query}"

      fetch_json_list(request_fun, token, url)
    end
  end

  @doc """
  Fetches a pull request's head branch ref (e.g. `"aiur/7"`) by number.
  Used by `Aiur.Events.GithubFirehose` to resolve a PR-conversation
  comment (which GitHub fires as an `IssueCommentEvent` keyed by the PR's
  number) back to its originating ticket id.
  """
  @spec fetch_pull_request_head_ref(String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_pull_request_head_ref(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls/#{pr_number}"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: %{"head" => %{"ref" => ref}}}} when is_binary(ref) ->
          {:ok, ref}

        {:ok, %{status: 200}} ->
          {:error, :head_ref_missing}

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, classify_error({:error, reason})}
      end
    end
  end

  @doc """
  Fetches the OPEN pull request numbered `pr_number` (`GET /pulls/{pr_number}`),
  for PR-anchored routing of watched/commanded PR comments.

  Returns `{:ok, pr_map}` for an open PR (the map carries `number`, `head.ref`,
  `title`, `body`, `state`), `{:ok, nil}` when the number is NOT an open PR — a
  404 (the number is a plain issue) or a closed/merged PR — and `{:error, _}`
  otherwise. The `{:ok, nil}` result is the safe signal that the comment must
  fall through to the legacy reactivation path (a tracker issue, not a human PR).
  """
  @spec fetch_open_pull_request(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls/#{pr_number}"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: %{} = pr}} ->
          {:ok, open_pull_request_or_nil(pr)}

        {:ok, %{status: 404}} ->
          {:ok, nil}

        {:ok, %{status: _status} = response} ->
          {:error, github_status_error(response)}

        {:error, reason} ->
          {:error, classify_error({:error, reason})}
      end
    end
  end

  # Treat a closed/merged PR the same as a missing one (nil) so the caller
  # routes its comment through the unchanged legacy path rather than dispatching
  # a PR-anchored agent onto a dead branch.
  defp open_pull_request_or_nil(%{"state" => "open"} = pr), do: pr
  defp open_pull_request_or_nil(%{"state" => state}) when is_binary(state), do: nil
  defp open_pull_request_or_nil(pr) when is_map(pr), do: pr

  @spec fetch_classified_pr_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(pr_number, opts \\ []) do
    with {:ok, paths} <- fetch_pull_request_changed_paths(pr_number, opts),
         {:ok, comments} <- fetch_pull_request_review_comments(pr_number, opts) do
      context = Codeowners.ownership_for_paths(paths, opts)
      {:ok, Enum.map(comments, &Codeowners.classify_comment(&1, context, opts))}
    end
  end

  @spec fetch_unaddressed_pr_review_thread_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_unaddressed_pr_review_thread_comments(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token(opts),
         {:ok, number} <- normalize_pr_number(pr_number) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)

      fetch_unaddressed_review_thread_pages(
        request_fun,
        token,
        owner,
        repo,
        number,
        nil,
        opts,
        []
      )
    end
  end

  @spec reply_to_review_thread(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reply_to_review_thread(review_thread_id, body, opts \\ []) do
    with {:ok, thread_id} <- normalize_review_thread_id(review_thread_id),
         {:ok, body} <- normalize_review_thread_reply_body(body),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      attempts = normalize_positive_integer(Keyword.get(opts, :attempts), 3)

      do_reply_to_review_thread(request_fun, token, thread_id, body, attempts, opts, 1)
    end
  end

  @spec resolve_review_thread(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_review_thread(review_thread_id, opts \\ []) do
    with {:ok, thread_id} <- normalize_review_thread_id(review_thread_id),
         {:ok, terminal_reply_body} <-
           normalize_review_thread_terminal_reply_body(Keyword.get(opts, :terminal_reply_body)),
         {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      do_resolve_review_thread(request_fun, token, thread_id, terminal_reply_body, opts)
    end
  end

  @spec verify_human_review_ready(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  def verify_human_review_ready(issue_number, opts \\ []) do
    with {:ok, token} <- require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)

      context = %{
        issue_number: to_string(issue_number),
        request_fun: request_fun,
        token: token,
        opts: opts
      }

      verify_issue_review_threads_clear(context)
    end
  end

  @spec fetch_classified_issue_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_issue_comments(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments?per_page=100"
      context = Codeowners.repo_ownership(opts)

      case fetch_json_list(request_fun, token, url) do
        {:ok, comments} ->
          {:ok, Enum.map(comments, &Codeowners.classify_comment(&1, context, opts))}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_number, state_name, opts \\ [])
      when is_binary(issue_number) and is_binary(state_name) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      issue_url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}"

      update_context = %{
        request_fun: request_fun,
        token: token,
        issue_url: issue_url,
        owner: owner,
        repo: repo,
        issue_number: issue_number,
        prefix: prefix,
        opts: opts
      }

      do_update_issue_state(update_context, state_name)
    end
  end

  @spec add_label(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def add_label(issue_number, label, opts \\ [])
      when is_binary(issue_number) and is_binary(label) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"

      case request_fun.(%{method: :post, url: url, token: token, body: %{"labels" => [label]}}) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
        {:error, reason} -> {:error, classify_error({:error, reason})}
      end
    end
  end

  @spec remove_label(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove_label(issue_number, label, opts \\ [])
      when is_binary(issue_number) and is_binary(label) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)

      url =
        "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

      case request_fun.(%{method: :delete, url: url, token: token}) do
        # 404 = label already absent; treat as success so the toggle is idempotent.
        {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
        {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
        {:error, reason} -> {:error, classify_error({:error, reason})}
      end
    end
  end

  # -- Private helpers --------------------------------------------------------

  defp preflight_checks(owner, repo) do
    [
      %{endpoint: :rate_limit, url: "#{@base_url}/rate_limit"},
      %{endpoint: :repository, url: "#{@base_url}/repos/#{owner}/#{repo}"},
      %{
        endpoint: :issues,
        url: "#{@base_url}/repos/#{owner}/#{repo}/issues?state=open&per_page=1"
      }
    ]
  end

  defp run_preflight_checks(checks, request_fun, token, owner, repo) do
    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case run_preflight_check(check, request_fun, token, owner, repo) do
        :ok -> {:cont, :ok}
        {:error, diagnostic} -> {:halt, {:error, diagnostic}}
      end
    end)
  end

  defp run_preflight_check(%{endpoint: endpoint, url: url}, request_fun, token, owner, repo) do
    request = %{method: :get, url: url, token: token, preflight?: true}

    case request_fun.(request) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        if rate_limited_response?(response, endpoint) do
          {:error, auth_diagnostic(:rate_limited, endpoint, status, response, owner, repo)}
        else
          :ok
        end

      {:ok, %{status: status} = response} ->
        {:error,
         auth_diagnostic(
           auth_failure_reason(status, response),
           endpoint,
           status,
           response,
           owner,
           repo
         )}

      {:error, reason} ->
        {:error,
         %{
           reason: :request_failed,
           endpoint: endpoint,
           repo: "#{owner}/#{repo}",
           token_source: "GITHUB_TOKEN",
           request_error: inspect(reason)
         }}
    end
  end

  defp auth_diagnostic(reason, endpoint, status, response, owner, repo) do
    %{
      reason: reason,
      endpoint: endpoint,
      repo: "#{owner}/#{repo}",
      token_source: "GITHUB_TOKEN",
      status: status,
      rate_limit_remaining: rate_limit_remaining(response),
      rate_limit_reset: rate_limit_reset(response)
    }
  end

  defp auth_failure_reason(401, _response), do: :invalid_or_expired_token
  defp auth_failure_reason(404, _response), do: :repo_not_accessible

  defp auth_failure_reason(403, response) do
    if rate_limited_response?(response, :unknown), do: :rate_limited, else: :forbidden
  end

  defp auth_failure_reason(_status, _response), do: :http_status

  defp enrich_auth_diagnostic(diagnostic, gh_auth_status_fun) do
    gh_status = safe_gh_auth_status(gh_auth_status_fun)

    diagnostic
    |> Map.put(:gh_keyring_status, gh_status)
    |> Map.put(:message, diagnostic_message(diagnostic, gh_status))
  end

  defp safe_gh_auth_status(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, status} -> status
      status when status in [:available, :unavailable, :not_installed] -> status
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp diagnostic_message(diagnostic, gh_status) do
    repo = diagnostic.repo
    endpoint = diagnostic.endpoint
    source = diagnostic.token_source
    reason = human_auth_reason(diagnostic)
    keyring = human_gh_keyring_status(gh_status)

    [
      "GitHub auth preflight failed for #{source} while validating #{repo} #{endpoint} access: #{reason}.",
      "Aiur uses GITHUB_TOKEN for GitHub tracker/API calls, and that environment token takes precedence over `gh` keyring auth.",
      keyring,
      "Recovery: refresh or unset GITHUB_TOKEN in the shell or .env used to launch aiur, restart aiur so the daemon inherits the fixed environment, then verify `gh api rate_limit` and `gh api repos/#{repo}/issues?per_page=1` without printing token material."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp human_auth_reason(%{reason: :invalid_or_expired_token, status: status}),
    do: "GitHub returned HTTP #{status}, which usually means the token is invalid or expired"

  defp human_auth_reason(%{
         reason: :rate_limited,
         status: status,
         rate_limit_remaining: 0,
         rate_limit_reset: reset
       }),
       do: "GitHub returned HTTP #{status} and the REST rate limit is exhausted#{reset_suffix(reset)}"

  defp human_auth_reason(%{reason: :rate_limited, status: status}),
    do: "GitHub returned HTTP #{status} with a rate-limit response"

  defp human_auth_reason(%{reason: :forbidden, status: status}),
    do: "GitHub returned HTTP #{status}, which usually means missing repository permissions or a secondary rate limit"

  defp human_auth_reason(%{reason: :repo_not_accessible, status: status}),
    do: "GitHub returned HTTP #{status}, so the token cannot access the configured repository or github.repo is wrong"

  defp human_auth_reason(%{reason: :request_failed, request_error: error}),
    do: "the request failed before GitHub returned a status (#{error})"

  defp human_auth_reason(%{status: status}), do: "GitHub returned HTTP #{status}"
  defp human_auth_reason(_diagnostic), do: "GitHub auth check failed"

  defp reset_suffix(nil), do: ""
  defp reset_suffix(reset), do: " until #{reset}"

  defp human_gh_keyring_status(:available),
    do: "`gh` keyring auth appears usable when GITHUB_TOKEN is removed, but Aiur will not use it while GITHUB_TOKEN is set."

  defp human_gh_keyring_status(:unavailable),
    do: "`gh` keyring auth was not usable when checked without GITHUB_TOKEN."

  defp human_gh_keyring_status(:not_installed),
    do: "`gh` is not installed or not on PATH, so only GITHUB_TOKEN can be validated."

  defp human_gh_keyring_status(_), do: "`gh` keyring auth status could not be determined."

  defp rate_limited_response?(response, endpoint) do
    Map.get(response, :status) == 429 or
      rate_limit_remaining(response) == 0 or
      (endpoint == :rate_limit and rate_limit_body_remaining(response) == 0) or
      rate_limit_message?(Map.get(response, :body))
  end

  defp rate_limit_remaining(%{headers: headers}) do
    case header(headers, "x-ratelimit-remaining") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} -> n
          _ -> nil
        end

      value when is_integer(value) ->
        value

      _ ->
        nil
    end
  end

  defp rate_limit_remaining(_response), do: nil

  defp rate_limit_reset(%{headers: headers}) do
    with value when is_binary(value) <- header(headers, "x-ratelimit-reset"),
         {unix, _} <- Integer.parse(value),
         {:ok, dt} <- DateTime.from_unix(unix) do
      DateTime.to_iso8601(dt)
    else
      _ -> nil
    end
  end

  defp rate_limit_reset(_response), do: nil

  defp rate_limit_body_remaining(%{
         body: %{"resources" => %{"core" => %{"remaining" => remaining}}}
       })
       when is_integer(remaining),
       do: remaining

  defp rate_limit_body_remaining(%{body: %{"rate" => %{"remaining" => remaining}}})
       when is_integer(remaining),
       do: remaining

  defp rate_limit_body_remaining(_response), do: nil

  defp rate_limit_message?(%{"message" => message}) when is_binary(message) do
    message
    |> String.downcase()
    |> String.contains?("rate limit")
  end

  defp rate_limit_message?(_body), do: false

  # GitHub labels query is AND (all labels must match), so we fetch each label
  # separately and deduplicate by issue id.
  defp fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix) do
    Enum.reduce_while(labels, {:ok, %{}}, fn label, {:ok, acc} ->
      url =
        "#{@base_url}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(label)}&state=open&per_page=100"

      reduce_label_issues(request_fun, url, token, owner, repo, prefix, acc)
    end)
    |> case do
      {:ok, map} -> {:ok, Map.values(map)}
      error -> error
    end
  end

  defp reduce_label_issues(request_fun, url, token, owner, repo, prefix, acc) do
    case do_list_issues(request_fun, url, token, owner, repo, prefix) do
      {:ok, issues} ->
        merged = Map.merge(acc, Map.new(issues, &{&1.id, &1}), fn _k, v, _new -> v end)
        {:cont, {:ok, merged}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp do_fetch_issues_by_states(state_names, opts) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      labels = Enum.map(state_names, &"#{prefix}:#{normalize_state(&1)}")

      fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix)
    end
  end

  defp do_fetch_issue_states_by_ids(issue_ids, opts) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)

      do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix)
    end
  end

  defp do_list_issues(request_fun, url, token, owner, repo, prefix) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, Enum.map(body, &normalize_issue(&1, owner, repo, prefix))}

      {:ok, %{status: status}} ->
        Logger.error("GitHub API request failed status=#{status}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")
        {:error, classify_error({:error, reason})}
    end
  end

  defp do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix) do
    result =
      Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, acc} ->
        url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_id}"
        reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc)
      end)

    case result do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:cont, {:ok, [normalize_issue(body, owner, repo, prefix) | acc]}}

      {:ok, %{status: 404}} ->
        {:cont, {:ok, acc}}

      {:ok, %{status: status}} ->
        {:halt, {:error, {:github_api_status, status}}}

      {:error, reason} ->
        {:halt, {:error, classify_error({:error, reason})}}
    end
  end

  defp fetch_json_list(request_fun, token, url) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: _status} = response} ->
        {:error, github_status_error(response)}

      {:error, reason} ->
        {:error, classify_error({:error, reason})}
    end
  end

  defp comment_query(opts) do
    %{"per_page" => Keyword.get(opts, :per_page, 100), "page" => Keyword.get(opts, :page, 1)}
    |> maybe_put_query("since", Keyword.get(opts, :since))
    |> URI.encode_query()
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp normalize_pr_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  defp normalize_pr_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, {:invalid_pr_number, number}}
    end
  end

  defp normalize_pr_number(number), do: {:error, {:invalid_pr_number, number}}

  defp fetch_unaddressed_review_thread_pages(
         request_fun,
         token,
         owner,
         repo,
         number,
         cursor,
         opts,
         acc
       ) do
    variables =
      %{"owner" => owner, "repo" => repo, "number" => number}
      |> maybe_put_query("cursor", cursor)

    case github_graphql(request_fun, token, @unaddressed_review_threads_query, variables) do
      {:ok, body} ->
        with {:ok, {threads, page_info}} <- review_threads_page(body) do
          comments = unaddressed_thread_comments(threads, opts)

          continue_unaddressed_review_thread_pages(
            request_fun,
            token,
            owner,
            repo,
            number,
            page_info,
            opts,
            acc ++ comments
          )
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp continue_unaddressed_review_thread_pages(
         request_fun,
         token,
         owner,
         repo,
         number,
         page_info,
         opts,
         acc
       ) do
    if Map.get(page_info, "hasNextPage") == true do
      fetch_unaddressed_review_thread_pages(
        request_fun,
        token,
        owner,
        repo,
        number,
        Map.get(page_info, "endCursor"),
        opts,
        acc
      )
    else
      {:ok, acc}
    end
  end

  defp do_reply_to_review_thread(request_fun, token, thread_id, body, max_attempts, opts, attempt) do
    case add_review_thread_reply(request_fun, token, thread_id, body) do
      {:ok, mutation_body} ->
        Logger.info("GitHub review thread reply mutation response: #{inspect(mutation_body)}")

        build_review_thread_retry_context(
          request_fun,
          token,
          thread_id,
          body,
          max_attempts,
          opts,
          mutation_body
        )
        |> verify_after_review_thread_reply(attempt)

      {:error, reason} ->
        Logger.warning("GitHub review thread reply mutation failed: #{inspect(reason)}")

        if retryable_github_error?(reason) and attempt < max_attempts do
          sleep_review_thread_retry(opts, attempt)

          do_reply_to_review_thread(
            request_fun,
            token,
            thread_id,
            body,
            max_attempts,
            opts,
            attempt + 1
          )
        else
          {:error, reason}
        end
    end
  end

  defp retry_review_thread_reply(context, attempt, reason) do
    if retryable_review_thread_verification_error?(reason) and attempt < context.max_attempts do
      sleep_review_thread_retry(context.opts, attempt)

      verify_after_review_thread_reply(context, attempt + 1)
    else
      {:error,
       {:review_thread_reply_not_verified,
        %{
          review_thread_id: context.thread_id,
          attempts: attempt,
          reason: reason,
          mutation_response: context.mutation_body
        }}}
    end
  end

  defp verify_after_review_thread_reply(context, attempt) do
    case verify_review_thread_reply(
           context.request_fun,
           context.token,
           context.thread_id,
           context.body,
           context.opts
         ) do
      {:ok, verification} ->
        {:ok,
         %{
           verified: true,
           review_thread_id: context.thread_id,
           attempt: attempt,
           mutation_response: context.mutation_body,
           verification: verification
         }}

      {:error, reason} ->
        retry_review_thread_reply(context, attempt, reason)
    end
  end

  defp build_review_thread_retry_context(
         request_fun,
         token,
         thread_id,
         body,
         max_attempts,
         opts,
         mutation_body
       ) do
    %{
      request_fun: request_fun,
      token: token,
      thread_id: thread_id,
      body: body,
      max_attempts: max_attempts,
      opts: opts,
      mutation_body: mutation_body
    }
  end

  defp add_review_thread_reply(request_fun, token, thread_id, body) do
    github_graphql(request_fun, token, @reply_review_thread_mutation, %{
      "threadId" => thread_id,
      "body" => body
    })
  end

  defp do_resolve_review_thread(request_fun, token, thread_id, terminal_reply_body, opts) do
    with {:ok, verification} <-
           verify_review_thread_resolution_ready(
             request_fun,
             token,
             thread_id,
             terminal_reply_body,
             opts
           ),
         {:ok, body} <- resolve_review_thread_mutation(request_fun, token, thread_id) do
      Logger.info("GitHub review thread resolve mutation response: #{inspect(body)}")
      verify_resolved_review_thread(body, thread_id, verification)
    end
  end

  defp resolve_review_thread_mutation(request_fun, token, thread_id) do
    case github_graphql(request_fun, token, @resolve_review_thread_mutation, %{"threadId" => thread_id}) do
      {:error, {:github_graphql_errors, errors}} ->
        {:error, classify_review_thread_resolution_errors(thread_id, errors)}

      result ->
        result
    end
  end

  defp verify_resolved_review_thread(body, thread_id, verification) when is_map(body) do
    thread = get_in(body, ["data", "resolveReviewThread", "thread"]) || %{}

    if Map.get(thread, "isResolved") == true do
      {:ok,
       %{
         resolved: true,
         review_thread_id: Map.get(thread, "id") || thread_id,
         verification: verification,
         mutation_response: body
       }}
    else
      {:error,
       {:review_thread_not_resolved,
        %{
          review_thread_id: thread_id,
          mutation_response: body
        }}}
    end
  end

  defp classify_review_thread_resolution_errors(thread_id, errors) when is_list(errors) do
    if Enum.any?(errors, &review_thread_resolution_permission_error?/1) do
      {:review_thread_resolution_not_permitted,
       %{
         review_thread_id: thread_id,
         errors: errors,
         required_permission:
           "Use a GitHub token that can write pull requests for this repository, such as a fine-grained token with Pull requests: Read and write or a classic token with repo/public_repo access."
       }}
    else
      {:github_graphql_errors, errors}
    end
  end

  defp review_thread_resolution_permission_error?(error) when is_map(error) do
    typed_permission_error?(Map.get(error, "type")) or
      typed_permission_error?(get_in(error, ["extensions", "code"])) or
      known_pat_permission_message?(Map.get(error, "message"))
  end

  defp review_thread_resolution_permission_error?(_error), do: false

  defp typed_permission_error?(value) when is_binary(value),
    do: value in ["FORBIDDEN", "INSUFFICIENT_SCOPES"]

  defp typed_permission_error?(_value), do: false

  defp known_pat_permission_message?(message) when is_binary(message),
    do: String.downcase(message) == "resource not accessible by personal access token"

  defp known_pat_permission_message?(_message), do: false

  defp verify_review_thread_resolution_ready(request_fun, token, thread_id, terminal_reply_body, opts) do
    case fetch_review_thread(request_fun, token, thread_id) do
      {:ok, thread_body} ->
        Logger.info("GitHub review thread resolution verification response: #{inspect(thread_body)}")

        verify_review_thread_resolution_latest_reply(
          thread_body,
          thread_id,
          terminal_reply_body,
          request_fun,
          token,
          opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_review_thread_resolution_latest_reply(
         thread_body,
         thread_id,
         terminal_reply_body,
         request_fun,
         token,
         opts
       ) do
    thread = review_thread_from_body(thread_body)
    latest = thread |> thread_comments() |> List.last()

    with {:ok, bot_account} <- review_thread_bot_account(opts, request_fun, token) do
      cond do
        Map.get(thread, "isResolved") == true ->
          {:error,
           resolution_precondition_failed(thread_id, :already_resolved, %{
             review_thread_id: thread_id
           })}

        is_nil(latest) ->
          {:error,
           resolution_precondition_failed(thread_id, :latest_comment_missing, %{
             review_thread_id: thread_id
           })}

        get_in(latest, ["author", "login"]) != bot_account ->
          {:error,
           resolution_precondition_failed(thread_id, :latest_comment_author_mismatch, %{
             expected: bot_account,
             actual: get_in(latest, ["author", "login"]),
             latest_comment: normalize_verified_thread_comment(latest)
           })}

        Map.get(latest, "body") != terminal_reply_body ->
          {:error,
           resolution_precondition_failed(thread_id, :latest_comment_body_mismatch, %{
             expected: terminal_reply_body,
             actual: Map.get(latest, "body"),
             latest_comment: normalize_verified_thread_comment(latest)
           })}

        review_thread_authoritative_comment?(thread, opts) ->
          {:ok,
           %{
             "review_thread_id" => thread_id,
             "latest_comment" => normalize_verified_thread_comment(latest)
           }}

        true ->
          {:error,
           {:review_thread_resolution_not_authorized,
            %{
              review_thread_id: thread_id,
              path: Map.get(thread, "path"),
              required_boundary: "Only resolve review threads whose latest non-agent reviewer comment is authoritative for the thread path according to CODEOWNERS."
            }}}
      end
    end
  end

  defp resolution_precondition_failed(thread_id, reason, detail) do
    {:review_thread_resolution_precondition_failed,
     detail
     |> Map.put(:review_thread_id, thread_id)
     |> Map.put(:reason, reason)}
  end

  defp review_thread_authoritative_comment?(thread, opts) when is_map(thread) do
    opts = codeowners_classification_opts(opts)
    context = thread |> normalize_thread_for_comment_context() |> thread_ownership_context(opts)

    thread
    |> thread_comments()
    |> Enum.reverse()
    |> Enum.find(fn comment ->
      author = get_in(comment, ["author", "login"])
      not agent_login?(author, opts)
    end)
    |> case do
      nil ->
        false

      reviewer_comment ->
        reviewer_comment
        |> get_in(["author", "login"])
        |> Codeowners.authoritative?(context)
    end
  end

  defp normalize_thread_for_comment_context(thread) do
    %{"path" => Map.get(thread, "path")}
  end

  defp verify_review_thread_reply(request_fun, token, thread_id, body, opts) do
    case fetch_review_thread(request_fun, token, thread_id) do
      {:ok, thread_body} ->
        Logger.info("GitHub review thread reply verification response: #{inspect(thread_body)}")

        verify_latest_review_thread_comment(
          thread_body,
          thread_id,
          body,
          request_fun,
          token,
          opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_review_thread(request_fun, token, thread_id) do
    github_graphql(request_fun, token, @review_thread_query, %{"id" => thread_id})
  end

  defp verify_latest_review_thread_comment(thread_body, thread_id, body, request_fun, token, opts) do
    latest = thread_body |> review_thread_from_body() |> thread_comments() |> List.last()

    with {:ok, bot_account} <- review_thread_bot_account(opts, request_fun, token) do
      cond do
        is_nil(latest) ->
          {:error, :review_thread_latest_comment_missing}

        get_in(latest, ["author", "login"]) != bot_account ->
          latest_comment_author_mismatch(bot_account, latest)

        Map.get(latest, "body") != body ->
          latest_comment_body_mismatch(body, latest)

        true ->
          {:ok,
           %{
             "review_thread_id" => thread_id,
             "latest_comment" => normalize_verified_thread_comment(latest)
           }}
      end
    end
  end

  defp latest_comment_author_mismatch(bot_account, latest) do
    detail = %{
      expected: bot_account,
      actual: get_in(latest, ["author", "login"])
    }

    {:error, {:review_thread_latest_comment_author_mismatch, detail}}
  end

  defp latest_comment_body_mismatch(body, latest) do
    detail = %{
      expected: body,
      actual: Map.get(latest, "body")
    }

    {:error, {:review_thread_latest_comment_body_mismatch, detail}}
  end

  defp review_thread_from_body(body) when is_map(body) do
    case get_in(body, ["data", "node"]) do
      %{"id" => _id} = thread -> thread
      _ -> %{}
    end
  end

  defp normalize_verified_thread_comment(comment) when is_map(comment) do
    %{
      "id" => Map.get(comment, "databaseId") || Map.get(comment, "id"),
      "node_id" => Map.get(comment, "id"),
      "body" => Map.get(comment, "body") || "",
      "created_at" => Map.get(comment, "createdAt"),
      "updated_at" => Map.get(comment, "updatedAt") || Map.get(comment, "createdAt"),
      "html_url" => Map.get(comment, "url"),
      "user" => %{"login" => get_in(comment, ["author", "login"])}
    }
  end

  defp review_thread_bot_account(opts, request_fun, token) do
    case opts
         |> Keyword.get_lazy(:bot_account, &GitHub.Config.bot_account/0)
         |> normalize_optional_binary() do
      bot_account when is_binary(bot_account) ->
        {:ok, bot_account}

      nil ->
        fetch_authenticated_viewer_login(request_fun, token)
    end
  end

  defp fetch_authenticated_viewer_login(request_fun, token) do
    case github_graphql(request_fun, token, @viewer_login_query, %{}) do
      {:ok, %{"data" => %{"viewer" => %{"login" => login}}}} ->
        case normalize_optional_binary(login) do
          nil -> {:error, :github_viewer_login_missing}
          viewer_login -> {:ok, viewer_login}
        end

      {:ok, _body} ->
        {:error, :github_viewer_login_missing}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_optional_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_binary(_value), do: nil

  defp retryable_review_thread_verification_error?({:github, kind, _detail})
       when kind in [:dns, :timeout, :tls, :transport, :rate_limited],
       do: true

  defp retryable_review_thread_verification_error?({:review_thread_latest_comment_author_mismatch, _}),
    do: true

  defp retryable_review_thread_verification_error?({:review_thread_latest_comment_body_mismatch, _}),
    do: true

  defp retryable_review_thread_verification_error?(:review_thread_latest_comment_missing),
    do: true

  defp retryable_review_thread_verification_error?(_reason), do: false

  defp retryable_github_error?({:github, kind, _detail})
       when kind in [:dns, :timeout, :tls, :transport, :rate_limited],
       do: true

  defp retryable_github_error?(_reason), do: false

  defp sleep_review_thread_retry(opts, attempt) do
    delay_ms = normalize_non_negative_integer(Keyword.get(opts, :retry_delay_ms), 250) * attempt
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    sleep_fun.(delay_ms)
  end

  defp normalize_review_thread_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> {:error, :missing_review_thread_id}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_review_thread_id(_id), do: {:error, :missing_review_thread_id}

  defp normalize_review_thread_reply_body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, :missing_review_thread_reply_body}
      _trimmed -> {:ok, body}
    end
  end

  defp normalize_review_thread_reply_body(_body), do: {:error, :missing_review_thread_reply_body}

  defp normalize_review_thread_terminal_reply_body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, :missing_review_thread_terminal_reply_body}
      _trimmed -> {:ok, body}
    end
  end

  defp normalize_review_thread_terminal_reply_body(_body),
    do: {:error, :missing_review_thread_terminal_reply_body}

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(_value, default), do: default

  defp github_graphql(request_fun, token, query, variables) do
    body = %{"query" => query, "variables" => variables}

    case request_fun.(%{method: :post, url: @graphql_url, token: token, body: body}) do
      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        {:error, {:github_graphql_errors, errors}}

      {:ok, %{status: 200, body: response}} when is_map(response) ->
        {:ok, response}

      {:ok, %{status: _status} = response} ->
        {:error, github_status_error(response)}

      {:error, reason} ->
        {:error, classify_error({:error, reason})}
    end
  end

  defp review_threads_page(body) when is_map(body) do
    threads = get_in(body, ["data", "repository", "pullRequest", "reviewThreads", "nodes"])
    page_info = get_in(body, ["data", "repository", "pullRequest", "reviewThreads", "pageInfo"])

    if is_list(threads) and is_map(page_info) do
      {:ok, {threads, page_info}}
    else
      {:error, :review_threads_missing}
    end
  end

  defp unaddressed_thread_comments(threads, opts) when is_list(threads) do
    threads
    |> Enum.flat_map(&unaddressed_thread_comment(&1, opts))
  end

  defp unaddressed_thread_comment(%{"isResolved" => false} = thread, opts) do
    thread
    |> thread_comments()
    |> List.last()
    |> classify_thread_comment(thread, opts)
    |> case do
      %{authoritative: true} = comment ->
        [comment]

      %{} = comment ->
        if unresolved_agent_review_thread_reply?(comment, opts),
          do: [mark_review_thread_resolution_required(comment)],
          else: []

      _ ->
        []
    end
  end

  defp unaddressed_thread_comment(_thread, _opts), do: []

  defp thread_comments(thread) when is_map(thread) do
    case get_in(thread, ["comments", "nodes"]) do
      comments when is_list(comments) -> comments
      _ -> []
    end
  end

  defp classify_thread_comment(nil, _thread, _opts), do: nil

  defp classify_thread_comment(comment, thread, opts) when is_map(comment) and is_map(thread) do
    normalized = normalize_thread_comment(comment, thread)
    classification_opts = codeowners_classification_opts(opts)
    context = thread_ownership_context(normalized, classification_opts)
    Codeowners.classify_comment(normalized, context, classification_opts)
  end

  defp normalize_thread_comment(comment, thread) do
    path = Map.get(thread, "path")

    %{
      "id" => Map.get(comment, "databaseId"),
      "review_thread_id" => Map.get(thread, "id"),
      "body" => Map.get(comment, "body") || "",
      "created_at" => Map.get(comment, "createdAt"),
      "updated_at" => Map.get(comment, "updatedAt") || Map.get(comment, "createdAt"),
      "html_url" => Map.get(comment, "url"),
      "path" => path,
      "line" => Map.get(thread, "line"),
      "user" => %{"login" => get_in(comment, ["author", "login"])}
    }
  end

  defp codeowners_classification_opts(opts) do
    agent_logins =
      [
        Keyword.get_lazy(opts, :bot_account, &GitHub.Config.bot_account/0)
        | Keyword.get(opts, :agent_logins, [])
      ]
      |> List.flatten()
      |> Enum.flat_map(fn value ->
        case normalize_optional_binary(value) do
          nil -> []
          login -> [login]
        end
      end)
      |> Enum.uniq()

    Keyword.put(opts, :agent_logins, agent_logins)
  end

  defp thread_ownership_context(%{"path" => path}, opts) when is_binary(path) and path != "" do
    Codeowners.ownership_for_path(path, opts)
  end

  defp thread_ownership_context(_comment, opts), do: Codeowners.repo_ownership(opts)

  defp unresolved_agent_review_thread_reply?(comment, opts) when is_map(comment) do
    comment
    |> get_in(["user", "login"])
    |> agent_login?(opts)
  end

  defp agent_login?(login, opts) when is_binary(login) do
    opts
    |> codeowners_classification_opts()
    |> Keyword.get(:agent_logins, [])
    |> Enum.member?(login)
  end

  defp agent_login?(_login, _opts), do: false

  defp mark_review_thread_resolution_required(comment) do
    comment
    |> Map.put(:authoritative, true)
    |> Map.put("review_thread_resolution_required", true)
  end

  defp do_update_issue_state(update_context, state_name) do
    new_label = "#{update_context.prefix}:#{normalize_state(state_name)}"

    case update_context.request_fun.(%{
           method: :get,
           url: update_context.issue_url,
           token: update_context.token
         }) do
      {:ok, %{status: 200, body: issue_body}} ->
        apply_issue_state_update(update_context, issue_body, state_name, new_label)

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, classify_error({:error, reason})}
    end
  end

  defp apply_issue_state_update(context, issue_body, state_name, new_label) do
    with :ok <- verify_human_review_review_threads_clear(context, state_name) do
      if closed_issue?(issue_body) and active_target_state?(state_name) do
        remove_active_state_labels(
          context.request_fun,
          context.token,
          context.owner,
          context.repo,
          context.issue_number,
          issue_body,
          context.prefix
        )
      else
        swap_and_maybe_close_issue(context, issue_body, state_name, new_label)
      end
    end
  end

  defp verify_human_review_review_threads_clear(context, state_name) do
    if human_review_target_state?(state_name) do
      verify_issue_review_threads_clear(context)
    else
      :ok
    end
  end

  defp verify_issue_review_threads_clear(context) do
    case fetch_open_pull_request_for_branch(context.issue_number,
           request_fun: context.request_fun,
           token: context.token
         ) do
      {:ok, %{"number" => pr_number}} when is_integer(pr_number) ->
        with {:ok, agent_login} <-
               review_thread_bot_account(context.opts, context.request_fun, context.token) do
          verify_pr_review_threads_clear(context, pr_number, agent_login)
        end

      {:ok, nil} ->
        :ok

      {:ok, _pr} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_pr_review_threads_clear(context, pr_number, agent_login) do
    case fetch_unaddressed_pr_review_thread_comments(pr_number,
           request_fun: context.request_fun,
           token: context.token,
           agent_logins: [agent_login | Keyword.get(context.opts, :agent_logins, [])]
         ) do
      {:ok, []} ->
        :ok

      {:ok, comments} ->
        {:error,
         {:unverified_review_threads,
          %{
            issue_number: context.issue_number,
            pr_number: pr_number,
            review_thread_ids: Enum.map(comments, &Map.get(&1, "review_thread_id")) |> Enum.reject(&is_nil/1),
            comment_ids: Enum.map(comments, &Map.get(&1, "id")) |> Enum.reject(&is_nil/1),
            count: length(comments)
          }}}

      {:error, _reason} = error ->
        error
    end
  end

  defp human_review_target_state?(state_name), do: normalize_state(state_name) == "human-review"

  defp remove_active_state_labels(
         request_fun,
         token,
         owner,
         repo,
         issue_number,
         issue_body,
         prefix
       ) do
    issue_body
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
    |> Enum.reject(&terminal_state_label?(&1, prefix))
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case delete_issue_label(request_fun, token, owner, repo, issue_number, label) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp swap_and_maybe_close_issue(context, issue_body, state_name, new_label) do
    with :ok <-
           swap_labels(
             context,
             issue_body,
             state_name,
             new_label
           ) do
      maybe_close_issue(context.request_fun, context.token, context.issue_url, state_name)
    end
  end

  defp swap_labels(context, issue_body, state_name, new_label) do
    with :ok <-
           remove_state_labels(
             context.request_fun,
             context.token,
             context.owner,
             context.repo,
             context.issue_number,
             issue_body,
             context.prefix
           ) do
      add_state_label(context, state_name, new_label)
    end
  end

  defp add_state_label(context, state_name, new_label) do
    if active_target_state?(state_name) do
      add_active_issue_label(context, new_label)
    else
      add_issue_label(
        context.request_fun,
        context.token,
        context.owner,
        context.repo,
        context.issue_number,
        new_label
      )
    end
  end

  defp add_active_issue_label(context, new_label) do
    case context.request_fun.(%{method: :get, url: context.issue_url, token: context.token}) do
      {:ok, %{status: 200, body: issue_body}} ->
        if closed_issue?(issue_body) do
          remove_active_state_labels(
            context.request_fun,
            context.token,
            context.owner,
            context.repo,
            context.issue_number,
            issue_body,
            context.prefix
          )
        else
          add_issue_label(
            context.request_fun,
            context.token,
            context.owner,
            context.repo,
            context.issue_number,
            new_label
          )
        end

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, classify_error({:error, reason})}
    end
  end

  defp remove_state_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix) do
    issue_body
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case delete_issue_label(request_fun, token, owner, repo, issue_number, label) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_issue_label(request_fun, token, owner, repo, issue_number, label) do
    url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

    case request_fun.(%{method: :delete, url: url, token: token}) do
      {:ok, %{status: status}} when status in [200, 204, 404] ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, classify_error({:error, reason})}
    end
  end

  defp add_issue_label(request_fun, token, owner, repo, issue_number, label) do
    url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"

    case request_fun.(%{method: :post, url: url, token: token, body: %{"labels" => [label]}}) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, classify_error({:error, reason})}
    end
  end

  defp maybe_close_issue(request_fun, token, issue_url, state_name) do
    if normalize_state(state_name) in ["done", "cancelled", "canceled"] do
      case request_fun.(%{
             method: :patch,
             url: issue_url,
             token: token,
             body: %{"state" => "closed"}
           }) do
        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, classify_error({:error, reason})}
      end
    else
      :ok
    end
  end

  defp closed_issue?(%{"state" => "closed"}), do: true
  defp closed_issue?(_issue_body), do: false

  defp active_target_state?(state_name) do
    not terminal_state_name?(state_name)
  end

  defp terminal_state_label?(label, prefix) do
    label
    |> String.replace_prefix("#{prefix}:", "")
    |> terminal_state_name?()
  end

  defp terminal_state_name?(state_name) do
    normalize_state(state_name) in ["done", "cancelled", "canceled"]
  end

  defp normalize_issue(gh_issue, _owner, _repo, prefix) when is_map(gh_issue) do
    number = gh_issue["number"]
    labels = gh_issue["labels"] || []
    label_names = Enum.map(labels, &(&1["name"] || ""))

    %Issue{
      id: to_string(number),
      identifier: to_string(number),
      title: gh_issue["title"],
      description: gh_issue["body"],
      priority: extract_priority(label_names),
      state: extract_state(gh_issue, label_names, prefix),
      branch_name: nil,
      url: gh_issue["html_url"],
      assignee_id: get_in(gh_issue, ["assignee", "login"]),
      labels: Enum.map(label_names, &String.downcase/1),
      assigned_to_worker: true,
      created_at: parse_datetime(gh_issue["created_at"]),
      updated_at: parse_datetime(gh_issue["updated_at"])
    }
  end

  defp extract_state(%{"state" => "closed"}, _label_names, _prefix), do: "Closed"

  defp extract_state(_gh_issue, label_names, prefix) do
    prefix_colon = "#{prefix}:"

    Enum.find_value(label_names, fn name ->
      if String.starts_with?(name, prefix_colon) do
        String.replace_prefix(name, prefix_colon, "")
      end
    end)
  end

  defp extract_priority(label_names) do
    Enum.find_value(label_names, &parse_priority_label/1)
  end

  defp parse_priority_label(name) do
    case Regex.run(~r/^priority:(\d+)$/, name) do
      [_, n] -> parse_priority_int(n)
      _ -> nil
    end
  end

  defp parse_priority_int(n) do
    case Integer.parse(n) do
      {priority, _} -> priority
      :error -> nil
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_state(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "-")
  end

  defp parse_repo do
    case GitHub.Config.repo() do
      nil ->
        {:error, :missing_github_repo}

      repo_string ->
        case String.split(repo_string, "/") do
          [owner, repo] -> {:ok, {owner, repo}}
          _ -> {:error, {:invalid_github_repo, repo_string}}
        end
    end
  end

  defp require_token do
    case GitHub.Config.token() do
      nil -> {:error, :missing_github_token}
      token -> {:ok, token}
    end
  end

  defp require_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        if Keyword.has_key?(opts, :request_fun) do
          {:ok, "test-gh-token"}
        else
          require_token()
        end
    end
  end

  defp default_request_fun(%{method: :get, url: url, token: token} = req) do
    headers =
      case Map.get(req, :etag) do
        nil -> github_headers(token, req)
        etag -> [{"If-None-Match", etag} | github_headers(token, req)]
      end

    Req.get(url, headers: headers, connect_options: [timeout: 30_000])
  end

  defp default_request_fun(%{method: :post, url: url, token: token, body: body} = req) do
    Req.post(url,
      headers: github_headers(token, req),
      json: body,
      connect_options: [timeout: 30_000]
    )
  end

  defp default_request_fun(%{method: :patch, url: url, token: token, body: body} = req) do
    Req.patch(url,
      headers: github_headers(token, req),
      json: body,
      connect_options: [timeout: 30_000]
    )
  end

  defp default_request_fun(%{method: :delete, url: url, token: token} = req) do
    Req.delete(url, headers: github_headers(token, req), connect_options: [timeout: 30_000])
  end

  defp default_gh_auth_status_fun do
    case System.find_executable("gh") do
      nil ->
        {:ok, :not_installed}

      gh ->
        case System.cmd(gh, ["auth", "status"],
               env: [{"GITHUB_TOKEN", nil}],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> {:ok, :available}
          {_output, _status} -> {:ok, :unavailable}
        end
    end
  rescue
    _ -> {:ok, :unknown}
  end

  defp github_headers(token, %{api_version: version}) when is_binary(version) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", version}
    ]
  end

  defp github_headers(token, _req) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end

  # ---------------------------------------------------------------------------
  # Issue Dependencies REST API helpers
  # ---------------------------------------------------------------------------
  #
  # GitHub's Issue Dependencies endpoints require the newer `2026-03-10`
  # API version header. The other client functions can continue using
  # `2022-11-28` since the issue/comment surfaces they hit are stable.

  @dependencies_api_version "2026-03-10"

  defp dependency_get(issue_number, kind, opts) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)

      url =
        "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/dependencies/#{kind}"

      case request_fun.(%{
             method: :get,
             url: url,
             token: token,
             api_version: @dependencies_api_version
           }) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          {:ok, body}

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, classify_error({:error, reason})}
      end
    end
  end

  defp dependency_mutate(blocked_number, blocker_id, method, opts) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)

      url =
        "#{@base_url}/repos/#{owner}/#{repo}/issues/#{blocked_number}/dependencies/blocked_by"

      req = %{
        method: method,
        url: url,
        token: token,
        api_version: @dependencies_api_version
      }

      req = if method == :post, do: Map.put(req, :body, %{"issue_id" => blocker_id}), else: req

      case request_fun.(req) do
        {:ok, %{status: status, body: body}} when status in [200, 201] and is_map(body) ->
          {:ok, body}

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, classify_error({:error, reason})}
      end
    end
  end

  defp header(headers, name) when is_list(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} ->
        if String.downcase(to_string(key)) == name_down do
          List.wrap(value) |> List.first()
        end

      _ ->
        nil
    end)
  end

  defp header(headers, name) when is_map(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name_down do
        List.wrap(value) |> List.first()
      end
    end)
  end

  defp poll_interval(headers) do
    case header(headers, "x-poll-interval") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> 60
        end

      _ ->
        60
    end
  end
end
