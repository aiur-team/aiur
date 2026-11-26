defmodule Aiur.GitHub.Issues.DispatchAuthorization do
  @moduledoc false

  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.TestTicketScope

  @spec authorize(Issue.t(), function(), String.t(), String.t(), String.t(), String.t(), keyword()) :: Issue.t()
  def authorize(%Issue{} = issue, request_fun, token, owner, repo, prefix, opts \\ []) do
    # Dispatch-time revalidation can observe a ticket that closed after the
    # open-candidate snapshot. Reject that terminal state before provenance
    # authorization buys a timeline read and raises an ambiguity alert.
    if DispatchPolicy.terminal_issue_state?(issue.state, DispatchPolicy.terminal_state_set()) do
      issue
    else
      DispatchAuthorization.authorize(
        issue,
        owner,
        repo,
        prefix,
        Keyword.merge([request_fun: request_fun, token: token], opts)
      )
    end
  end

  @spec authorize_dispatches([Issue.t()], function(), String.t(), String.t(), String.t(), String.t()) :: [Issue.t()]
  def authorize_dispatches(issues, request_fun, token, owner, repo, prefix) do
    issues
    |> TestTicketScope.filter_issues()
    |> Enum.map(fn issue ->
      authorize(issue, request_fun, token, owner, repo, prefix)
    end)
  end
end
