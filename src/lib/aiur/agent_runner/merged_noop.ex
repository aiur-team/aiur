defmodule Aiur.AgentRunner.MergedNoop do
  @moduledoc """
  Hands a ticket to human review when its pull request is merged and a worker
  turn changes nothing.

  A merged PR leaves the ticket with no open PR, so the worker cannot hand it
  back and the no-op stop kept the active label. The ticket was dispatched
  again every few minutes until the no-op limit ended it in `agent:error`
  (open-games #432, #480, #511, #518, #520). Whether the ticket is done or has
  work left is a person's call, so it goes to `human-review` with the worker's
  last message instead of taking more turns.
  """

  alias Aiur.AgentRunner.{StoppedSessionPrompt, TurnLoop}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator.{ReworkGate, TicketTransition}

  @doc "Writes the review handback when the ticket's branch has a merged PR and no open one."
  @spec handoff(map(), Aiur.Issue.t(), map()) :: {:handoff, term()} | :none
  def handoff(turn_context, issue, progress) do
    case merged_pull_request(issue, turn_context.workspace, turn_context.opts) do
      %{"number" => number} -> {:handoff, write_handoff(turn_context, issue, number, progress)}
      nil -> :none
    end
  end

  defp merged_pull_request(issue, workspace, opts) do
    open_fetcher = Keyword.get(opts, :open_pr_fetcher, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1)
    merged_fetcher = Keyword.get(opts, :merged_pr_fetcher, &GitHubClient.fetch_merged_pull_request_for_branch/1)

    with {:skip, :no_open_pr} <- ReworkGate.open_pr(issue.identifier, open_pr_fetcher: open_fetcher),
         branch when is_binary(branch) <- workspace_branch(workspace),
         {:ok, %{"number" => number} = pr} when is_integer(number) <- merged_fetcher.(branch) do
      pr
    else
      _open_unknown_or_unmerged -> nil
    end
  end

  defp workspace_branch(workspace) when is_binary(workspace) do
    case System.cmd("git", ["-C", workspace, "branch", "--show-current"], stderr_to_stdout: true) do
      {branch, 0} -> if String.trim(branch) == "", do: nil, else: String.trim(branch)
      _not_a_checkout -> nil
    end
  rescue
    _error -> nil
  end

  defp workspace_branch(_workspace), do: nil

  defp write_handoff(turn_context, issue, number, progress) do
    body = """
    PR ##{number} is merged and the worker's last #{turns(progress.consecutive_noops)} changed nothing, so this ticket moves to human-review instead of being dispatched again. Close it if the work is complete, or say what remains.

    Worker's last message:
    #{StoppedSessionPrompt.last_agent_message(turn_context.workspace, issue.identifier)}
    """

    with :ok <- TicketTransition.write_comment(issue.identifier, body, writer: :turn_loop),
         :ok <- TicketTransition.write_state(issue.identifier, "human-review", writer: :turn_loop) do
      TurnLoop.return_completed(turn_context, %{issue | state: "human-review"})
    else
      {:error, reason} -> {:error, {:merged_noop_handoff_failed, reason}}
    end
  end

  defp turns(1), do: "turn"
  defp turns(count), do: "#{count} turns"
end
