defmodule Aiur.Orchestrator.MergedTicketReconciler.StrandedWork do
  @moduledoc """
  Keeps a ticket open when its PR merges while the worker's checkout still
  holds commits the merged head does not (#4528).

  The merge queue can land a PR while its worker is still adding scope: the
  guard refuses pushes to a queued PR, so the new commits stay local. GitHub
  then closes the ticket and deletes the branch, and the merge route tears the
  worker down, stranding that work. Here the ticket is reopened as
  `in-progress` instead, and the worker is told to carry the commits to a new
  PR from the base branch. Any other merge takes the usual
  `CommentWake.mark_pr_merged_issue_done/3` path.
  """

  require Logger

  alias Aiur.{Alerts, Config}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.IssueReopen
  alias Aiur.Orchestrator.{CommentWake, Dispatcher, State, TicketTransition, TrackerTasks}
  alias Aiur.Orchestrator.OperatorMessages.Enqueue

  @spec mark_merged(State.t(), String.t() | integer(), keyword()) :: State.t()
  def mark_merged(%State{} = state, identifier, opts \\ []) do
    identifier = to_string(identifier)
    entry = State.find_running_by_identifier(state.running, identifier)
    workspace = if is_map(entry), do: Map.get(entry, :workspace_path)
    head_sha = Keyword.get(opts, :head_sha)

    if is_binary(workspace) and is_binary(head_sha) do
      TrackerTasks.run(
        state,
        {:stranded_work, identifier},
        fn -> check(identifier, workspace, head_sha, opts) end,
        fn current, result -> apply_check(current, identifier, result, opts) end
      )
    else
      CommentWake.mark_pr_merged_issue_done(state, identifier, opts)
    end
  end

  @doc "Non-merge commits on the checkout's HEAD that neither the merged head nor the base branch contains."
  @spec unmerged_commits(String.t(), String.t(), String.t() | nil) :: [String.t()]
  def unmerged_commits(workspace, head_sha, base \\ nil) do
    # Merges are skipped and the base excluded, so a base integration after the head is not new scope.
    args = ["-C", workspace, "rev-list", "--no-merges", "HEAD", "--not", head_sha, "origin/#{base || Config.base_branch()}"]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} ->
        String.split(out, "\n", trim: true)

      {out, status} ->
        Logger.info("stranded-work check skipped workspace=#{workspace} status=#{status} output=#{String.trim(out)}")
        []
    end
  rescue
    error ->
      Logger.info("stranded-work check skipped workspace=#{workspace} error=#{Exception.message(error)}")
      []
  end

  defp check(identifier, workspace, head_sha, opts) do
    case Keyword.get(opts, :unmerged_commits_fun, &unmerged_commits/2).(workspace, head_sha) do
      [] -> :merged
      commits -> {:stranded, commits, keep_open(identifier, opts)}
    end
  end

  defp keep_open(identifier, opts) do
    reopen = Keyword.get(opts, :reopen_issue_fun, &reopen_issue/1)
    write = Keyword.get(opts, :keep_open_state_fun, &TicketTransition.write_state(&1, "in-progress", writer: :stranded_work))

    with :ok <- reopen.(identifier), do: write.(identifier)
  end

  defp reopen_issue(identifier), do: if(Dispatcher.github_tracker_kind?(), do: IssueReopen.reopen(identifier), else: :ok)

  defp apply_check(state, identifier, :merged, opts), do: CommentWake.mark_pr_merged_issue_done(state, identifier, opts)

  # The worker is never torn down here, even when the reopen failed: it still holds the only copy of the work.
  defp apply_check(state, identifier, {:stranded, commits, kept_open}, opts) do
    pr = if is_integer(opts[:pr_number]), do: "PR ##{opts[:pr_number]}", else: "The PR"
    Logger.warning("PR merged with stranded commits: issue_identifier=#{identifier} commits=#{length(commits)} kept_open=#{inspect(kept_open)}")
    alert(identifier, pr, commits, kept_open, opts)
    {_queued, state} = Enqueue.enqueue_operator_message(state, identifier, worker_message(identifier, pr, commits, opts), %{}, :plain)
    mark_merge_reconciled(state, identifier, opts)
  end

  defp worker_message(identifier, pr, commits, opts) do
    base = Config.base_branch()

    "#{pr} merged at #{String.slice(opts[:head_sha], 0, 9)} while your checkout held #{length(commits)} commit(s) it does not contain: " <>
      "#{Enum.map_join(commits, ", ", &String.slice(&1, 0, 9))}. GitHub closed ticket ##{identifier} and deleted its branch; " <>
      "Aiur reopened the ticket as in-progress so this work is not lost. Rebase those commits onto origin/#{base} " <>
      "(drop anything the merge already landed), push the branch, and open a new PR against #{base} with `Closes ##{identifier}`. " <>
      "If nothing remains after the rebase, move the ticket to done."
  end

  defp alert(identifier, pr, commits, kept_open, opts) do
    {message, reason, needs_attention} =
      case kept_open do
        :ok ->
          {"#{pr} merged while worker ##{identifier} held #{length(commits)} newer commit(s); reopened the ticket and told the worker to open a new PR",
           "Work committed after the queued head would otherwise be stranded.", false}

        {:error, error} ->
          {"#{pr} merged while worker ##{identifier} held #{length(commits)} newer commit(s), but Aiur could not reopen the ticket (#{inspect(error)})",
           "The worker was told to open a new PR. Remedy: reopen the ticket and set it in-progress, or the next poll stops the worker.", true}
      end

    Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2).(
      "ticket.#{identifier}.agent.attention.merged_with_stranded_work",
      issue: identifier,
      message: message,
      reason: reason,
      needs_attention: needs_attention,
      severity: if(needs_attention, do: "warning", else: "info")
    )
  end

  # Stops the poll-cycle reconciler from closing the reopened ticket again for the same merge this run.
  defp mark_merge_reconciled(state, identifier, opts) do
    with number when is_integer(number) <- opts[:pr_number],
         repo when is_binary(repo) <- Keyword.get(opts, :repo_fun, &GitHubConfig.repo/0).() do
      %{state | merged_ticket_reconciliations: MapSet.put(state.merged_ticket_reconciliations, {identifier, "#{repo}##{number}"})}
    else
      _unknown -> state
    end
  end
end
