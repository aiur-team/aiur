defmodule Aiur.Orchestrator.ReworkGate do
  @moduledoc """
  The precondition every `agent:rework` transition must satisfy.

  `rework` means "work exists and was rejected" — a reviewer (or CI) rejected
  existing work. A ticket with no open pull request has nothing a reviewer
  could have rejected, so stamping it `rework` asserts a verdict that never
  happened: the agent wastes a dispatch discovering there is nothing to rework
  (#1844), and the flip can transiently leave the ticket carrying two state
  labels, silently undispatchable (#2075).

  Since #2422 / #2450 the gate also decides *whether a reviewer is currently
  asking for a change*: routing on unresolved review threads, not on GitHub's
  sticky `reviewDecision`. A `CHANGES_REQUESTED` verdict never clears when
  findings are addressed, so it cannot distinguish "outstanding findings" from
  "was once told to change something" — routing rework on it re-enters
  `agent:rework` forever. This module is the single place that verifies these
  preconditions. Each rework writer calls it before writing `rework`, and each
  names the precondition in a test so a future writer cannot be added without
  stating one.
  """

  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Tracker

  @doc """
  Verifies that the rework target still has an open pull request.

  Returns:
    * `:ok` — an open PR exists, so a rework verdict is meaningful;
    * `{:skip, :no_open_pr}` — the ticket has no open PR; rework must be
      refused at the source;
    * `{:error, reason}` — the PR lookup itself failed transiently; callers
      decide whether to retry or park.
  """
  @spec verify_open_pr(String.t() | integer(), keyword()) ::
          :ok | {:skip, :no_open_pr} | {:error, term()}
  def verify_open_pr(issue_key, opts \\ []) do
    fetcher = Keyword.get(opts, :open_pr_fetcher, &default_fetcher/1)

    case fetcher.(to_string(issue_key)) do
      {:ok, %{} = _pr} -> :ok
      {:ok, _no_open_pr} -> {:skip, :no_open_pr}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Decides whether an open pull request is currently a rework target.

  `rework` means "a reviewer is currently asking for a change", and the only
  signal that reliably answers that is unresolved review threads: GitHub's
  `reviewDecision` is sticky by design — a `CHANGES_REQUESTED` verdict never
  clears when findings are addressed — so it cannot distinguish "outstanding
  findings" from "was once told to change something" (#2422, #2450). A pull
  request whose review threads are all resolved (or that has none) is not a
  rework target, whatever its verdict says.

  This is the per-PR form of the rule, for callers that already hold the
  open-PR listing (e.g. `MergedTicketReconciler`). The thread read is
  injectable via `:unresolved_threads_fetcher` for tests; the default routes
  through the tracker boundary, which fails open to "no threads" where the
  tracker has no PR/thread notion.

  Returns:
    * `{:ok, :rework}` — the PR has unresolved review threads, so routing it to
      rework is justified;
    * `{:skip, :no_unresolved_review_threads}` — the PR's threads are all
      resolved (or it has none); the reviewer is not currently asking for a
      change, so rework must be refused;
    * `{:error, reason}` — the thread read failed transiently; callers decide
      whether to retry or park.
  """
  @spec open_pull_request_rework_verdict(map(), keyword()) ::
          {:ok, :rework} | {:skip, :no_unresolved_review_threads} | {:error, term()}
  def open_pull_request_rework_verdict(pull_request, opts \\ []) do
    threads_fetcher = Keyword.get(opts, :unresolved_threads_fetcher, &default_threads_fetcher/1)

    case pull_request do
      %{} ->
        case threads_fetcher.(pull_request) do
          {:ok, comments} when is_list(comments) and comments != [] -> {:ok, :rework}
          {:ok, _no_unresolved_threads} -> {:skip, :no_unresolved_review_threads}
          {:error, reason} -> {:error, reason}
        end

      # A PR that is not a map has nothing a reviewer could have rejected.
      _non_map ->
        {:skip, :no_unresolved_review_threads}
    end
  end

  @doc false
  # The gate only applies where an open-PR lookup is actually meaningful: the
  # GitHub tracker behind a client that can answer `fetch_open_pull_request_for_branch/1`.
  # Non-GitHub trackers and stub/fake clients (which predate this gate) fail
  # open — they have no notion of a PR, so the rework writers keep their legacy
  # behaviour there, and the precondition is still pinned by the dedicated tests.
  @spec available?() :: boolean()
  def available? do
    Tracker.adapter() == GitHubTracker and
      github_client_exported?()
  end

  defp default_fetcher(issue_key) do
    if available?() do
      Tracker.fetch_open_pull_request_for_branch(issue_key)
    else
      {:ok, %{}}
    end
  end

  # The default unresolved-thread read routes through the tracker boundary so a
  # non-GitHub tracker or stub client answers `{:ok, []}` (no threads) rather
  # than reaching for a GitHub fetch that cannot answer; a live GitHub tracker
  # resolves the real GraphQL read via `Tracker`. A PR without a number cannot
  # be checked, so it fails open to "no threads" — the caller that holds a
  # PR listing without numbers has no rework signal to act on either way.
  defp default_threads_fetcher(%{} = pull_request) do
    case pull_request_number(pull_request) do
      nil -> {:ok, []}
      number -> Tracker.fetch_unaddressed_pr_review_thread_comments(number)
    end
  end

  defp default_threads_fetcher(_pull_request), do: {:ok, []}

  defp pull_request_number(%{"number" => number}) when is_integer(number), do: number
  defp pull_request_number(%{number: number}) when is_integer(number), do: number
  defp pull_request_number(_pull_request), do: nil

  defp github_client_exported? do
    client = Application.get_env(:aiur, :github_client_module, GitHubClient)

    Code.ensure_loaded?(client) and
      function_exported?(client, :fetch_open_pull_request_for_branch, 1)
  end
end
