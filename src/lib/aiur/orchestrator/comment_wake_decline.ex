defmodule Aiur.Orchestrator.CommentWakeDecline do
  @moduledoc false

  alias Aiur.Issue

  @spec reason_details(Issue.t(), boolean()) :: String.t()
  def reason_details(issue, running?) do
    case {issue.paused, issue.parked, Issue.executor_owner(issue), running?} do
      {true, _, _, _} -> "issue is paused"
      {_, true, _, _} -> "issue is parked"
      {_, _, owner, _} when is_binary(owner) -> "issue is Executor-owned"
      {_, _, _, true} -> "issue is already running"
      _ -> "dispatch policy does not permit this state"
    end
  end

  @spec describe(String.t(), Issue.t()) :: String.t()
  def describe("issue is paused", _issue),
    do: "Dispatch policy refused to wake the paused issue. Remedy: resume the issue, then retry the comment delivery."

  def describe("issue is parked", _issue),
    do: "Dispatch policy refused to wake the parked issue. Remedy: resume it explicitly to clear the park marker."

  def describe("issue is Executor-owned", issue),
    do: "Dispatch policy refused to wake this ticket, held by #{Issue.executor_owner(issue)}. Remedy: release the Executor hold first."

  def describe("issue is already running", _issue),
    do: "Dispatch policy refused a duplicate wake for an issue with a running agent. Remedy: let that agent finish or send the comment to its session."

  def describe(_details, issue),
    do: "Dispatch policy refused the issue in state #{inspect(issue.state)}. Remedy: move it to an active state eligible for dispatch, then retry the comment delivery."
end
