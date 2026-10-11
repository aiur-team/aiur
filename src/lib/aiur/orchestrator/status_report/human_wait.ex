defmodule Aiur.Orchestrator.StatusReport.HumanWait do
  @moduledoc false
  # Tracks waiting-for-human episodes and their overdue/resolved alerts.

  alias Aiur.AlertFeed
  alias Aiur.Alerts
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport.AgentStatuses

  @waiting_for_human_alert_after_seconds 600

  @doc false
  @spec sync_waiting_for_human_episodes(State.t(), DateTime.t()) :: State.t()
  def sync_waiting_for_human_episodes(%State{} = state, %DateTime{} = now) do
    track_waiting_for_human_episodes(state, AgentStatuses.agent_statuses(state), now)
  end

  defp track_waiting_for_human_episodes(%State{} = state, statuses, now) do
    current =
      statuses
      |> Enum.filter(&human_wait_alert_candidate?/1)
      |> Map.new(fn status -> {status.identifier, status} end)

    Enum.each(state.waiting_for_human_episodes, fn {identifier, episode} ->
      if not Map.has_key?(current, identifier) and episode.alerted?,
        do: emit_waiting_for_human_resolution(identifier)
    end)

    episodes =
      Enum.reduce(current, %{}, fn {identifier, _status}, acc ->
        episode = Map.get(state.waiting_for_human_episodes, identifier, %{since: now, alerted?: false})
        elapsed = DateTime.diff(now, episode.since, :second)

        episode =
          if waiting_for_human_alert_due?(episode.since, now) and not episode.alerted? do
            maybe_emit_waiting_for_human_alert(identifier, elapsed)
            %{episode | alerted?: true}
          else
            episode
          end

        Map.put(acc, identifier, episode)
      end)

    %{state | waiting_for_human_episodes: episodes}
  end

  @doc false
  @spec waiting_for_human_alert_due?(DateTime.t(), DateTime.t()) :: boolean()
  def waiting_for_human_alert_due?(%DateTime{} = since, %DateTime{} = now) do
    DateTime.diff(now, since, :second) >= @waiting_for_human_alert_after_seconds
  end

  defp human_wait_alert_candidate?(%{waiting_reason: :waiting_for_human} = status) do
    (is_integer(status.open_decision_count) and status.open_decision_count > 0) or
      status.pause_reason in [:agent_pause_request, :input_required]
  end

  defp human_wait_alert_candidate?(_status), do: false

  defp emit_waiting_for_human_resolution(identifier) do
    Alerts.emit_system("ticket.#{identifier}.agent.attention.waiting_for_human.resolved",
      issue: identifier,
      reason: "Agent is no longer waiting for Executor input.",
      needs_attention: false,
      severity: "info",
      central: true
    )
  end

  defp maybe_emit_waiting_for_human_alert(identifier, runtime_seconds)
       when is_binary(identifier) and is_integer(runtime_seconds) do
    topic = "ticket.#{identifier}.agent.attention.waiting_for_human"

    unless AlertFeed.active_ticket_attention?(topic) do
      Alerts.emit_system(topic,
        issue: identifier,
        reason: "Agent has been waiting for Executor input for #{div(runtime_seconds, 60)}m; answer the blocking question or resume the agent.",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end
  end
end
