defmodule Aiur.Orchestrator.StatusReport.RunningSummaries do
  @moduledoc false
  # Agent-list summaries broadcast on every running-set change.

  import Aiur.Orchestrator.StatusReport.RowFacts,
    only: [idle_issue_pause_reason: 1, idle_issue_work_state: 1, session_execution: 1, visible_polled_issues: 1]

  alias Aiur.AgentEvents
  alias Aiur.Issue
  alias Aiur.Orchestrator.RemoteControlMode, as: RC
  alias Aiur.Orchestrator.State

  @spec running_summaries(State.t()) :: [map()]
  def running_summaries(state) do
    now = DateTime.utc_now()

    polled_summaries =
      visible_polled_issues(state)
      |> Enum.map(&polled_summary(&1, state, now))

    # Cover the narrow race where an agent is mid-dispatch and the
    # tracker poll hasn't refreshed yet — those issues live in
    # `state.running` but not in `last_polled_issues`.
    extra_running =
      state.running
      |> Enum.flat_map(&unpolled_running_summary(&1, visible_polled_issues(state), now))

    (polled_summaries ++ extra_running)
    |> Enum.reject(fn %{identifier: id} -> id == "" end)
  end

  defp polled_summary({issue_id, issue}, state, now) do
    identifier = Map.get(issue, :identifier) || ""
    tag = State.issue_tag(issue)
    title = Map.get(issue, :title)

    case Map.get(state.running, issue_id) do
      nil -> queued_summary(identifier, issue, tag, title)
      entry -> running_summary(identifier, entry, tag, title, now)
    end
  end

  defp queued_summary(identifier, issue, tag, title) do
    # Has an `agent:*` label but no Aiur slot is running it.
    AgentEvents.agent_summary(identifier, :queued, 0, %{
      tag: tag,
      title: title,
      tracker_identity: Issue.tracker_identity(issue),
      work_state: idle_issue_work_state(issue),
      pause_reason: idle_issue_pause_reason(issue)
    })
  end

  defp unpolled_running_summary({issue_id, entry}, polled_issues, now) do
    if Map.has_key?(polled_issues, issue_id) do
      []
    else
      [running_summary(Map.get(entry, :identifier) || "", entry, now)]
    end
  end

  defp running_summary(identifier, entry, now) do
    issue = Map.get(entry, :issue) || %{}

    running_summary(
      identifier,
      entry,
      State.issue_tag(issue),
      get_in(entry, [:issue, Access.key(:title)]),
      now
    )
  end

  defp running_summary(identifier, entry, tag, title, now) do
    AgentEvents.agent_summary(identifier, :running, 0, %{
      tag: tag,
      title: title,
      tracker_identity: Issue.tracker_identity(Map.get(entry, :issue)),
      runtime_seconds: State.effective_runtime_seconds(entry, now),
      turn_count: Map.get(entry, :turn_count, 0),
      context_usage: Map.get(entry, :context_usage),
      telemetry_attempt_id: Map.get(entry, :telemetry_attempt_id),
      work_state: get_in(entry, [:control, :status]) || :working,
      pause_reason: Map.get(entry, :paused_reason),
      backend: entry_backend(entry),
      model: entry_model(entry),
      remote_control: RC.remote_control_summary(entry)
    })
  end

  # Session-resolved backend for a running entry, so the agent list names the
  # engine that actually started rather than re-routing from mutable config.
  # nil while the dispatched worker is still warming up.
  defp entry_backend(entry) do
    entry |> session_execution() |> Map.get(:backend)
  end

  # Session-requested model variant for a running entry (for example
  # "opus-4-8" or "gpt-5.5"). nil while warming up or when the backend default
  # is authoritative; agent_summary drops nil and the renderer shows the base.
  defp entry_model(entry) do
    entry |> session_execution() |> Map.get(:requested_model)
  end
end
