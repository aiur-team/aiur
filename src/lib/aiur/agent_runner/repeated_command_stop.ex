defmodule Aiur.AgentRunner.RepeatedCommandStop do
  @moduledoc false

  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.GitHub.Config
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Signal

  @doc false
  @spec stop_on_repeated_command(map(), String.t(), pos_integer()) :: term()
  def stop_on_repeated_command(turn_context, command, count) do
    message =
      "Stopped #{turn_context.issue.identifier}: read-only command output repeated #{count} times: #{inspect(command)}. Review the result before resuming."

    pause_repeated_turn(turn_context, message, "repeated-identical-command", :repeated_identical_command)
  end

  @doc false
  @spec stop_on_turn_cap(map(), atom(), non_neg_integer()) :: term()
  def stop_on_turn_cap(turn_context, cap, count) do
    message = "Stopped #{turn_context.issue.identifier}: per-turn #{cap} cap reached at #{count}. Review the result before resuming."
    pause_repeated_turn(turn_context, message, "turn-#{cap}-cap", :turn_cap)
  end

  @doc false
  @spec stop_on_green_ci_local_gate_wait(map(), String.t(), integer() | nil, non_neg_integer()) :: term()
  def stop_on_green_ci_local_gate_wait(turn_context, head_sha, pr_number, elapsed_minutes) do
    pr = if is_integer(pr_number), do: "PR ##{pr_number}", else: "the current PR"

    message =
      "Stopped #{turn_context.issue.identifier}: required CI is green for #{pr} at #{head_sha}, " <>
        "but local test/gate polling continued for #{elapsed_minutes} minutes. " <>
        "Refresh the PR body and mark the PR ready before resuming."

    pause_repeated_turn(turn_context, message, "green-ci-local-gate-wait", :green_ci_local_gate_wait)
  end

  defp pause_repeated_turn(turn_context, message, alert_name, pause_kind) do
    %{
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      codex_update_recipient: recipient,
      orchestrator: orchestrator
    } = turn_context

    _ = Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier)

    label = "#{Config.label_prefix()}:paused"

    marker_result =
      case Map.get(turn_context, :pause_marker_writer) do
        writer when is_function(writer, 2) -> writer.(issue.identifier, label)
        _ -> TicketTransition.write_marker(issue.identifier, :add, label, writer: :approval_pause)
      end

    alert = Map.get(turn_context, :attention_emitter, &Signal.alert/2)

    alert.("ticket.#{issue.identifier}.agent.attention.#{alert_name}",
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "warning"
    )

    case marker_result do
      :ok ->
        MessageHandler.send_control_state(recipient, issue, :paused, %{kind: pause_kind})
        {:completed, %{issue | paused: true}}

      {:error, reason} ->
        {:error, {:turn_guard_pause_marker_failed, reason}}
    end
  end
end
