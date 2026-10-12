defmodule Aiur.AgentRunner.TurnAlerts do
  @moduledoc """
  Emits Executor alerts for quota and token-exhaustion turn outcomes.

  Ordinary pauses remain silent while recognized exhaustion conditions produce
  the existing ticket-scoped alerts with their original Executor guidance.
  """

  require Logger

  alias Aiur.{Alerts, CodingAgent, Issue}
  alias Aiur.CodingAgent.RouteFailure

  @doc "Emits the quota alert, forwarding ledger options such as `:now` for clock-consistent incident replay."
  @spec maybe_emit_usage_limit_alert(Issue.t(), Path.t() | nil, String.t() | nil, map(), keyword()) :: :ok
  def maybe_emit_usage_limit_alert(issue, workspace, worker_host, pause_payload, ledger_opts \\ [])

  def maybe_emit_usage_limit_alert(
        issue,
        workspace,
        worker_host,
        %{kind: :usage_limit_exhausted} = pause_payload,
        ledger_opts
      ) do
    reset_hint = pause_payload[:reset_hint]
    backend = Aiur.ModelAvailability.backend_key(pause_payload[:backend])

    case Aiur.ModelAvailability.mark_limited(backend, pause_payload[:reset_at] || reset_hint, ledger_opts) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Unable to persist provider limit issue=#{issue.identifier} backend=#{backend} reason=#{inspect(reason)}; reset remains in worker pause state")
    end

    reset_suffix = if is_binary(reset_hint), do: " (try again at #{reset_hint})", else: ""
    backend_suffix = " Backend detail: #{backend}."

    reason =
      "Agent paused: the #{backend} account usage quota is exhausted; retrying cannot help " <>
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

  def maybe_emit_usage_limit_alert(_issue, _workspace, _worker_host, _pause_payload, _ledger_opts), do: :ok

  @doc """
  Applies #1923's route-failure disposition to a failed turn: a rejected
  credential and a transient outage each raise their own attention, and neither
  is written to `model-usage.json`.

  The ledger is left alone on purpose. It means exactly "rate-limited until
  `reset_at`", and recording an outage there would make the outage
  indistinguishable from a quota event — suppressing the alert and benching the
  route until a reset that was never real. Only the genuine quota path above
  writes to it. See `Aiur.CodingAgent.RouteFailure`.
  """
  @spec maybe_emit_route_failure_alert(Issue.t(), Path.t() | nil, String.t() | nil, term()) :: :ok
  def maybe_emit_route_failure_alert(%Issue{} = issue, workspace, worker_host, reason) do
    route = CodingAgent.backend_for(issue)

    RouteFailure.alert(issue, route, reason, workspace: workspace, worker_host: worker_host)

    :ok
  end

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

  @doc """
  Durable record of the #2806 consecutive-no-op bound firing.

  This is the whole point of the bound: a loop that stops silently is how
  eleven wasted turns went unnoticed on khala #198, and #2797 is open on
  exactly the `Logger.info`-only pattern. The alert is ticket-scoped and
  needs-attention, so it lands in the alert ledger and the central
  `alerts.ndjson` and shows on the Executor's alert feed. A run that reached
  no-op bound keeps its current state except verified rework with no push.
  """
  @spec emit_noop_turn_bound_alert(Issue.t(), Path.t() | nil, String.t() | nil, map()) :: :ok
  def emit_noop_turn_bound_alert(%Issue{} = issue, workspace, worker_host, details) do
    consecutive = Map.get(details, :consecutive_noops)
    cap = Map.get(details, :cap)
    turn_number = Map.get(details, :turn_number)
    unchanged = details |> Map.get(:unchanged, []) |> Enum.join(", ")

    message =
      "Stopped the agent continuation loop on #{issue.identifier} after #{consecutive} consecutive turn(s) " <>
        "that changed nothing (cap #{cap}, last turn ##{turn_number}). Unchanged across those turns: #{unchanged}. " <>
        "No new PR head was detected. Current state: agent:#{issue.state}. " <>
        "Review the agent's result before redispatching."

    Alerts.emit_system(
      "ticket.#{issue.identifier}.agent.noop_turns_bounded",
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "info"
    )

    :ok
  end

  @doc false
  @spec emit_rework_handoff_alert(Issue.t(), Path.t() | nil, String.t() | nil, String.t()) :: :ok
  def emit_rework_handoff_alert(%Issue{} = issue, workspace, worker_host, state) do
    message =
      "Agent stopped after pushing work for #{issue.identifier}; moved the ticket to agent:#{state}."

    Alerts.emit_system(
      "ticket.#{issue.identifier}.agent.rework_handoff",
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "info"
    )

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
