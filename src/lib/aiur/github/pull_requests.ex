defmodule Aiur.GitHub.PullRequests do
  @moduledoc """
  GitHub pull request domain.
  """

  require Logger

  alias Aiur.{Codeowners, TicketBranch}
  alias Aiur.GitHub.{Comments, Errors, Transport, WriteThrough}

  @spec fetch_pull_request_changed_paths(String.t() | integer(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_pull_request_changed_paths(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}/files?per_page=100"

      case Transport.fetch_json_list(request_fun, token, url) do
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
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      query = Comments.comment_query(opts)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}/comments?#{query}"

      Transport.fetch_json_list(request_fun, token, url)
    end
  end

  @doc """
  Fetches all review submissions for a pull request.

  Returns a list of review objects, each containing `id`, `user`, `state`,
  `body`, and `submitted_at`. Does not paginate beyond `per_page=100`; the
  review count on any active PR is expected to be well under that limit.
  """
  @spec fetch_pull_request_reviews(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_pull_request_reviews(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}/reviews?per_page=100"

      Transport.fetch_json_list(request_fun, token, url)
    end
  end

  @doc """
  Fetches a pull request's review submissions with `If-None-Match` support.

  The list-only `fetch_pull_request_reviews/2` contract is unchanged for
  foreground callers. This variant exists because the approval read behind the
  human-review gate runs on every transition attempt and must be strictly fresh:
  it cannot be answered from a cache, so the only way to make it cost nothing is
  to let GitHub answer `304`. That is a request GitHub does not bill against the
  primary REST limit.
  """
  @spec fetch_pull_request_reviews_conditional(String.t() | integer(), keyword()) ::
          {:ok, [map()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_pull_request_reviews_conditional(pr_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}/reviews?per_page=100"

      Transport.fetch_json_list_conditional(request_fun, token, url, Keyword.get(opts, :etag))
    end
  end

  @doc """
  Fetches the open pull request whose legacy or readable Aiur head branch
  belongs to `issue_number`.
  """
  @spec fetch_open_pull_request_for_branch(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      legacy_branch = TicketBranch.legacy_branch_name(issue_number)

      legacy_query =
        URI.encode_query(%{"state" => "open", "head" => "#{owner}:#{legacy_branch}", "per_page" => "10"})

      legacy_url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls?#{legacy_query}"

      case Transport.fetch_json_list(request_fun, token, legacy_url) do
        {:ok, [pull_request | _]} ->
          {:ok, pull_request}

        {:ok, []} ->
          query = URI.encode_query(%{"state" => "open", "per_page" => "100"})
          fetch_open_ticket_pull_request(request_fun, token, "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls?#{query}", issue_number)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp fetch_open_ticket_pull_request(_request_fun, _token, nil, _issue_number), do: {:ok, nil}

  defp fetch_open_ticket_pull_request(request_fun, token, url, issue_number) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        headers = Map.get(response, :headers, [])

        case Enum.find(body, &ticket_pull_request?(&1, issue_number)) do
          nil ->
            fetch_open_ticket_pull_request(
              request_fun,
              token,
              Transport.parse_next_page_url(headers),
              issue_number
            )

          pull_request ->
            {:ok, pull_request}
        end

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp ticket_pull_request?(%{"head" => %{"ref" => branch}}, issue_number) when is_binary(branch),
    do: TicketBranch.ticket_branch?(branch, issue_number)

  defp ticket_pull_request?(_pull_request, _issue_number), do: false

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

      with {:ok, check_runs} <-
             fetch_check_runs(request_fun, token, base_url <> "/check-runs?filter=latest&per_page=100"),
           {:ok, commit_status} when is_map(commit_status) <-
             Transport.fetch_json_map(request_fun, token, base_url <> "/status") do
        {:ok, %{check_runs: check_runs, commit_status: commit_status}}
      else
        {:error, _reason} = error -> error
      end
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

      case Transport.fetch_json_map(request_fun, token, url) do
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

  defp fetch_check_runs(request_fun, token, url, acc \\ []) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: %{"check_runs" => check_runs}} = response} when is_list(check_runs) ->
        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, acc ++ check_runs}
          next -> fetch_check_runs(request_fun, token, next, acc ++ check_runs)
        end

      {:ok, %{status: 200}} ->
        {:error, :invalid_ci_status_response}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
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
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      query = URI.encode_query(%{"state" => "open", "per_page" => "100"})
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls?#{query}"
      fetch_labeled_open_pull_requests(request_fun, token, url, label, [])
    end
  end

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
  Ensures an open pull request targets the configured integration branch.

  A matching pull request is read-only. A mismatch is repaired with GitHub's
  pull-request REST endpoint and accepted only when the response confirms the
  requested base, preserving every other pull-request field (including draft
  state). Failures retain the observed and expected branches for an actionable
  CI handoff.
  """
  @spec ensure_base_branch(map(), String.t(), keyword()) ::
          {:ok, :unchanged | {:repaired, String.t()}} | {:error, term()}
  def ensure_base_branch(pr, expected_base, opts \\ [])

  def ensure_base_branch(
        %{"number" => number, "base" => %{"ref" => current_base}},
        expected_base,
        opts
      )
      when is_binary(current_base) and is_binary(expected_base) and expected_base != "" do
    with {:ok, pr_number} <- positive_integer(number) do
      if current_base == expected_base do
        Logger.debug("Pull request base verified: pr=#{pr_number} base=#{inspect(expected_base)} action=unchanged")

        {:ok, :unchanged}
      else
        repair_base_branch(pr_number, current_base, expected_base, opts)
      end
    end
  end

  def ensure_base_branch(pr, expected_base, _opts)
      when not is_binary(expected_base) or expected_base == "" do
    {:error, {:invalid_pull_request_base_branch, expected_base, Map.get(pr, "number")}}
  end

  def ensure_base_branch(pr, expected_base, _opts) do
    {:error, {:pull_request_base_unavailable, %{pr_number: Map.get(pr, "number"), expected_base: expected_base}}}
  end

  defp repair_base_branch(pr_number, current_base, expected_base, opts) do
    Logger.warning(
      "Pull request base mismatch: pr=#{pr_number} current=#{inspect(current_base)} " <>
        "expected=#{inspect(expected_base)} action=repair"
    )

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         :ok <- journal_before_base_repair(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{pr_number}"

      request_fun.(%{
        method: :patch,
        url: url,
        token: token,
        body: %{"base" => expected_base}
      })
      |> handle_base_repair_response(pr_number, current_base, expected_base)
    else
      {:error, {:base_repair_journal_failed, _reason} = reason} ->
        base_repair_error(pr_number, current_base, expected_base, reason, false)

      {:error, reason} ->
        base_repair_error(pr_number, current_base, expected_base, reason, false)
    end
  end

  defp journal_before_base_repair(opts) do
    case Keyword.fetch(opts, :before_base_repair_fun) do
      {:ok, journal_fun} when is_function(journal_fun, 0) ->
        try do
          case journal_fun.() do
            :ok -> :ok
            {:error, reason} -> {:error, {:base_repair_journal_failed, reason}}
            other -> {:error, {:base_repair_journal_failed, {:unexpected_result, other}}}
          end
        rescue
          error -> {:error, {:base_repair_journal_failed, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:base_repair_journal_failed, {kind, reason}}}
        end

      _ ->
        {:error, {:base_repair_journal_failed, :journal_callback_required}}
    end
  end

  defp handle_base_repair_response(
         {:ok,
          %{
            status: 200,
            body:
              %{
                "base" => %{"ref" => expected_base},
                "head" => %{"sha" => confirmed_head_sha}
              } = pull_request
          }},
         pr_number,
         _current_base,
         expected_base
       )
       when is_binary(confirmed_head_sha) and confirmed_head_sha != "" do
    Logger.info("Pull request base repaired: pr=#{pr_number} base=#{inspect(expected_base)} action=repaired")
    # The repair response is the whole pull request at its new `updated_at`.
    # Only the confirmed repair deposits: the not-confirmed clause below is a
    # state Aiur is refusing to believe, so caching it would be caching a doubt.
    WriteThrough.pull_request(pull_request)
    {:ok, {:repaired, confirmed_head_sha}}
  end

  defp handle_base_repair_response(
         {:ok, %{status: 200, body: body}},
         pr_number,
         current_base,
         expected_base
       ) do
    base_repair_error(
      pr_number,
      current_base,
      expected_base,
      {:repair_not_confirmed,
       %{
         base: get_in(body, ["base", "ref"]),
         head_sha: get_in(body, ["head", "sha"])
       }},
      true
    )
  end

  defp handle_base_repair_response(
         {:ok, %{status: _status} = response},
         pr_number,
         current_base,
         expected_base
       ) do
    base_repair_error(
      pr_number,
      current_base,
      expected_base,
      Errors.github_status_error(response),
      true
    )
  end

  defp handle_base_repair_response({:error, reason}, pr_number, current_base, expected_base) do
    base_repair_error(
      pr_number,
      current_base,
      expected_base,
      Errors.classify_error({:error, reason}),
      true
    )
  end

  defp base_repair_error(pr_number, current_base, expected_base, reason, repair_journaled) do
    {:error,
     {:pull_request_base_repair_failed,
      %{
        pr_number: pr_number,
        current_base: current_base,
        expected_base: expected_base,
        reason: reason,
        repair_journaled: repair_journaled
      }}}
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, {:invalid_pull_request_number, value}}
    end
  end

  defp positive_integer(value), do: {:error, {:invalid_pull_request_number, value}}

  @spec fetch_classified_pr_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(pr_number, opts \\ []) do
    with {:ok, paths} <- fetch_pull_request_changed_paths(pr_number, opts),
         context when is_map(context) <- Codeowners.ownership_for_paths(paths, opts),
         {:ok, comments} <- fetch_pull_request_review_comments(pr_number, opts) do
      {:ok, Enum.map(comments, &Codeowners.classify_comment(&1, context, opts))}
    end
  end

  # Follows the GitHub `Link` `rel="next"` pagination (mirrors
  # `fetch_member_logins/4`) so a repo with more than 100 open PRs cannot
  # silently hide a watched PR past the first page — silent truncation here
  # would drop a watched PR's comments, the exact failure this feature prevents.
  @spec fetch_labeled_open_pull_requests(function(), String.t(), String.t() | nil, String.t(), [
          map()
        ]) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_labeled_open_pull_requests(_request_fun, _token, nil, _label, acc), do: {:ok, acc}

  def fetch_labeled_open_pull_requests(request_fun, token, url, label, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        matched = Enum.filter(body, &pull_request_has_label?(&1, label))
        next = Transport.parse_next_page_url(headers)
        fetch_labeled_open_pull_requests(request_fun, token, next, label, acc ++ matched)

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec pull_request_has_label?(map(), String.t()) :: boolean()
  def pull_request_has_label?(%{"labels" => labels}, label) when is_list(labels) do
    Enum.any?(labels, fn
      %{"name" => name} when is_binary(name) -> name == label
      name when is_binary(name) -> name == label
      _ -> false
    end)
  end

  def pull_request_has_label?(_pull_request, _label), do: false

  # Treat a closed/merged PR the same as a missing one (nil) so the caller
  # routes its comment through the unchanged legacy path rather than dispatching
  # a PR-anchored agent onto a dead branch.
  @spec open_pull_request_or_nil(map()) :: map() | nil
  def open_pull_request_or_nil(%{"state" => "open"} = pr), do: pr
  def open_pull_request_or_nil(%{"state" => state}) when is_binary(state), do: nil
  def open_pull_request_or_nil(pr) when is_map(pr), do: pr
end
