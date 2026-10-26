defmodule Aiur.Orchestrator.CiLifecycle.TerminalPR do
  @moduledoc false

  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State
  require Logger

  @doc false
  @spec route(State.t(), Issue.t(), map(), (-> State.t())) :: State.t()
  def route(state, issue, result, continue) do
    if terminal_pr?(result) and (Transition.effective_ci_state(issue) == "ci-wait" or closed_ci_wait?(issue, result)) do
      route_terminal(state, issue, result)
    else
      continue.()
    end
  end

  @doc false
  @spec terminal_pr?(map()) :: boolean()
  def terminal_pr?(%{pull_request: %{"state" => state}}), do: state in ["merged", "closed"]
  def terminal_pr?(%{pending_reason: reason}), do: reason in [:pr_merged, :pr_closed_unmerged]
  def terminal_pr?(_result), do: false

  defp route_terminal(state, issue, result) do
    cause = result.pull_request["state"]
    target = to_string(issue.identifier || issue.id)
    closes_issue = cause == "merged" and closes_issue?(result.pull_request, target)
    message = terminal_message(cause, result.pull_request["number"], closes_issue)
    next_state = if closes_issue, do: "done", else: "rework"

    Transition.transition_ci_ticket(state, issue, next_state, fn transitioned ->
      post_terminal_comment(issue, target, message)
      Reconciler.refresh_running_issue_state(transitioned, %{issue | state: next_state})
    end)
  end

  defp post_terminal_comment(issue, target, message) do
    if closed_issue?(issue) do
      :ok
    else
      case Aiur.Tracker.create_comment(target, message) do
        :ok -> :ok
        other -> Logger.warning("Terminal PR rework comment not posted: issue=#{target} reason=#{inspect(other)}")
      end
    end
  end

  defp terminal_message("merged", number, true),
    do: "PR ##{number} merged and closes this ticket. Marking it done."

  defp terminal_message("merged", number, false),
    do: "PR ##{number} merged, but this ticket remains open. Returning it to rework for remaining acceptance work."

  defp terminal_message("closed", number, _closes_issue),
    do: "PR ##{number} closed without merging (`pr_closed_unmerged`). Returning this ticket to rework for triage."

  defp closes_issue?(pull_request, target) do
    target in Enum.map(List.wrap(pull_request["closing_issue_numbers"]), &to_string/1)
  end

  defp closed_ci_wait?(issue, %{pull_request: %{"state" => "merged"}}) do
    closed_issue?(issue) and "ci-wait" in List.wrap(issue.state_labels)
  end

  defp closed_ci_wait?(_issue, _result), do: false

  defp closed_issue?(issue), do: String.downcase(to_string(issue.state || "")) == "closed"
end
