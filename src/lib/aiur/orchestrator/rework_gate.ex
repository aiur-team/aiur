defmodule Aiur.Orchestrator.ReworkGate do
  @moduledoc """
  The precondition every `agent:rework` transition must satisfy.

  `rework` means "work exists and was rejected" — a reviewer (or CI) rejected
  existing work. A ticket with no open pull request has nothing a reviewer
  could have rejected, so stamping it `rework` asserts a verdict that never
  happened: the agent wastes a dispatch discovering there is nothing to rework
  (#1844), and the flip can transiently leave the ticket carrying two state
  labels, silently undispatchable (#2075).

  This module is the single place that verifies the "an open PR exists"
  precondition. Each rework writer calls it before writing `rework`, and each
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

  defp github_client_exported? do
    client = Application.get_env(:aiur, :github_client_module, GitHubClient)

    Code.ensure_loaded?(client) and
      function_exported?(client, :fetch_open_pull_request_for_branch, 1)
  end
end
