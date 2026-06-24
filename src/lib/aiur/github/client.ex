defmodule Aiur.GitHub.Client do
  @moduledoc """
  GitHub REST API client for issue tracking via labels.
  """

  require Logger
  alias Aiur.{Codeowners, Config, GitHub, Issue}

  @base_url "https://api.github.com"

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    fetch_issues_by_states(Config.active_states(), opts)
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    if state_names == [], do: {:ok, []}, else: do_fetch_issues_by_states(state_names, opts)
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    if issue_ids == [], do: {:ok, []}, else: do_fetch_issue_states_by_ids(issue_ids, opts)
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_number, body, opts \\ []) when is_binary(issue_number) and is_binary(body) do
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
          {:error, {:github_api_request, reason}}
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
  header. Page 1 only (cap 30 items) — see plan U8 rationale: events
  are dense enough that page 2 would already be stale before we fetch.
  """
  @spec fetch_repo_events(keyword()) ::
          {:ok,
           {:events, [map()], String.t() | nil, pos_integer()}
           | {:not_modified, String.t() | nil, pos_integer()}}
          | {:error, term()}
  def fetch_repo_events(opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      etag = Keyword.get(opts, :etag)

      url = "#{@base_url}/repos/#{owner}/#{repo}/events?per_page=30"

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

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, {:github_api_request, reason}}
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
        {:error, reason} -> {:error, {:github_api_request, reason}}
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

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
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
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls/#{pr_number}/comments?per_page=100"

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
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      query = URI.encode_query(%{"state" => "open", "head" => "#{owner}:aiur/#{issue_number}", "per_page" => "10"})
      url = "#{@base_url}/repos/#{owner}/#{repo}/pulls?#{query}"

      case fetch_json_list(request_fun, token, url) do
        {:ok, [first | _]} -> {:ok, first}
        {:ok, []} -> {:ok, nil}
        {:error, _reason} = error -> error
      end
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
         {:ok, token} <- require_token() do
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
          {:error, {:github_api_request, reason}}
      end
    end
  end

  @spec fetch_classified_pr_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(pr_number, opts \\ []) do
    with {:ok, paths} <- fetch_pull_request_changed_paths(pr_number, opts),
         {:ok, comments} <- fetch_pull_request_review_comments(pr_number, opts) do
      context = Codeowners.ownership_for_paths(paths, opts)
      {:ok, Enum.map(comments, &Codeowners.classify_comment(&1, context, opts))}
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
        {:ok, comments} -> {:ok, Enum.map(comments, &Codeowners.classify_comment(&1, context, opts))}
        {:error, _reason} = error -> error
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

      do_update_issue_state(request_fun, token, issue_url, owner, repo, issue_number, prefix, state_name)
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
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  @spec remove_label(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove_label(issue_number, label, opts \\ [])
      when is_binary(issue_number) and is_binary(label) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

      case request_fun.(%{method: :delete, url: url, token: token}) do
        # 404 = label already absent; treat as success so the toggle is idempotent.
        {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
        {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  # -- Private helpers --------------------------------------------------------

  # GitHub labels query is AND (all labels must match), so we fetch each label
  # separately and deduplicate by issue id.
  defp fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix) do
    Enum.reduce_while(labels, {:ok, %{}}, fn label, {:ok, acc} ->
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(label)}&state=open&per_page=100"
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
        {:error, {:github_api_request, reason}}
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
        {:halt, {:error, {:github_api_request, reason}}}
    end
  end

  defp fetch_json_list(request_fun, token, url) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp do_update_issue_state(request_fun, token, issue_url, owner, repo, issue_number, prefix, state_name) do
    new_label = "#{prefix}:#{normalize_state(state_name)}"

    case request_fun.(%{method: :get, url: issue_url, token: token}) do
      {:ok, %{status: 200, body: issue_body}} ->
        swap_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix, new_label)
        maybe_close_issue(request_fun, token, issue_url, state_name)
        :ok

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp swap_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix, new_label) do
    issue_body
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
    |> Enum.each(fn label ->
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"
      request_fun.(%{method: :delete, url: url, token: token})
    end)

    add_url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"
    request_fun.(%{method: :post, url: add_url, token: token, body: %{"labels" => [new_label]}})
  end

  defp maybe_close_issue(request_fun, token, issue_url, state_name) do
    if normalize_state(state_name) in ["done", "cancelled"] do
      request_fun.(%{method: :patch, url: issue_url, token: token, body: %{"state" => "closed"}})
    end
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
      state: extract_state(label_names, prefix),
      branch_name: nil,
      url: gh_issue["html_url"],
      assignee_id: get_in(gh_issue, ["assignee", "login"]),
      labels: Enum.map(label_names, &String.downcase/1),
      assigned_to_worker: true,
      created_at: parse_datetime(gh_issue["created_at"]),
      updated_at: parse_datetime(gh_issue["updated_at"])
    }
  end

  defp extract_state(label_names, prefix) do
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
          {:error, {:github_api_request, reason}}
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
          {:error, {:github_api_request, reason}}
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
