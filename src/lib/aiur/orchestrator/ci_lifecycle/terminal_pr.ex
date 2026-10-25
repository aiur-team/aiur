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
    if Transition.effective_ci_state(issue) == "ci-wait" and terminal_pr?(result) do
      route_terminal(state, issue, result)
    else
      continue.()
    end
  end

  @doc false
  @spec terminal_pr?(map()) :: boolean()
  def terminal_pr?(%{pull_request: %{"state" => state}}), do: state in ["merged", "closed"]
  def terminal_pr?(_result), do: false

  defp route_terminal(state, issue, result) do
    cause = result.pull_request["state"]
    target = to_string(issue.identifier || issue.id)
    message = terminal_message(cause, result.pull_request["number"])

    Transition.transition_ci_ticket(state, issue, "rework", fn transitioned ->
      case Aiur.Tracker.create_comment(target, message) do
        :ok -> :ok
        other -> Logger.warning("Terminal PR rework comment not posted: issue=#{target} reason=#{inspect(other)}")
      end

      Reconciler.refresh_running_issue_state(transitioned, %{issue | state: "rework"})
    end)
  end

  defp terminal_message("merged", number),
    do: "PR ##{number} merged, but this ticket remains open. Returning it to rework for remaining acceptance work."

  defp terminal_message("closed", number),
    do: "PR ##{number} closed without merging (`pr_closed_unmerged`). Returning this ticket to rework for triage."
end
