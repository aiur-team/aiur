defmodule Aiur.AgentList.Controls do
  @moduledoc """
  Applies pause, remote-control, and concurrency controls in AgentList.

  These functions use `Process.send_after(self(), ...)` and therefore must run
  in the App GenServer process. Calling them from a Task would clear hints and
  alerts in the wrong process.
  """

  require Logger

  alias Aiur.AgentList.Summaries
  alias Aiur.Orchestrator

  @spec toggle_pause(map()) :: map()
  def toggle_pause(%{selection_focus: :agents} = state) do
    state.summaries |> Enum.at(state.selection_index) |> toggle_agent_pause(state)
  end

  def toggle_pause(state), do: state

  @spec toggle_remote_control(map()) :: map()
  def toggle_remote_control(%{selection_focus: :agents} = state) do
    state.summaries |> Enum.at(state.selection_index) |> toggle_agent_remote_control(state)
  end

  def toggle_remote_control(state), do: state

  @spec adjust_max_concurrent_agents(map(), integer()) :: map()
  def adjust_max_concurrent_agents(state, delta) do
    Logger.info("[user-action] adjust_max delta=#{delta} source=agent_list")
    result = Orchestrator.adjust_max_concurrent_agents(state.orchestrator, delta)
    Logger.info("[user-action] adjust_max result=#{inspect(result)}")
    handle_max_adjust_result(state, result)
  end

  defp handle_max_adjust_result(state, {:ok, _status}), do: state
  defp handle_max_adjust_result(state, _result), do: state

  defp toggle_agent_pause(%{identifier: identifier, status: :running} = summary, state) do
    cond do
      Summaries.remote_control_on?(summary) ->
        # RC-on has no local headless driver to pause, so hint and no-op.
        rc_hint(state, "Agent is in Remote Control — press `r` to return")

      Summaries.paused?(summary) ->
        Logger.info("[user-action] resume_agent identifier=#{identifier} source=agent_list")
        handle_resume_result(state, Orchestrator.resume_agent(state.orchestrator, identifier))

      true ->
        Logger.info("[user-action] pause_agent identifier=#{identifier} source=agent_list")
        _ = Orchestrator.pause_agent(state.orchestrator, identifier)
        state
    end
  end

  defp toggle_agent_pause(%{identifier: identifier, status: :queued}, state) do
    Logger.info("[user-action] start_queued_agent identifier=#{identifier} source=agent_list")
    handle_resume_result(state, Orchestrator.resume_agent(state.orchestrator, identifier))
  end

  defp toggle_agent_pause(_summary, state), do: state

  defp toggle_agent_remote_control(%{identifier: identifier, status: :running} = summary, state) do
    # The Orchestrator owns backend and workspace capability gating.
    desired = not Summaries.remote_control_on?(summary)
    Logger.info("[user-action] remote_control identifier=#{identifier} desired=#{if(desired, do: "on", else: "off")} source=agent_list")
    handle_remote_control_result(state, Orchestrator.set_remote_control(state.orchestrator, identifier, desired))
  end

  defp toggle_agent_remote_control(_summary, state), do: rc_hint(state, "Remote Control requires a local Claude agent")

  defp handle_resume_result(state, {:ok, _}), do: state

  defp handle_resume_result(state, {:error, reason}) do
    Logger.info("[user-action] resume_failed reason=#{inspect(reason)}")
    ring_bell(state)
    schedule_max_agents_alert_clear()
    %{state | max_agents_alert?: true}
  end

  defp ring_bell(state) do
    state.write_fun.("\a")
    :ok
  end

  defp schedule_max_agents_alert_clear, do: Process.send_after(self(), :clear_max_agents_alert, 750)

  defp handle_remote_control_result(state, {:ok, :on}), do: rc_hint(state, "Switching to remote — REPL + Claude app, same transcript")
  defp handle_remote_control_result(state, {:ok, :off}), do: rc_hint(state, "Remote off — re-dispatching on the default backend")
  defp handle_remote_control_result(state, {:error, :unsupported}), do: rc_hint(state, "Remote Control requires a local Claude agent")
  defp handle_remote_control_result(state, {:error, :remote_unsupported}), do: rc_hint(state, "Remote Control is local-only — this agent runs on a remote worker")
  defp handle_remote_control_result(state, {:error, :workspace_unavailable}), do: rc_hint(state, "Remote Control unavailable — agent has no workspace yet")
  defp handle_remote_control_result(state, {:error, _reason}), do: rc_hint(state, "Remote Control unavailable")

  defp rc_hint(state, message) do
    schedule_remote_control_hint_clear()
    %{state | remote_control_hint: message}
  end

  defp schedule_remote_control_hint_clear,
    do: Process.send_after(self(), :clear_remote_control_hint, 4_000)
end
