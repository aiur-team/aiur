defmodule Aiur.Orchestrator.RetryEngine.HoldStreak do
  @moduledoc """
  Surfaces a local GitHub budget hold that keeps a ticket's retries deferred
  (#4693).

  A `:local_budget_hold` retry never consumes the failure budget (#2429), so a
  hold that never clears — a broker that stays down, a quota that never
  resets — would retry at max backoff forever, unseen. This counts the
  consecutive hold deferrals per ticket and raises one Executor attention once
  the run has lasted `alert_after_ms/0`. The ticket's next committed dispatch,
  a retry scheduled for any non-hold reason, or the release of its claim ends
  the run and resolves the attention.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Orchestrator.State

  @alert_after_ms 30 * 60 * 1_000

  @doc "How long a run of hold deferrals lasts before it raises an attention."
  @spec alert_after_ms() :: pos_integer()
  def alert_after_ms, do: @alert_after_ms

  @doc "The attention topic for `identifier`'s persistent hold."
  @spec topic(String.t()) :: String.t()
  def topic(identifier), do: "ticket.#{identifier}.agent.attention.budget-hold-persistent"

  @doc "Counts one hold deferral for `issue_id`; raises the attention once the run passes the threshold."
  @spec record(State.t(), String.t(), String.t(), map(), integer()) :: State.t()
  def record(%State{} = state, issue_id, identifier, hold, now_ms) when is_map(hold) and is_integer(now_ms) do
    streak = Map.get(state.budget_hold_streaks, issue_id, %{since_ms: now_ms, count: 0, alerted?: false})
    streak = %{streak | count: streak.count + 1}

    streak =
      if not streak.alerted? and now_ms - streak.since_ms >= @alert_after_ms,
        do: %{streak | alerted?: emit(identifier, streak, hold, now_ms) == :ok},
        else: streak

    %{state | budget_hold_streaks: Map.put(state.budget_hold_streaks, issue_id, Map.put(streak, :identifier, identifier))}
  end

  @doc "Ends `issue_id`'s run of hold deferrals, resolving its attention if one was raised."
  @spec clear(State.t(), String.t()) :: State.t()
  def clear(%State{} = state, issue_id) do
    case Map.get(state.budget_hold_streaks, issue_id) do
      %{alerted?: true, identifier: identifier} ->
        case Alerts.emit_system("#{topic(identifier)}.resolved",
               issue: identifier,
               reason: "Ticket #{identifier} is no longer held: the local GitHub budget hold lifted or its claim was released.",
               needs_attention: false,
               severity: "info",
               central: true
             ) do
          :ok -> %{state | budget_hold_streaks: Map.delete(state.budget_hold_streaks, issue_id)}
          # Keep the streak so the next clear retries the resolution.
          {:error, _reason} -> state
        end

      _none_or_unalerted ->
        %{state | budget_hold_streaks: Map.delete(state.budget_hold_streaks, issue_id)}
    end
  end

  defp emit(identifier, streak, hold, now_ms) do
    minutes = div(now_ms - streak.since_ms, 60_000)
    reason = Map.get(hold, :reason) || Map.get(hold, "reason") || :unknown
    reset_at = format_reset_at(Map.get(hold, :reset_at) || Map.get(hold, "reset_at"))

    message =
      "Ticket #{identifier} has been held by the local GitHub budget for #{minutes} min " <>
        "(#{streak.count} deferrals; reason=#{inspect(reason)}, reset_at=#{reset_at}). Retries do not consume the failure budget, so it will not give up on its own."

    Logger.warning(message)

    Alerts.emit_system(topic(identifier),
      issue: identifier,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end

  defp format_reset_at(%DateTime{} = reset_at), do: DateTime.to_iso8601(reset_at)
  defp format_reset_at(nil), do: "unknown"
  defp format_reset_at(reset_at) when is_binary(reset_at), do: reset_at
  defp format_reset_at(reset_at), do: inspect(reset_at)
end
