defmodule Aiur.Orchestrator.MergedTicketReconciler.StrandedWork do
  @moduledoc """
  Keeps a ticket open when its PR merges while the worker's checkout still
  holds commits the merged head does not (#4528).

  The merge queue can land a PR while its worker is still adding scope: the
  guard refuses pushes to a queued PR, so the new commits stay local. GitHub
  then closes the ticket and deletes the branch, and the merge route tears the
  worker down, stranding that work. Here the ticket is reopened as
  `in-progress` instead, and the worker is told to carry the commits to a new
  PR from the base branch. Only a merge that would otherwise move the ticket to
  `done` is checked; any other merge takes the usual
  `CommentWake.mark_pr_merged_issue_done/3` path.
  """

  require Logger

  alias Aiur.{Alerts, Config, Tracker}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.LocalHold
  alias Aiur.Orchestrator.{CommentWake, State, TicketTransition, TrackerTasks}
  alias Aiur.Orchestrator.OperatorMessages.Enqueue

  @spec mark_merged(State.t(), String.t() | integer(), keyword()) :: State.t()
  def mark_merged(%State{} = state, identifier, opts \\ []) do
    identifier = to_string(identifier)
    entry = State.find_running_by_identifier(state.running, identifier)
    workspace = if is_map(entry), do: Map.get(entry, :workspace_path)
    head_sha = Keyword.get(opts, :head_sha)

    # The SHA becomes a git argument, so only a hex object id is accepted.
    if is_binary(workspace) and is_binary(head_sha) and head_sha =~ ~r/\A[0-9a-f]{7,64}\z/ do
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

  @doc """
  Non-merge commits on the checkout's HEAD that neither the merged head nor the
  base branch contains, and whose patch the merged head does not already carry.
  """
  @spec unmerged_commits(String.t(), String.t(), String.t() | nil) :: [String.t()]
  def unmerged_commits(workspace, head_sha, base \\ nil) do
    # Merges are skipped and the base excluded, so a base integration after the head is not new scope.
    # `git cherry` marks patch-equivalent commits `-`, so a local rebase of the queued commits is not either.
    with {:ok, candidates} <- git(workspace, ["rev-list", "--no-merges", "HEAD", "--not", head_sha, "origin/#{base || Config.base_branch()}"]),
         {:ok, cherry} <- git(workspace, ["cherry", head_sha, "HEAD"]) do
      new_patches = MapSet.new(for "+ " <> sha <- cherry, do: sha)
      Enum.filter(candidates, &MapSet.member?(new_patches, &1))
    else
      :skipped -> []
    end
  end

  defp git(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {out, 0} ->
        {:ok, String.split(out, "\n", trim: true)}

      {out, status} ->
        Logger.info("stranded-work check skipped workspace=#{workspace} status=#{status} output=#{String.trim(out)}")
        :skipped
    end
  rescue
    error ->
      Logger.info("stranded-work check skipped workspace=#{workspace} error=#{Exception.message(error)}")
      :skipped
  end

  # A merge that leaves another open PR, or only `Refs` the ticket, keeps its own routing.
  defp check(identifier, workspace, head_sha, opts) do
    case LocalHold.run(fn -> CommentWake.merged_issue_target_state(identifier, opts) end, LocalHold.caller_opts(opts)) do
      "done" -> stranded(identifier, workspace, head_sha, opts)
      target when is_binary(target) -> {:merged, target}
      {:error, _reason} -> {:merged, nil}
    end
  end

  defp stranded(identifier, workspace, head_sha, opts) do
    case Keyword.get(opts, :unmerged_commits_fun, &unmerged_commits/2).(workspace, head_sha) do
      [] -> {:merged, "done"}
      commits -> {:stranded, commits, keep_open(identifier, opts)}
    end
  end

  # Both writes wait out a budget hold as long as the `done` write does: giving up leaves the ticket closed.
  defp keep_open(identifier, opts) do
    reopen = Keyword.get(opts, :reopen_issue_fun, &Tracker.reopen_issue/1)
    write = Keyword.get(opts, :keep_open_state_fun, &TicketTransition.write_state(&1, "in-progress", writer: :stranded_work))
    hold_opts = LocalHold.caller_opts(Keyword.put(opts, :local_hold_max_wait_ms, 3_600_000))

    with {:reopen, :ok} <- {:reopen, LocalHold.run(fn -> reopen.(identifier) end, hold_opts)},
         {:state_write, :ok} <- {:state_write, LocalHold.run(fn -> write.(identifier) end, hold_opts)} do
      :ok
    else
      {step, {:error, error}} -> {:error, {step, error}}
    end
  end

  defp apply_check(state, identifier, {:merged, nil}, opts), do: CommentWake.mark_pr_merged_issue_done(state, identifier, opts)

  defp apply_check(state, identifier, {:merged, target}, opts),
    do: CommentWake.mark_pr_merged_issue_done(state, identifier, Keyword.put(opts, :target_state, target))

  # The check crashed or timed out, so whether work is stranded is unknown: keep the worker and ask the Executor.
  defp apply_check(state, identifier, {:error, reason}, opts) do
    Logger.warning("stranded-work check failed: issue_identifier=#{identifier} reason=#{inspect(reason)}")

    Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2).(
      "ticket.#{identifier}.agent.attention.merged_with_stranded_work",
      issue: identifier,
      message: "The PR for ##{identifier} merged, but Aiur could not check the worker's checkout for unmerged commits (#{inspect(reason)})",
      reason: "The worker was kept running. Remedy: check its checkout for commits after the merged head, then reopen the ticket or move it to done.",
      needs_attention: true,
      severity: "warning"
    )

    state
  end

  # The worker is never torn down here, even when the reopen failed: it still holds the only copy of the work.
  defp apply_check(state, identifier, {:stranded, commits, kept_open}, opts) do
    key = reconciliation_key(identifier, opts)

    # The webhook and the poll reconciler can both check one merge; only the first one reports it.
    if key && MapSet.member?(state.merged_ticket_reconciliations, key) do
      state
    else
      pr = if is_integer(opts[:pr_number]), do: "PR ##{opts[:pr_number]}", else: "The PR"
      Logger.warning("PR merged with stranded commits: issue_identifier=#{identifier} commits=#{length(commits)} kept_open=#{inspect(kept_open)}")
      alert(identifier, pr, commits, kept_open, opts)
      message = worker_message(identifier, pr, commits, kept_open, opts)
      {_queued, state} = Enqueue.enqueue_operator_message(state, identifier, message, %{}, :plain)
      # Stops the poll-cycle reconciler from closing the reopened ticket again for the same merge this run.
      if key, do: %{state | merged_ticket_reconciliations: MapSet.put(state.merged_ticket_reconciliations, key)}, else: state
    end
  end

  defp worker_message(identifier, pr, commits, kept_open, opts) do
    base = Config.base_branch()

    status =
      case kept_open do
        :ok -> "Aiur reopened the ticket as in-progress so this work is not lost."
        {:error, {:reopen, _}} -> "Aiur could not reopen the ticket and asked the Executor to; until then a poll may stop you."
        {:error, {:state_write, _}} -> "Aiur reopened the ticket but could not set it in-progress and asked the Executor to."
      end

    "#{pr} merged at #{String.slice(opts[:head_sha], 0, 9)} while your checkout held #{length(commits)} commit(s) it does not contain: " <>
      "#{Enum.map_join(commits, ", ", &String.slice(&1, 0, 9))}. GitHub closed ticket ##{identifier} and deleted its branch. " <>
      "#{status} Rebase those commits onto origin/#{base} " <>
      "(drop anything the merge already landed), push the branch, and open a new PR against #{base} with `Closes ##{identifier}`. " <>
      "If nothing remains after the rebase, move the ticket to done."
  end

  defp alert(identifier, pr, commits, kept_open, opts) do
    held = "#{pr} merged while worker ##{identifier} held #{length(commits)} newer commit(s)"

    {message, reason, needs_attention} =
      case kept_open do
        :ok ->
          {"#{held}; reopened the ticket and told the worker to open a new PR", "Work committed after the queued head would otherwise be stranded.", false}

        {:error, {:reopen, error}} ->
          {"#{held}, but Aiur could not reopen the ticket (#{inspect(error)})",
           "The worker was told to open a new PR. Remedy: reopen the ticket and set it in-progress, or the next poll stops the worker.", true}

        {:error, {:state_write, error}} ->
          {"#{held}; Aiur reopened the ticket but could not set it in-progress (#{inspect(error)})", "The issue is open but keeps its pre-merge label. Remedy: set the ticket in-progress.", true}
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

  defp reconciliation_key(identifier, opts) do
    with number when is_integer(number) <- opts[:pr_number],
         repo when is_binary(repo) <- Keyword.get(opts, :repo_fun, &GitHubConfig.repo/0).() do
      {identifier, "#{repo}##{number}"}
    else
      _unknown -> nil
    end
  end
end
