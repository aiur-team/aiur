defmodule Aiur.GitHub.PullRequests do
  @moduledoc """
  GitHub pull request domain.
  """

  alias Aiur.{Codeowners, TicketBranch}
  alias Aiur.GitHub.{Comments, Errors, Transport}

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

  @spec fetch_classified_pr_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(pr_number, opts \\ []) do
    with {:ok, paths} <- fetch_pull_request_changed_paths(pr_number, opts),
         {:ok, comments} <- fetch_pull_request_review_comments(pr_number, opts) do
      context = Codeowners.ownership_for_paths(paths, opts)
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
