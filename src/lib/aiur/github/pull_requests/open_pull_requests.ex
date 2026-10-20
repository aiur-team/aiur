defmodule Aiur.GitHub.PullRequests.OpenPullRequests do
  @moduledoc """
  Reads over the open-pull-request listing (`GET /pulls?state=open`): the open
  pull request or requests for a ticket branch, and the ones carrying a label.
  """

  alias Aiur.GitHub.{Errors, Transport}
  alias Aiur.TicketBranch

  @doc """
  Fetches the open pull request whose legacy or readable Aiur head branch
  belongs to `issue_number`.

  ## One listing, not two

  This used to probe `?head=<owner>:aiur/<n>` first and fall back to scanning the
  open-pull-request listing. The probe was a strict subset of the fallback and so
  was pure duplication: the listing is filtered by `TicketBranch.ticket_branch?/2`,
  whose regex `\\Aaiur\\/([1-9]\\d*)(?:-[a-z0-9]+(?:-[a-z0-9]+)*)?\\z` accepts the
  legacy `aiur/<n>` spelling and the suffixed `aiur/<n>-<slug>` one alike, and the
  listing is paginated to exhaustion while the probe capped at ten. Anything the
  probe could find, the listing finds.

  It was not free. `Aiur.GitHub.Listeners.Comments.Driver.TargetSelection` calls this
  once per human-review target — up to 25 a cycle — so the probe was billing one
  primary-rate point per target per cycle to answer a question the very next
  request answered anyway. It was measured at roughly half of
  `GET /repos/:owner/:repo/pulls`, the single busiest REST call site in the
  daemon (`aiur github-cost --budget core`).

  The one behavioural difference is which pull request wins when a ticket has
  both a legacy-named and a suffixed open pull request: the probe preferred the
  legacy one, and the listing now prefers GitHub's own ordering, which is newest
  first. Preferring the newer of two open pull requests for one ticket is the
  better answer, not merely a different one.
  """
  @spec fetch_open_pull_request_for_branch(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      query = URI.encode_query(%{"state" => "open", "per_page" => "100"})

      fetch_open_ticket_pull_request(
        request_fun,
        token,
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls?#{query}",
        issue_number
      )
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

  @doc """
  Fetches every open pull request whose head branch belongs to `issue_number`.

  The singular `fetch_open_pull_request_for_branch/2` answers "does this ticket
  have an open PR?" with the newest match and is the right shape for a gate that
  needs one canonical PR. A ticket can legitimately have more than one open PR —
  two `aiur/<ticket>-<slug>` branches worked in parallel, where a merge of the
  first must not let the second be abandoned. This plural form lists them all,
  reusing the same paginated open-pull-request listing and the same
  `TicketBranch.ticket_branch?/2` head-branch filter, so callers that must
  consider every open PR (the merged-ticket reconciler) do not reimplement the
  lookup.
  """
  @spec fetch_open_pull_requests_for_branch(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests_for_branch(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      query = URI.encode_query(%{"state" => "open", "per_page" => "100"})

      fetch_open_ticket_pull_requests(
        request_fun,
        token,
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls?#{query}",
        issue_number,
        []
      )
    end
  end

  defp fetch_open_ticket_pull_requests(_request_fun, _token, nil, _issue_number, acc), do: {:ok, acc}

  defp fetch_open_ticket_pull_requests(request_fun, token, url, issue_number, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        headers = Map.get(response, :headers, [])
        matched = Enum.filter(body, &ticket_pull_request?(&1, issue_number))

        fetch_open_ticket_pull_requests(
          request_fun,
          token,
          Transport.parse_next_page_url(headers),
          issue_number,
          acc ++ matched
        )

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @doc """
  Fetches the open pull request for a ticket's head branch with `If-None-Match`
  support.

  The list-only `fetch_open_pull_request_for_branch/2` contract is unchanged.
  This variant exists so the three per-cycle call sites — comment-target
  selection, the comment poller and the CI poller — can revalidate the
  open-pull-request listing instead of paying full price for it every cycle.

  The validator belongs to the first page of the open-pull-request collection
  (`GET /pulls?state=open&per_page=100`); later pages ride along on a `200` and
  the found pull request is folded into the answer, so a `304` against the
  first page reuses the whole stored result.

  This is the one paginated read whose page-1 `304` is genuinely trustworthy
  (#2330): the question asked is "does this branch have an open PR?", which
  flips from `nil` to `PR` exactly when a PR is created for the branch — and a
  created PR is always the newest open PR, so it lands on page 1 and forces a
  `200`. A page-1 `304` therefore proves no branch PR appeared; a closure can
  lag the held answer but can never hide a new PR. (Contrast the removed
  watch-target label listing, which was `created` desc and read for *every*
  labelled PR, where a label on an older PR landed on page 2+.) A ticket with
  no open pull request answers `{:ok, nil, etag}`.
  """
  @spec fetch_open_pull_request_for_branch_conditional(String.t() | integer(), keyword()) ::
          {:ok, map() | nil, String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch_conditional(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      etag = Keyword.get(opts, :etag)
      query = URI.encode_query(%{"state" => "open", "per_page" => "100"})
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls?#{query}"

      case request_fun.(branch_pull_request_request(url, token, etag, opts)) do
        {:ok, %{status: 200, body: body} = response} when is_list(body) ->
          open_pull_request_list_page(request_fun, token, body, response, issue_number, etag, opts)

        {:ok, %{status: 304} = response} ->
          {:not_modified, Transport.header(Map.get(response, :headers, []), "etag") || etag}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  @doc """
  Fetches the full open-pull-request listing with a page-one ETag.

  Pollers that look up several ticket branches in one repository share the same
  `GET /pulls?state=open&per_page=100` response. Revalidating that one response
  avoids paying for a full listing each time a different ticket is checked.
  New open PRs land on page one, so its validator is sufficient to detect a new
  branch PR; later pages are fetched on a page-one change and then held with the
  result, matching the singular branch lookup's freshness contract.
  """
  @spec fetch_open_pull_requests_conditional(keyword()) ::
          {:ok, [map()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_open_pull_requests_conditional(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      etag = Keyword.get(opts, :etag)
      query = URI.encode_query(%{"state" => "open", "per_page" => "100"})
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls?#{query}"

      case request_fun.(branch_pull_request_request(url, token, etag, opts)) do
        {:ok, %{status: 200, body: body} = response} when is_list(body) ->
          headers = Map.get(response, :headers, [])
          first_etag = Transport.header(headers, "etag") || etag
          fetch_open_pull_request_pages(request_fun, token, Transport.parse_next_page_url(headers), body, first_etag, opts)

        {:ok, %{status: 304} = response} ->
          {:not_modified, Transport.header(Map.get(response, :headers, []), "etag") || etag}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  defp fetch_open_pull_request_pages(_request_fun, _token, nil, pull_requests, first_etag, _opts),
    do: {:ok, pull_requests, first_etag}

  defp fetch_open_pull_request_pages(request_fun, token, url, pull_requests, first_etag, opts) do
    case request_fun.(branch_pull_request_request(url, token, nil, opts)) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        headers = Map.get(response, :headers, [])

        fetch_open_pull_request_pages(
          request_fun,
          token,
          Transport.parse_next_page_url(headers),
          pull_requests ++ body,
          first_etag,
          opts
        )

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp branch_pull_request_request(url, token, etag, opts) do
    request = %{method: :get, url: url, token: token}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request
    Transport.put_caller(request, opts)
  end

  defp open_pull_request_list_page(request_fun, token, body, response, issue_number, etag, opts) do
    headers = Map.get(response, :headers, [])
    first_etag = Transport.header(headers, "etag") || etag

    case Enum.find(body, &ticket_pull_request?(&1, issue_number)) do
      nil ->
        fetch_open_ticket_pull_request_pages(
          request_fun,
          token,
          Transport.parse_next_page_url(headers),
          issue_number,
          first_etag,
          opts
        )

      pull_request ->
        {:ok, pull_request, first_etag}
    end
  end

  defp fetch_open_ticket_pull_request_pages(_request_fun, _token, nil, _issue_number, first_etag, _opts),
    do: {:ok, nil, first_etag}

  defp fetch_open_ticket_pull_request_pages(request_fun, token, url, issue_number, first_etag, opts) do
    case request_fun.(branch_pull_request_request(url, token, nil, opts)) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        headers = Map.get(response, :headers, [])

        case Enum.find(body, &ticket_pull_request?(&1, issue_number)) do
          nil ->
            fetch_open_ticket_pull_request_pages(
              request_fun,
              token,
              Transport.parse_next_page_url(headers),
              issue_number,
              first_etag,
              opts
            )

          pull_request ->
            {:ok, pull_request, first_etag}
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

  The listing is `created` desc, so a page-1 validator could never answer for
  a multi-page list — a label added to an older PR lands on page 2+ while
  page 1 answers `304` forever (#2330). Watch-target discovery therefore reads
  this listing **unconditionally**: correct beats quietly wrong, and the read
  is one per poll cycle (see website/docs-app/apis/github.md).
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

  @doc """
  Fetches every OPEN pull request for the repository, regardless of label.

  Unlike `fetch_open_pull_requests_by_label/2` this does not filter the list,
  so it is the scan the PR-health checks use: the unmergeable-author case is a
  PR opened by a configured human merger on any branch, and an ageing
  non-draft PR can be flagged whether or not its head is an `aiur/<id>` branch.

  Paginated through `per_page=100`; the caller is expected to have a bounded
  repo where one page (or a few) covers the open set.
  """
  @spec fetch_open_pull_requests(keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests(opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      query = URI.encode_query(%{"state" => "open", "per_page" => "100"})
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls?#{query}"
      fetch_all_open_pull_requests(request_fun, token, url, [])
    end
  end

  # Follows the GitHub `Link` `rel="next"` pagination, mirroring
  # `fetch_labeled_open_pull_requests/5`, so a repo with more than 100 open PRs
  # cannot silently hide an unmergeable or ageing PR past the first page.
  @spec fetch_all_open_pull_requests(function(), String.t(), String.t() | nil, [map()]) ::
          {:ok, [map()]} | {:error, term()}
  defp fetch_all_open_pull_requests(_request_fun, _token, nil, acc), do: {:ok, acc}

  defp fetch_all_open_pull_requests(request_fun, token, url, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        next = Transport.parse_next_page_url(headers)
        fetch_all_open_pull_requests(request_fun, token, next, acc ++ body)

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
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
end
