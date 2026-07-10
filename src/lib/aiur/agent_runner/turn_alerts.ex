defmodule Aiur.AgentRunner.TurnAlerts do
  @moduledoc """
  Emits operator alerts for quota and token-exhaustion turn outcomes.

  Ordinary pauses remain silent while recognized exhaustion conditions produce
  the existing ticket-scoped alerts with their original operator guidance.
  """

  alias Aiur.{Alerts, Issue}

  @spec maybe_emit_usage_limit_alert(Issue.t(), Path.t() | nil, String.t() | nil, map()) :: :ok
  def maybe_emit_usage_limit_alert(issue, workspace, worker_host, %{kind: :usage_limit_exhausted} = pause_payload) do
    reset_hint = pause_payload[:reset_hint]
    backend = pause_payload[:reason]

    Aiur.ModelAvailability.mark_limited("codex", reset_hint)

    reset_suffix = if is_binary(reset_hint), do: " (try again at #{reset_hint})", else: ""
    backend_suffix = if is_binary(backend), do: " Backend detail: #{backend}.", else: ""

    reason =
      "Agent paused: the codex account usage quota is exhausted; retrying cannot help " <>
        "until it resets#{reset_suffix}. Resume the agent after the quota resets.#{backend_suffix}"

    Alerts.emit_system(
      "ticket.#{issue.identifier}.agent.usage_limit_exhausted",
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      reason: reason,
      needs_attention: true,
      severity: "warning"
    )

    :ok
  end

  def maybe_emit_usage_limit_alert(_issue, _workspace, _worker_host, _pause_payload), do: :ok

  @spec maybe_emit_more_tokens_alert(Issue.t(), Path.t() | nil, String.t() | nil, term()) :: :ok
  def maybe_emit_more_tokens_alert(issue, workspace, worker_host, reason) do
    if more_tokens_reason?(reason) do
      Alerts.emit_system(
        "ticket.#{issue.identifier}.agent.error.tokens_exhausted",
        issue: issue,
        workspace: workspace,
        worker_host: worker_host,
        reason: "Agent stopped because its token budget or context limit was exhausted.",
        needs_attention: true,
        severity: "warning"
      )
    end

    :ok
  end

  defp more_tokens_reason?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> String.contains?([
      "rate limit exhausted",
      "token budget",
      "context length",
      "maximum context",
      "max tokens",
      "too many tokens"
    ])
  end
end
