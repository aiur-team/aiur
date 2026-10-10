defmodule Aiur.Orchestrator.PauseResume.LabelOverride do
  @moduledoc """
  Applies and lifts the tracker `agent:paused` label override on running and completed issues.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.AgentTeardown
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.PauseResume.PauseRequest
  alias Aiur.Orchestrator.PauseResume.Resume
  alias Aiur.Orchestrator.PauseResume.WorkerControl
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State
  require Logger

  @spec pause_issue_for_label_override(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_label_override(%State{} = state, %Issue{} = issue) do
    running_entry = Map.get(state.running, issue.id)

    if pending_local_pause?(state, running_entry, issue.id) do
      Reconciler.refresh_running_entry_issue(state, issue, running_entry)
    else
      apply_label_override(state, running_entry, issue)
    end
  end

  defp apply_label_override(state, running_entry, issue) do
    case running_entry do
      nil ->
        RetryEngine.release_issue_claim(state, issue.id)

      %{completed_provenance: true} = running_entry ->
        pause_completed_issue_for_label_override(state, running_entry, issue)

      %{control: %{status: :completed}} = running_entry ->
        pause_completed_issue_for_label_override(state, running_entry, issue)

      %{control: %{status: :deactivated}} = running_entry ->
        Reconciler.refresh_running_entry_issue(state, issue, running_entry)

      %{control: %{status: :paused}} = running_entry ->
        apply_label_override_to_paused_issue(state, running_entry, issue)

      running_entry when is_map(running_entry) ->
        Logger.info("Issue pause override detected: #{State.issue_context(issue)}; pausing active agent")
        {_reply, state} = PauseRequest.request_pause(state, running_entry, issue, :label_override)
        state

      _ ->
        state
    end
  end

  defp pending_local_pause?(state, running_entry, issue_id) when is_map(running_entry) do
    pending_reason = Map.get(running_entry, :pending_pause_reason)
    pending_request = ControlLifecycle.current_pending(state.control_lifecycle, issue_id)

    case {pending_reason, pending_request} do
      {%{request_id: request_id, reason: reason}, %{action: :pause, request_id: request_id}}
      when reason != :label_override ->
        true

      _ ->
        false
    end
  end

  defp pending_local_pause?(_state, _running_entry, _issue_id), do: false

  defp apply_label_override_to_paused_issue(state, running_entry, issue) do
    pause_reason = Map.get(running_entry, :paused_reason)

    if not is_nil(pause_reason) and pause_reason != :label_override do
      Reconciler.refresh_running_entry_issue(state, issue, running_entry)
    else
      running_entry =
        running_entry
        |> Map.put(:issue, issue)
        |> Map.put(:paused_reason, :label_override)

      WorkerControl.transition_control_status(state, running_entry, :paused, "label_override")
    end
  end

  @spec resume_label_overridden_issue(State.t(), map()) ::
          {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_label_overridden_issue(%State{} = state, running_entry),
    do: Resume.resume_running_issue(state, running_entry)

  defp pause_completed_issue_for_label_override(state, running_entry, issue) do
    if State.paused_running_entry?(running_entry) and
         not is_nil(Map.get(running_entry, :paused_reason)) do
      Reconciler.refresh_running_entry_issue(state, issue, running_entry)
    else
      state = Reconciler.refresh_running_entry_issue(state, issue, running_entry)
      state = AgentTeardown.deactivate_running_issue(state, issue.id)
      parked_entry = Map.fetch!(state.running, issue.id)

      parked_entry =
        parked_entry
        |> Map.put(:issue, issue)
        |> Map.put(:paused_reason, :label_override)

      WorkerControl.transition_control_status(state, parked_entry, :paused, "label_override.completed")
    end
  end
end
