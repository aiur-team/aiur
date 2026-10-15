defmodule Aiur.AgentRunner.ReworkHandoff do
  @moduledoc false

  alias Aiur.AgentRunner.{TurnAlerts, TurnLoop}
  alias Aiur.CodeHost
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator.{DispatchPolicy, ReworkGate, TicketTransition}

  @spec after_turn(Aiur.Issue.t(), map(), (-> term())) :: term()
  def after_turn(issue, turn_context, continue) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "rework",
      do: handoff_if_ready(issue, turn_context, continue),
      else: continue.()
  end

  defp handoff_if_ready(issue, turn_context, continue) do
    if ReworkGate.operator_queue_empty?(turn_context.orchestrator, issue.identifier),
      do: handoff_completed_turn(issue, turn_context, continue),
      else: continue.()
  end

  defp handoff_completed_turn(issue, turn_context, continue) do
    opts = turn_context.opts

    case ReworkGate.completed_agent_handoff(issue.identifier, Keyword.get(opts, :rework_head_sha),
           open_pr_fetcher: Keyword.get(opts, :open_pr_fetcher, &CodeHost.fetch_open_pull_request_for_branch/1),
           commit_ci_status_fetcher: Keyword.get(opts, :commit_ci_status_fetcher, &GitHubClient.fetch_commit_ci_status/1)
         ) do
      {:handoff, state} -> write_handoff(issue, turn_context, state)
      :none -> continue.()
    end
  end

  defp write_handoff(issue, turn_context, state) do
    case TicketTransition.write_state(issue.identifier, state, writer: :turn_loop) do
      :ok ->
        TurnAlerts.emit_rework_handoff_alert(issue, turn_context.workspace, turn_context.worker_host, state)
        TurnLoop.return_completed(turn_context, %{issue | state: state})

      {:error, reason} ->
        {:error, {:rework_handoff_state_write_failed, reason}}
    end
  end
end
