defmodule Aiur.AgentRunner.ApprovedHandoff do
  @moduledoc """
  Redirects a worker's human-review handback to ci-wait when the PR is already
  approved and that approval carries to the current head (#4965).

  Such a ticket waits only on CI; parking it in human-review hides it from the
  landing path. A rework handback keeps human-review: the reviewer asked for it.
  Anything unreadable keeps human-review.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.ReworkGate

  @spec target_state(Issue.t(), String.t(), keyword()) :: String.t()
  def target_state(%Issue{} = issue, "human-review", opts) do
    case ReworkGate.open_pr(issue.identifier, opts) do
      {:ok, pr} ->
        if ReworkGate.post_agent_handoff_target(pr, "human-review", opts) == "ci-wait",
          do: "ci-wait",
          else: "human-review"

      _ ->
        "human-review"
    end
  end

  def target_state(_issue, state, _opts), do: state
end
