defmodule Aiur.Orchestrator.OperatorMessages.ControlAlerts do
  @moduledoc """
  Agent control alerts (pause, resume, stop) and running-agent control messages.
  Public API stays on `Aiur.Orchestrator.OperatorMessages`.
  """

  alias Aiur.Alerts
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReason

  @spec maybe_emit_agent_control_alert(atom(), atom(), map()) :: :ok
  def maybe_emit_agent_control_alert(previous_status, status, running_entry) do
    maybe_emit_agent_control_alert(previous_status, status, running_entry, Map.get(running_entry, :paused_reason))
  end

  @spec maybe_emit_agent_control_alert(atom(), atom(), map(), atom() | String.t() | nil) :: :ok
  def maybe_emit_agent_control_alert(
        :working,
        :paused,
        %{paused_reason: :ci_wait} = running_entry,
        _previous_pause_reason
      )
      when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.ci.wait",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Waiting for CI before human review.",
      needs_attention: false,
      severity: "info"
    )
  end

  def maybe_emit_agent_control_alert(
        :working,
        :paused,
        %{paused_reason: :github_budget_hold} = running_entry,
        _previous_pause_reason
      )
      when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.github-budget.wait",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      message: "Agent waiting for GitHub budget",
      reason: "GitHub budget hold paused the agent; automatic retry is scheduled when the hold clears.",
      needs_attention: false,
      severity: "info"
    )
  end

  def maybe_emit_agent_control_alert(:working, :paused, running_entry, _previous_pause_reason)
      when is_map(running_entry) do
    pause_reason = Map.get(running_entry, :paused_reason)
    reason = StatusReason.render(StatusReason.for_pause(pause_reason))

    Alerts.emit_system(pause_attention_topic(running_entry, pause_reason),
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Agent paused (#{reason}); expected to clear #{pause_clearance(pause_reason)}.",
      needs_attention: true,
      severity: "warning"
    )
  end

  def maybe_emit_agent_control_alert(:paused, :working, running_entry, previous_pause_reason)
      when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.agent.unpaused",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Agent resumed; no Executor action is needed.",
      needs_attention: false,
      severity: "info"
    )

    if is_nil(previous_pause_reason) do
      :ok
    else
      Alerts.emit_system("#{pause_attention_topic(running_entry, previous_pause_reason)}.resolved",
        issue: Map.get(running_entry, :identifier),
        workspace: Map.get(running_entry, :workspace_path),
        worker_host: Map.get(running_entry, :worker_host),
        reason: "Agent pause cause #{pause_cause(previous_pause_reason)} is resolved.",
        needs_attention: false,
        severity: "info"
      )
    end
  end

  def maybe_emit_agent_control_alert(_previous_status, _status, _running_entry, _previous_pause_reason), do: :ok

  defp pause_attention_topic(running_entry, pause_reason) do
    "ticket.#{Map.get(running_entry, :identifier)}.agent.attention.paused-#{pause_cause(pause_reason)}"
  end

  defp pause_cause(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp pause_cause(reason) when is_binary(reason) and reason != "" do
    if Regex.match?(~r/\A[a-z0-9_-]+\z/, reason), do: reason, else: "unknown"
  end

  defp pause_cause(_reason), do: "unknown"

  defp pause_clearance(reason) when reason in [:operator_pause, :label_override, :agent_pause_request, :input_required, :blocker_dependency],
    do: "after Executor or agent action"

  defp pause_clearance(reason) when reason in [:global_pause, :usage_limit_exhausted, :github_budget_hold], do: "when the condition is lifted"

  defp pause_clearance(:before_run_failure), do: "after preflight succeeds"

  defp pause_clearance(_reason), do: "after the next control reconciliation"

  @spec send_running_control_message(State.t(), String.t(), (integer() -> term())) ::
          {:ok, integer()} | {:error, atom()}
  def send_running_control_message(state, issue_identifier, build_message) do
    request_id = :erlang.unique_integer([:positive])
    send_running_control_message(state, issue_identifier, request_id, build_message)
  end

  @doc false
  @spec send_running_control_message(State.t(), String.t(), integer(), (integer() -> term())) ::
          {:ok, integer()} | {:error, atom()}
  def send_running_control_message(state, issue_identifier, request_id, build_message)
      when is_integer(request_id) and request_id > 0 and is_function(build_message, 1) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      nil ->
        {:error, :no_running_agent}

      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          send(pid, build_message.(request_id))
          {:ok, request_id}
        else
          {:error, :agent_finished}
        end

      _ ->
        {:error, :agent_finished}
    end
  end
end
