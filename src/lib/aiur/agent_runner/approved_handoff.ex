defmodule Aiur.AgentRunner.ApprovedHandoff do
  @moduledoc """
  Redirects a worker's human-review handback to ci-wait when the PR is already
  approved and that approval carries to the current head (#4965).

  Such a ticket waits only on CI; parking it in human-review hides it from the
  landing path. A rework handback keeps human-review: the reviewer asked for it.
  Anything unreadable keeps human-review.
  """

  alias Aiur.Events.GithubCIPoller
  alias Aiur.GitHub.HumanReviewGate
  alias Aiur.Issue
  alias Aiur.Orchestrator.ReworkGate

  @spec target_state(Issue.t(), String.t(), keyword()) :: String.t()
  def target_state(%Issue{state: issue_state} = issue, "human-review", opts) when issue_state not in ["rework", "agent:rework"] do
    approval = Keyword.get(opts, :pull_request_approval_fetcher, &default_approval/1)
    classifier = Keyword.get(opts, :approval_carry_classifier, &GithubCIPoller.classify_approval_carry/4)

    with {:ok, %{"number" => number}} when is_integer(number) <- ReworkGate.open_pr(issue.identifier, opts),
         {:ok, {head, approved}} when is_binary(approved) <- approval.(number),
         :carried <- carried(classifier, approved, head, number) do
      "ci-wait"
    else
      _ -> "human-review"
    end
  end

  def target_state(_issue, state, _opts), do: state

  defp carried(_classifier, head, head, _number), do: :carried
  defp carried(classifier, approved, head, number), do: classifier.(approved, head, number, [])

  defp default_approval(number) do
    if ReworkGate.available?(), do: HumanReviewGate.pull_request_approval(number, caller: "approved_handoff"), else: {:error, :unavailable}
  end
end
