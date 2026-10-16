defmodule Aiur.AgentRunner.ReworkHandoffGuard do
  @moduledoc false

  alias Aiur.{Alerts, Issue, LocalTestEvidence}
  alias Aiur.Orchestrator.ReworkGate

  @spec write(Issue.t(), String.t(), String.t(), Path.t() | nil, String.t() | nil, keyword(), fun()) ::
          {:ok, map()} | {:error, term()}
  def write(issue, issue_id, state, workspace, worker_host, opts, writer) do
    case blockers(issue, state, opts) do
      {:blocked, checks} ->
        message =
          "Cannot hand ticket #{issue.identifier} back to human review: PR head is unchanged and required checks are failing: #{Enum.join(checks, ", ")}. Address the Executor's latest rework comment or explain why it cannot be addressed."

        alert(issue, checks, message, workspace, worker_host, opts)
        {:error, {:no_op_rework, message}}

      {:stale_evidence, message} ->
        {:error, {:stale_pr_body_evidence, message}}

      :allow ->
        case writer.(issue_id, state) do
          :ok -> {:ok, %{state: state, issue: issue_id}}
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  end

  defp blockers(issue, state, opts) do
    with :allow <- rework_blockers(issue, state, opts), do: evidence_blockers(issue, state, opts)
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
      {:stale_evidence,
       "Cannot hand ticket #{issue.identifier} to #{state}: PR ##{pr["number"]} body is wrong (#{reason}). Run `aiur pre-pr` again after `gh pr create` so it writes `Tested head: #{head}` and `Base:`, then hand off."}
    else
      _ -> :allow
    end
  end

  defp evidence_blockers(_issue, _state, _opts), do: :allow

  defp evidence_error(body, head) do
    with {:ok, evidence} <- LocalTestEvidence.parse(body), do: LocalTestEvidence.validate(evidence, "none", head)
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
