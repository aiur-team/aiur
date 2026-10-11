defmodule Aiur.OpenTicketSource.Fetch do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.{Issues, Transport}
  alias Aiur.Issue
  alias Aiur.OpenTicketSource.Snapshot

  @max_pages 10
  # Issue bodies are large on a planning-heavy repository, so the bootstrap
  # response is bounded rather than decoded in full.
  @max_response_bytes 4 * 1024 * 1024
  # The Tickets panel search matches descriptions as well as titles, and the
  # listing already carries every body on the wire — GitHub's REST issue list
  # returns `body` inline, so reading descriptions costs no extra request. Only
  # the head of each body is kept: this projection broadcasts to every
  # subscribed LiveView, so a ticket's summary lives in its opening lines and
  # the tail (checklists and logs) makes a search noisier rather than better.
  @body_excerpt_chars 1_000

  @spec fetch(map()) :: {:ok, [Snapshot.ticket()], boolean()} | {:error, term()} | :unsupported
  def fetch(state) do
    if state.github_fun.() do
      github_fetch(state)
    else
      :unsupported
    end
  end

  defp github_fetch(state) do
    with {:ok, {owner, repo}} <- state.repo_fun.(),
         {:ok, token} <- state.token_fun.() do
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=open&per_page=100"
      fetch_pages(state, url, token, owner, repo, [], @max_pages)
    else
      # A missing repo or token is a configuration fault, and every other failure
      # path here says why in the log; this one must not be the silent exception.
      {:error, reason} ->
        Logger.warning("Open ticket listing unavailable: #{inspect(reason)}")
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp fetch_pages(_state, _url, _token, _owner, _repo, acc, 0), do: {:ok, flatten(acc), true}

  defp fetch_pages(state, url, token, owner, repo, acc, pages_left) do
    request = %{method: :get, url: url, token: token, max_response_bytes: @max_response_bytes}

    case state.request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        tickets =
          body
          |> Enum.reject(&pull_request?/1)
          |> Enum.map(&ticket(Issues.normalize_issue(&1, owner, repo, state.label_prefix)))

        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, flatten([tickets | acc]), false}
          next_url -> fetch_pages(state, next_url, token, owner, repo, [tickets | acc], pages_left - 1)
        end

      {:ok, %{status: status}} ->
        Logger.warning("Open ticket listing failed status=#{status}")
        {:error, {:github_status, status}}

      {:error, reason} ->
        Logger.warning("Open ticket listing failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp flatten(pages), do: pages |> Enum.reverse() |> Enum.concat()

  # GitHub serves pull requests from the issues endpoint; only a `pull_request`
  # key distinguishes them, and the Tickets panel is about tickets.
  @spec pull_request?(term()) :: boolean()
  def pull_request?(gh_issue) when is_map(gh_issue), do: is_map(Map.get(gh_issue, "pull_request"))
  def pull_request?(_gh_issue), do: false

  @spec ticket(Issue.t()) :: Snapshot.ticket()
  def ticket(%Issue{} = issue) do
    %{
      identity: issue.tracker_identity,
      identifier: issue.identifier,
      title: issue.title,
      body_excerpt: body_excerpt(issue.description),
      url: issue.url,
      state: issue.state,
      labels: List.wrap(issue.labels),
      assignee: issue.assignee_id,
      created_at: issue.created_at,
      updated_at: issue.updated_at
    }
  end

  defp body_excerpt(description) when is_binary(description) do
    case description |> String.slice(0, @body_excerpt_chars) |> String.trim() do
      "" ->
        nil

      # `String.slice/3` and `String.trim/1` both return sub-binaries, which
      # keep the *whole* body alive behind a 1000-character window. Copying is
      # what actually applies the bound this design rests on.
      excerpt ->
        :binary.copy(excerpt)
    end
  end

  defp body_excerpt(_description), do: nil
end
