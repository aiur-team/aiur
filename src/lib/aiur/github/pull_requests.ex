defmodule Aiur.GitHub.PullRequests do
  @moduledoc """
  GitHub pull request domain.
  """

  alias Aiur.Codeowners
  alias Aiur.GitHub.{ChangedPaths, Comments, Errors, ResourceFetch, ResourceStore, Transport, WriteThrough}
  alias Aiur.GitHub.PullRequests.{BaseBranch, OpenPullRequests}
  alias Aiur.GitHub.PullRequests.CommitCiStatus

  @issue_events_page 100

  @doc "Updates an open pull request body through the daemon's authenticated transport."
  @spec update_body(pos_integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_body(number, body, opts \\ []) when is_integer(number) and number > 0 and is_binary(body) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{number}"

      case request_fun.(%{method: :patch, url: url, token: token, body: %{"body" => body}, caller: "agent_handoff_body"}) do
        {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) ->
          WriteThrough.pull_request(response)
          {:ok, response}

        {:ok, response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  @spec fetch_pull_request_changed_paths(String.t() | integer(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_pull_request_changed_paths(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}/files?per_page=100"

      case Comments.fetch_repo_comment_stream(request_fun, token, url, [], caller: "pull_request_changed_paths") do
        {:ok, files} ->
          ChangedPaths.decode(files)

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  The fingerprint of a pull request's own contribution at a given head.

  `GET /repos/{o}/{r}/compare/{base}...{head}` returns the three-dot diff
  between the merge-base of `base` and `head` and `head` — the PR's own
  contribution, with merges of the base branch excluded. The returned
  `{filename, sha}` pairs are content-sensitive (the blob sha changes when the
  file's content changes), so comparing the fingerprint at a blocking review's
  `commit_id` against the current head distinguishes a genuine rework from a
  merge-only push of the base branch (#2337 rework follow-up).
  """
  @spec fetch_compare_files(String.t(), String.t(), keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def fetch_compare_files(base_sha, head_sha, opts \\ [])
      when is_binary(base_sha) and is_binary(head_sha) and base_sha != "" and head_sha != "" do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/compare/#{base_sha}...#{head_sha}"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: %{"files" => files}}} when is_list(files) ->
          {:ok, Enum.map(files, &compare_file_fingerprint/1) |> Enum.reject(&is_nil/1)}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  defp compare_file_fingerprint(file) when is_map(file) do
    case {Map.get(file, "filename"), Map.get(file, "sha")} do
      {filename, sha} when is_binary(filename) and is_binary(sha) -> {filename, sha}
      _other -> nil
    end
  end

  defp compare_file_fingerprint(_file), do: nil

  @spec fetch_pull_request_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_pull_request_review_comments(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      query = Comments.comment_query(opts)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}/comments?#{query}"

      Comments.fetch_repo_comment_stream(request_fun, token, url, [], caller: "pull_request_review_comments")
    end
  end

  @doc """
  Fetches a pull request's review submissions with `If-None-Match` support.

  This is the only reader of the review-submissions endpoint; the unconditional
  `fetch_pull_request_reviews/2` was retired (#2326) so no new call site could
  pick a full-price read by accident. The approval read behind the human-review
  gate runs on every transition attempt and must be strictly fresh: it cannot be
  answered from a cache, so the only way to make it cost nothing is to let GitHub
  answer `304`. That is a request GitHub does not bill against the primary REST
  limit.

  The read is single-page in practice — `per_page=100` is GitHub's ceiling and
  no active PR has that many reviews — so a page-1 `304` *is* the whole-list
  answer. `Transport.fetch_json_list_conditional/4` asserts the single-page
  claim and refuses a response that points at a next page rather than silently
  answering a truncated list (#2330).
  """
  @spec fetch_pull_request_reviews_conditional(String.t() | integer(), keyword()) ::
          {:ok, [map()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_pull_request_reviews_conditional(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}/reviews?per_page=100"

      Transport.fetch_json_list_conditional(request_fun, token, url, Keyword.get(opts, :etag), caller: "pull_request_reviews_conditional")
    end
  end

  @doc "Fetch formal PR reviews for cold agent context with a fresh validator and CODEOWNERS classification."
  @spec fetch_classified_pr_reviews(String.t() | integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_reviews(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         context when is_map(context) <- Codeowners.repo_ownership(opts) do
      key = ResourceStore.key_for_repo(:pull_request_reviews, "#{owner}/#{repo}", pr_number)

      fetcher = fn fetch_opts ->
        fetch_pull_request_reviews_conditional(pr_number, Keyword.merge(opts, fetch_opts))
      end

      case ResourceFetch.need(key, fetcher, freshness: ResourceFetch.decision(), reason: "cold agent review context") do
        {:ok, reviews, _meta} when is_list(reviews) ->
          {:ok, Enum.map(reviews, &Codeowners.classify_comment(&1, context, opts))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec fetch_open_pull_request_for_branch(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  defdelegate fetch_open_pull_request_for_branch(issue_number, opts \\ []), to: OpenPullRequests

  @spec fetch_open_pull_requests_for_branch(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate fetch_open_pull_requests_for_branch(issue_number, opts \\ []), to: OpenPullRequests

  @spec fetch_open_pull_request_for_branch_conditional(String.t() | integer(), keyword()) ::
          {:ok, map() | nil, String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  defdelegate fetch_open_pull_request_for_branch_conditional(issue_number, opts \\ []), to: OpenPullRequests

  @spec fetch_open_pull_requests_conditional(keyword()) ::
          {:ok, [map()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  defdelegate fetch_open_pull_requests_conditional(opts \\ []), to: OpenPullRequests

  @doc """
  Fetches the GitHub check runs and legacy combined commit status for `sha`.

  GitHub Actions and GitHub Apps report check runs while older integrations
  report commit statuses. CI lifecycle callers need both sources to determine
  whether a pull request head is pending or terminal.
  """
  @spec fetch_commit_ci_status(String.t(), keyword()) ::
          {:ok, %{check_runs: [map()], commit_status: map()}} | {:error, term()}
  def fetch_commit_ci_status(sha, opts \\ [])

  def fetch_commit_ci_status(sha, opts) when is_binary(sha) and sha != "" do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      encoded_sha = URI.encode(sha)
      base_url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/commits/#{encoded_sha}"

      CommitCiStatus.fetch(owner, repo, sha, base_url, request_fun, token)
    end
  end

  def fetch_commit_ci_status(sha, _opts), do: {:error, {:invalid_commit_sha, sha}}

  @spec fetch_commit_timestamp(String.t(), keyword()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  def fetch_commit_timestamp(sha, opts \\ [])

  def fetch_commit_timestamp(sha, opts) when is_binary(sha) and sha != "" do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/commits/#{URI.encode(sha)}"

      case Transport.fetch_json_map(request_fun, token, url, caller: "commit_timestamp") do
        {:ok, commit} -> {:ok, commit_timestamp(commit)}
        {:error, _reason} = error -> error
      end
    end
  end

  def fetch_commit_timestamp(sha, _opts), do: {:error, {:invalid_commit_sha, sha}}

  defp commit_timestamp(commit) do
    value = get_in(commit, ["commit", "committer", "date"]) || get_in(commit, ["commit", "author", "date"])

    case value && DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  @spec fetch_open_pull_requests_by_label(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate fetch_open_pull_requests_by_label(label, opts \\ []), to: OpenPullRequests

  @spec fetch_open_pull_requests(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate fetch_open_pull_requests(opts \\ []), to: OpenPullRequests

  @spec fetch_pull_request_head_ref(String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_pull_request_head_ref(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: %{"head" => %{"ref" => ref}}}} when is_binary(ref) ->
          {:ok, ref}

        {:ok, %{status: 200}} ->
          {:error, :head_ref_missing}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  @doc """
  Answers whether an open, non-draft pull request was ever a draft.

  Used only when a poll first sees a ticket's PR already ready and holds no
  earlier observation of it (#2707): GitHub's webhook sends
  `ready_for_review` for a draft that went ready, and nothing for a PR opened
  ready, so the poll needs the PR's history to match. The answer is recorded
  durably, so this is at most one request per PR, and only for a PR no poll
  ever saw as a draft.

  Reads one page of the issue events, oldest first. A `ready_for_review` event
  answers `true`. A page with fewer than 100 events and no such event answers
  `false`. A full page with no such event answers `true`: the history is too
  long to read cheaply, and a spare wake costs less than a lost one.
  """
  @spec fetch_pull_request_was_draft(String.t() | integer(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def fetch_pull_request_was_draft(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{pr_number}/events?per_page=#{@issue_events_page}"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: events}} when is_list(events) ->
          {:ok, Enum.any?(events, &ready_for_review_event?/1) or length(events) >= @issue_events_page}

        {:ok, %{status: 200}} ->
          {:error, :issue_events_malformed}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  defp ready_for_review_event?(%{"event" => "ready_for_review"}), do: true
  defp ready_for_review_event?(_event), do: false

  @doc """
  Fetches a pull request's head ref with `If-None-Match` support.

  The list-only `fetch_pull_request_head_ref/2` contract is unchanged. This
  variant exists so a `/pulls/{n}` read can be a `304` in steady state — a
  request GitHub does not bill against the primary REST limit — instead of the
  unconditional re-read that made row 5 of #2352 pure waste.
  """
  @spec fetch_pull_request_head_ref_conditional(String.t() | integer(), keyword()) ::
          {:ok, String.t(), String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_pull_request_head_ref_conditional(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}"

      pull_request_conditional_request(url, token, opts)
      |> request_fun.()
      |> head_ref_conditional_response(Keyword.get(opts, :etag))
    end
  end

  defp head_ref_conditional_response(
         {:ok, %{status: 200, body: %{"head" => %{"ref" => ref}}} = response},
         etag
       )
       when is_binary(ref) do
    {:ok, ref, retained_etag(response, etag)}
  end

  defp head_ref_conditional_response({:ok, %{status: 200}}, _etag), do: {:error, :head_ref_missing}

  defp head_ref_conditional_response({:ok, %{status: 304} = response}, etag),
    do: {:not_modified, retained_etag(response, etag)}

  defp head_ref_conditional_response({:ok, %{status: _status} = response}, _etag),
    do: {:error, Errors.github_status_error(response)}

  defp head_ref_conditional_response({:error, reason}, _etag),
    do: {:error, Errors.classify_error({:error, reason})}

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
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: %{} = pr}} ->
          {:ok, open_pull_request_or_nil(pr)}

        {:ok, %{status: 404}} ->
          {:ok, nil}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  @doc """
  Fetches the OPEN pull request numbered `pr_number` with `If-None-Match`
  support.

  The list-only `fetch_open_pull_request/2` contract is unchanged for callers
  that need a fresh answer. This variant exists because the `/pulls/{n}` read
  was the one row of #2352 with **no validator at all** — unconditional, so
  every repeat was pure waste rather than a cheap revalidation. `Client`
  routes through it under `ResourceFetch`, so a read GitHub confirms unchanged
  answers `304` — a request it does not bill against the primary REST limit —
  instead of a full-price re-read. Inside the transport cache's `:pull` TTL the
  held body is served as a cache hit and no request is sent; the `304` is the
  post-expiry backstop, not the steady-state path.

  A `304` against the held validator reuses the held pull request, exactly the
  page-one contract the other conditional reads trust. A `404` (the number is a
  plain issue) or a closed/merged PR carries no validator and answers
  `{:ok, nil, nil}` / `{:ok, nil, etag}` respectively, matching the `{:ok, nil}`
  signal `fetch_open_pull_request/2` already uses for the non-PR fallthrough.
  """
  @spec fetch_open_pull_request_conditional(String.t() | integer(), keyword()) ::
          {:ok, map() | nil, String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_open_pull_request_conditional(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}"

      pull_request_conditional_request(url, token, opts)
      |> request_fun.()
      |> open_pull_request_conditional_response(Keyword.get(opts, :etag))
    end
  end

  defp open_pull_request_conditional_response({:ok, %{status: 200, body: %{} = pr} = response}, etag) do
    {:ok, open_pull_request_or_nil(pr), retained_etag(response, etag)}
  end

  defp open_pull_request_conditional_response({:ok, %{status: 304} = response}, etag),
    do: {:not_modified, retained_etag(response, etag)}

  defp open_pull_request_conditional_response({:ok, %{status: 404}}, _etag), do: {:ok, nil, nil}

  defp open_pull_request_conditional_response({:ok, %{status: _status} = response}, _etag),
    do: {:error, Errors.github_status_error(response)}

  defp open_pull_request_conditional_response({:error, reason}, _etag),
    do: {:error, Errors.classify_error({:error, reason})}

  # The `/pulls/{n}` GET request shared by the two row-5 conditional variants,
  # carrying the caller's validator when it has one.
  defp pull_request_conditional_request(url, token, opts) do
    etag = Keyword.get(opts, :etag)
    request = %{method: :get, url: url, token: token}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request
    Transport.put_caller(request, opts)
  end

  defp retained_etag(response, etag), do: Transport.header(Map.get(response, :headers, []), "etag") || etag

  @spec ensure_base_branch(map(), String.t(), keyword()) ::
          {:ok, :unchanged | {:repaired, String.t()}} | {:error, term()}
  defdelegate ensure_base_branch(pr, expected_base, opts \\ []), to: BaseBranch

  @spec fetch_classified_pr_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(pr_number, opts \\ []) do
    with {:ok, paths} <- fetch_pull_request_changed_paths(pr_number, opts),
         context when is_map(context) <- Codeowners.ownership_for_paths(paths, opts),
         {:ok, comments} <- fetch_pull_request_review_comments(pr_number, opts) do
      {:ok, Enum.map(comments, &Codeowners.classify_comment(&1, context, opts))}
    end
  end

  @spec fetch_labeled_open_pull_requests(function(), String.t(), String.t() | nil, String.t(), [map()]) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate fetch_labeled_open_pull_requests(request_fun, token, url, label, acc), to: OpenPullRequests

  @spec pull_request_has_label?(map(), String.t()) :: boolean()
  defdelegate pull_request_has_label?(pull_request, label), to: OpenPullRequests

  # Treat a closed/merged PR the same as a missing one (nil) so the caller
  # routes its comment through the unchanged legacy path rather than dispatching
  # a PR-anchored agent onto a dead branch.
  @spec open_pull_request_or_nil(map()) :: map() | nil
  def open_pull_request_or_nil(%{"state" => "open"} = pr), do: pr
  def open_pull_request_or_nil(%{"state" => state}) when is_binary(state), do: nil
  def open_pull_request_or_nil(pr) when is_map(pr), do: pr
end
