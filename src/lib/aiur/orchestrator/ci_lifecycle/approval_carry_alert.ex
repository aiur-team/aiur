defmodule Aiur.Orchestrator.CiLifecycle.ApprovalCarryAlert do
  @moduledoc """
  Raises or records `stale_approved_pr_head` for a push made after approval (#4668).

  Each `{approved head, new head}` pair is classified once, outside the
  orchestrator. A carried approval is recorded on the PR as a comment and
  as an informational `pr.approval_carried` alert; any other verdict raises the attention with the
  differing hunks in its reason.
  """

  alias Aiur.Alerts
  alias Aiur.Events.GithubCIPoller
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Poll
  alias Aiur.Orchestrator.State

  @max_reason_hunks 10
  @max_hunk_lines 12

  @doc false
  @spec handle(State.t(), Issue.t(), map(), keyword()) :: State.t()
  def handle(%State{} = state, %Issue{} = issue, result, opts) do
    target = CiLifecycle.ci_target_for_issue(issue)
    pair = {result[:approved_review_head_sha], result[:head_sha]}
    carries = Map.get(state.ci_lifecycle, :approval_carries, %{})

    cond do
      Aiur.Instance.skip?(issue.identifier, issue.labels, :approval_carry_alert) ->
        state

      Map.get(carries, target) == pair ->
        state

      is_binary(elem(pair, 0)) and is_integer(result[:pr_number]) ->
        state = put_in(state.ci_lifecycle[:approval_carries], Map.put(carries, target, pair))
        classifier = Keyword.get(opts, :approval_carry_classifier, &GithubCIPoller.classify_approval_carry/4)
        {approved, head} = pair

        Poll.run_ci_effect(state, issue, :approval_carry, fn -> classify(classifier, approved, head, result[:pr_number], opts) end, fn current, verdict ->
          emit(issue, result, verdict)
          current
        end)

      true ->
        emit(issue, result, {:changed, %{reason: :approved_head_unknown, hunks: []}})
        put_in(state.ci_lifecycle[:approval_carries], Map.put(carries, target, pair))
    end
  end

  # ponytail: the pair cache is in memory, so a daemon restart re-classifies and may post a second carried comment.
  defp classify(classifier, approved, head, pr_number, opts) do
    verdict = classifier.(approved, head, pr_number, opts)

    if verdict == :carried do
      commenter = Keyword.get(opts, :approval_carry_commenter, &GitHubClient.create_comment/2)
      _ = commenter.(to_string(pr_number), "Aiur carried the approval from `#{approved}` to `#{head}`: the contribution diff is unchanged.")
    end

    verdict
  end

  # Not an `agent.attention.*` topic: those bind to the Executor as attentions regardless of `needs_attention`.
  defp emit(issue, result, :carried) do
    Alerts.emit_system("ticket.#{issue.identifier}.pr.approval_carried",
      issue: issue.identifier,
      message: "Approval carried to the new PR head for #{issue.identifier}.",
      reason: "The push after approval left the contribution diff unchanged and the PR body Tested head names the new head.",
      needs_attention: false,
      severity: "info",
      central: true,
      head_sha: result[:head_sha]
    )
  end

  defp emit(issue, result, {:changed, %{reason: reason, hunks: hunks}}) do
    Alerts.emit_system("ticket.#{issue.identifier}.agent.attention.stale_approved_pr_head",
      issue: issue.identifier,
      message: "The PR head for #{issue.identifier} changed after its last green CI head.",
      reason: "#{changed_reason(reason)} Keep the ticket out of rework until fresh CI and review establish the status of the new head." <> render_hunks(hunks),
      needs_attention: true,
      severity: "critical",
      central: true,
      head_sha: result[:head_sha]
    )
  end

  defp changed_reason(:contribution_changed), do: "The push changed the PR's own contribution diff, so the approval was not carried."
  defp changed_reason(:tested_head_stale), do: "The contribution diff is unchanged, but the PR body Tested head does not name the new head, so the approval was not carried."
  defp changed_reason(:approved_head_unknown), do: "The approved commit is unknown, so the push could not be compared with it."
  defp changed_reason({:unavailable, detail}), do: "The contribution diffs could not be compared (#{inspect(detail)})."

  defp render_hunks([]), do: ""

  defp render_hunks(hunks) do
    shown =
      hunks
      |> Enum.take(@max_reason_hunks)
      |> Enum.map_join("\n", fn hunk ->
        side = if hunk.side == :approved, do: "approved only", else: "new head only"
        Enum.join(["#{hunk.file} (#{side}) #{hunk.header}" | Enum.take(hunk.lines, @max_hunk_lines)], "\n")
      end)

    more = if length(hunks) > @max_reason_hunks, do: "\n… #{length(hunks) - @max_reason_hunks} more hunk(s)", else: ""
    "\n\nDiffering hunks:\n" <> shown <> more
  end
end
