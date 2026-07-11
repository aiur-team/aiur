defmodule Aiur.Orchestrator.StatusReport do
  @moduledoc """
  Owns orchestrator StatusReport behavior.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.{AgentEvents, AgentPubSub, CodingAgent, Issue}
  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.RemoteControlMode, as: RC
  alias Aiur.Orchestrator.{Slots, State}
  alias AiurWeb.ObservabilityPubSub

  @spec notify_dashboard(State.t()) :: :ok
  def notify_dashboard(state) do
    state
    |> running_summaries()
    |> AgentPubSub.broadcast_running_change()

    AgentPubSub.broadcast_poll_state(%{
      checking?: state.poll_check_in_progress == true,
      next_poll_due_at_ms: state.next_poll_due_at_ms,
      max_concurrent_agents: Slots.max_concurrent_agent_limit(state)
    })

    ObservabilityPubSub.broadcast_update()
  end

  @spec running_summaries(State.t()) :: [map()]
  def running_summaries(state) do
    now = DateTime.utc_now()

    running_by_identifier =
      Map.new(state.running, fn {_id, entry} -> {Map.get(entry, :identifier), entry} end)

    polled_summaries =
      state.last_polled_issues
      |> Map.values()
      |> Enum.map(fn issue ->
        identifier = Map.get(issue, :identifier) || ""
        tag = State.issue_tag(issue)
        title = Map.get(issue, :title)

        case Map.get(running_by_identifier, identifier) do
          nil ->
            # Has an `agent:*` label but no Aiur slot is running it.
            AgentEvents.agent_summary(identifier, :queued, 0, %{
              tag: tag,
              title: title,
              work_state: idle_issue_work_state(issue),
              pause_reason: idle_issue_pause_reason(issue)
            })

          entry ->
            AgentEvents.agent_summary(identifier, :running, 0, %{
              tag: tag,
              title: title,
              runtime_seconds: State.effective_runtime_seconds(entry, now),
              turn_count: Map.get(entry, :turn_count, 0),
              work_state: get_in(entry, [:control, :status]) || :working,
              pause_reason: Map.get(entry, :paused_reason),
              backend: entry_backend(entry),
              model: entry_model(entry),
              remote_control: RC.remote_control_summary(entry)
            })
        end
      end)

    polled_identifiers = MapSet.new(polled_summaries, fn s -> s.identifier end)

    # Cover the narrow race where an agent is mid-dispatch and the
    # tracker poll hasn't refreshed yet — those issues live in
    # `state.running` but not in `last_polled_issues`.
    extra_running =
      state.running
      |> Enum.flat_map(fn {_id, entry} ->
        identifier = Map.get(entry, :identifier) || ""

        if identifier == "" or MapSet.member?(polled_identifiers, identifier) do
          []
        else
          [
            AgentEvents.agent_summary(identifier, :running, 0, %{
              tag: State.issue_tag(Map.get(entry, :issue)),
              title: get_in(entry, [:issue, Access.key(:title)]),
              runtime_seconds: State.effective_runtime_seconds(entry, now),
              turn_count: Map.get(entry, :turn_count, 0),
              work_state: get_in(entry, [:control, :status]) || :working,
              pause_reason: Map.get(entry, :paused_reason),
              backend: entry_backend(entry),
              model: entry_model(entry),
              remote_control: RC.remote_control_summary(entry)
            })
          ]
        end
      end)

    (polled_summaries ++ extra_running)
    |> Enum.reject(fn %{identifier: id} -> id == "" end)
  end

  # Resolved backend string for a running entry, so the agent list can name
  # the agent's own engine in its placeholder rather than guessing. nil when
  # the entry carries no issue; agent_summary drops the nil.
  defp entry_backend(entry) do
    case Map.get(entry, :issue) do
      %Issue{} = issue -> CodingAgent.backend_for(issue)
      _ -> nil
    end
  end

  # Pinned model variant for a running entry (e.g. "opus-4-8", "gpt-5.5"),
  # so the agent list can render the model column's version suffix. nil when
  # the entry carries no issue or the model is unpinned (backend default);
  # agent_summary drops the nil and the renderer falls back to the base name.
  defp entry_model(entry) do
    case Map.get(entry, :issue) do
      %Issue{} = issue -> CodingAgent.model_for(issue)
      _ -> nil
    end
  end

  # Highest `complexity:N` label on the issue (nil when unlabelled). Reused by
  # the status rows so `aiur watch` can render the cx column without a tracker
  # round-trip — the issue is already in memory.
  defp issue_complexity(%Issue{} = issue), do: CodingAgent.complexity_level(issue)

  @spec agent_statuses(State.t()) :: [map()]
  def agent_statuses(%State{} = state) do
    now = DateTime.utc_now()

    running_by_identifier =
      Map.new(state.running, fn {_id, entry} -> {Map.get(entry, :identifier), entry} end)

    (running_statuses(state, now) ++ idle_statuses(state, running_by_identifier))
    |> Enum.sort_by(fn status -> to_string(status.identifier || status.issue_id || "") end)
  end

  defp running_statuses(%State{} = state, %DateTime{} = now) do
    Enum.map(state.running, fn {issue_id, entry} ->
      running_status(state, issue_id, entry, now)
    end)
  end

  defp running_status(%State{} = state, issue_id, entry, now) do
    identifier = Map.get(entry, :identifier) || issue_id
    issue = Map.get(entry, :issue)
    work_state = get_in(entry, [:control, :status]) || :working

    %{
      issue_id: issue_id,
      identifier: identifier,
      state: if(work_state == :paused, do: :paused, else: :running),
      work_state: work_state,
      tracker_state: Map.get(issue, :state),
      tracker_paused: Issue.paused?(issue),
      tag: State.issue_tag(issue),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      runtime_seconds: State.running_seconds(Map.get(entry, :started_at), now),
      queue_depth: OM.queue_depth_for_issue(state, identifier),
      complexity: issue_complexity(issue),
      last_codex_timestamp: Map.get(entry, :last_codex_timestamp),
      last_codex_message: Map.get(entry, :last_codex_message),
      last_codex_event: Map.get(entry, :last_codex_event)
    }
  end

  defp idle_statuses(%State{} = state, running_by_identifier) do
    state.last_polled_issues
    |> Map.values()
    |> Enum.reject(&running_issue?(&1, running_by_identifier))
    |> Enum.map(&idle_status(state, &1))
  end

  defp running_issue?(issue, running_by_identifier) do
    identifier = Map.get(issue, :identifier)
    is_binary(identifier) and Map.has_key?(running_by_identifier, identifier)
  end

  defp idle_status(%State{} = state, issue) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, :id)

    %{
      issue_id: Map.get(issue, :id),
      identifier: identifier,
      state: :idle,
      tracker_state: Map.get(issue, :state),
      tracker_paused: Issue.paused?(issue),
      tag: State.issue_tag(issue),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      runtime_seconds: 0,
      queue_depth: idle_queue_depth(state, identifier),
      complexity: issue_complexity(issue),
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil
    }
  end

  defp idle_queue_depth(%State{} = state, identifier) when is_binary(identifier) do
    OM.queue_depth_for_issue(state, identifier)
  end

  defp idle_queue_depth(_state, _identifier), do: 0

  defp idle_issue_work_state(%Issue{} = issue) do
    if Issue.paused?(issue), do: :paused, else: :idle
  end

  defp idle_issue_work_state(_issue), do: :idle

  defp idle_issue_pause_reason(%Issue{} = issue) do
    if Issue.paused?(issue), do: :label_override, else: nil
  end

  defp idle_issue_pause_reason(_issue), do: nil

  @spec next_poll_in_ms(integer() | nil, integer()) :: non_neg_integer() | nil
  def next_poll_in_ms(nil, _now_ms), do: nil

  def next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end
end
