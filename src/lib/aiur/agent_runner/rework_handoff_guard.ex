defmodule Aiur.AgentRunner.ReworkHandoffGuard do
  @moduledoc false

  alias Aiur.AgentRunner.ReworkFindings
  alias Aiur.{Alerts, Issue, LocalTestEvidence, Tracker}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator.ReworkGate

  @spec write(Issue.t(), String.t(), String.t(), Path.t() | nil, String.t() | nil, keyword(), fun()) ::
          {:ok, map()} | {:error, term()}
  def write(issue, issue_id, state, workspace, worker_host, opts, writer) do
    case blockers(issue, state, workspace, opts) do
      {:blocked, checks} ->
        message =
          "Cannot hand ticket #{issue.identifier} back to human review: PR head is unchanged and required checks are failing: #{Enum.join(checks, ", ")}. Address the Executor's latest rework comment or explain why it cannot be addressed."

        alert(issue, checks, message, workspace, worker_host, opts)
        {:error, {:no_op_rework, message}}

      {:refused, reason, message} ->
        {:error, {reason, message}}

      {:allow, findings} ->
        case writer.(issue_id, state) do
          :ok -> {:ok, report_checklist(issue, findings, opts, %{state: state, issue: issue_id})}
          {:ok, result} -> {:ok, report_checklist(issue, findings, opts, result)}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  end

  defp blockers(issue, state, workspace, opts) do
    with :allow <- rework_blockers(issue, state, opts),
         :allow <- evidence_blockers(issue, state, opts),
         :allow <- conflict_blockers(issue, state, opts) do
      findings_blockers(issue, state, workspace, opts)
    end
  end

  defp rework_blockers(%Issue{state: state} = issue, "human-review", opts) when state in ["rework", "agent:rework"] do
    ReworkGate.agent_handoff_blockers(issue.identifier, Keyword.get(opts, :rework_head_sha), opts)
  end

  defp rework_blockers(_issue, _state, _opts), do: :allow

  # #4611: a PR created after the first `aiur pre-pr` keeps stale Local tests evidence; refuse the handoff until it is refreshed.
  # An unreadable PR fails open here; the `pr body` CI check and the push backstop alert still cover it.
  defp evidence_blockers(issue, state, opts) when state in ["ci-wait", "human-review"] do
    with {:ok, pr} <- ReworkGate.open_pr(issue.identifier, opts),
         head when is_binary(head) <- ReworkGate.head_sha(pr),
         body when is_binary(body) <- pr["body"],
         {:error, reason} <- evidence_error(body, head) do
      {:refused, :stale_pr_body_evidence,
       "Cannot hand ticket #{issue.identifier} to #{state}: PR ##{pr["number"]} body is wrong (#{reason}). Run `aiur pre-pr` again after `gh pr create` so it writes `Tested head: #{head}` and `Base:`, then hand off."}
    else
      _ -> :allow
    end
  end

  defp evidence_blockers(_issue, _state, _opts), do: :allow

  defp evidence_error(body, head) do
    with {:ok, evidence} <- LocalTestEvidence.parse(body), do: LocalTestEvidence.validate(evidence, "none", head)
  end

  # #4654: PRs were handed back while GitHub reported them CONFLICTING. The list read carries no mergeability,
  # so this reads the PR itself; an unreadable or still-computing state fails open.
  defp conflict_blockers(issue, state, opts) when state in ["ci-wait", "human-review"] do
    fetch = Keyword.get(opts, :pull_request_fetcher, &default_pull_request/1)

    with {:ok, %{"number" => number}} when is_integer(number) <- ReworkGate.open_pr(issue.identifier, opts),
         {:ok, %{"mergeable_state" => "dirty"}} <- fetch.(number) do
      {:refused, :pull_request_conflicting,
       "Cannot hand ticket #{issue.identifier} to #{state}: PR ##{number} conflicts with its base. Merge `origin/$AIUR_BASE_BRANCH`, resolve the conflicts, push, then hand off."}
    else
      _ -> :allow
    end
  end

  defp conflict_blockers(_issue, _state, _opts), do: :allow

  defp default_pull_request(number), do: if(ReworkGate.available?(), do: GitHubClient.fetch_open_pull_request(number), else: {:ok, nil})

  # #4654: a rework handback must answer every finding of the latest blocking review and carry commits made since it.
  defp findings_blockers(%Issue{state: rework} = issue, state, workspace, opts)
       when state in ["ci-wait", "human-review"] and rework in ["rework", "agent:rework"] do
    case ReworkFindings.fetch(issue.identifier, opts) do
      {:ok, %{review_head: review_head, head: head, findings: findings}} when is_binary(review_head) ->
        {commits, files} = ReworkFindings.branch_changes(workspace, review_head, head)

        case ReworkFindings.validate(findings, Keyword.get(opts, :review_findings), commits, files) do
          :allow ->
            {:allow, findings}

          {:blocked, reasons} ->
            {:refused, :rework_findings_unaddressed,
             "Cannot hand ticket #{issue.identifier} back to #{state}: #{Enum.join(reasons, "; ")}. Pass every finding in `review_findings` as `fixed` (with its commit) or `disputed` (with evidence)."}
        end

      {:ok, _no_blocking_review} ->
        {:allow, []}

      {:error, reason} ->
        {:refused, :rework_findings_unaddressed, "Cannot hand ticket #{issue.identifier} back to #{state}: the latest review's findings could not be read (#{inspect(reason)}). Retry the handoff."}
    end
  end

  defp findings_blockers(_issue, _state, _workspace, _opts), do: {:allow, []}

  # The re-review reads the worker's answers from this ticket comment; a failed post does not undo the handback.
  defp report_checklist(_issue, [], _opts, result), do: result

  defp report_checklist(issue, findings, opts, result) do
    comment = Keyword.get(opts, :checklist_commenter, &Tracker.create_comment/2)
    comment.(issue.id || issue.identifier, ReworkFindings.comment_body(findings, Keyword.get(opts, :review_findings)))
    result
  end

  defp alert(issue, checks, message, workspace, worker_host, opts) do
    case Keyword.get(opts, :no_op_rework_alert) do
      emit when is_function(emit, 3) ->
        emit.(issue, checks, message)

      _default ->
        Alerts.emit_custom("ticket.#{issue.identifier}.agent.attention.no_op_rework", message,
          issue: issue,
          workspace: workspace,
          worker_host: worker_host,
          reason: message,
          needs_attention: true,
          severity: "warning"
        )
    end
  end
end
