defmodule Aiur.AgentRunner.ReworkHandoffGuard do
  @moduledoc false

  alias Aiur.{Alerts, Issue}
  alias Aiur.Orchestrator.{ReworkGate, ReworkHandoffChecks}

  @spec write(Issue.t(), String.t(), String.t(), Path.t() | nil, String.t() | nil, keyword(), fun()) ::
          {:ok, map()} | {:error, term()}
  def write(issue, issue_id, state, workspace, worker_host, opts, writer) do
    case blockers(issue, state, opts) do
      {:blocked, checks} ->
        message =
          "Cannot hand ticket #{issue.identifier} back to human review: PR head is unchanged and required checks are failing: #{Enum.join(checks, ", ")}. Address the Executor's latest rework comment or explain why it cannot be addressed."

        alert(issue, checks, message, workspace, worker_host, opts)
        {:error, {:no_op_rework, message}}

      :allow ->
        case writer.(issue_id, state) do
          :ok -> {:ok, %{state: state, issue: issue_id}}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  end

  defp blockers(%Issue{state: state} = issue, "human-review", opts) when state in ["rework", "agent:rework"] do
    case ReworkGate.open_pr(issue.identifier, opts) do
      {:ok, pr} ->
        ReworkHandoffChecks.agent_handoff_blockers(Keyword.get(opts, :rework_head_sha), ReworkGate.head_sha(pr), opts)

      _unknown ->
        :allow
    end
  end

  defp blockers(_issue, _state, _opts), do: :allow

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
