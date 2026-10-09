defmodule Aiur.Orchestrator.Parking do
  @moduledoc false

  alias Aiur.{Alerts, Config, Issue, Tracker}
  alias Aiur.Orchestrator.{AgentTeardown, ControlLifecycle, PauseResume, State, TrackerTasks}
  require Logger

  @spec park_agent_call(State.t(), String.t()) :: term()
  def park_agent_call(%State{} = state, issue_identifier) do
    PauseResume.guard_control_call(state, :park, issue_identifier, fn ->
      case State.find_running_by_identifier(state.running, issue_identifier) do
        %{issue: %Issue{parked: true}, control: %{status: :deactivated}, operator_parked: true} ->
          {:reply, {:ok, :already_parked}, state}

        %{issue: %Issue{} = issue, control: %{status: :paused}} = entry ->
          park_paused_entry_call(state, entry, issue)

        nil ->
          {:reply, {:error, :no_running_agent}, state}

        _entry ->
          {:reply, {:error, :agent_not_paused}, state}
      end
    end)
  end

  @spec running_control(State.t(), atom(), String.t(), map(), Issue.t(), function(), function()) :: term()
  def running_control(state, action, identifier, entry, issue, tracker_io, resume_reply) do
    cond do
      TrackerTasks.running?(state, {:park_issue, issue.id}) ->
        {:reply, {:error, :park_pending}, state}

      Issue.paused?(issue) ->
        tracker_io.(state, action, identifier, {:running_cleared, issue.id, Map.get(entry, :ref)}, :remove_label, [issue.identifier, pause_label()])

      Issue.parked?(issue) ->
        tracker_io.(state, action, identifier, {:running_unparked, issue.id, Map.get(entry, :ref)}, :remove_label, [issue.identifier, park_label()])

      true ->
        resume_reply.(state, action, identifier, entry)
    end
  end

  @spec running_marker_result(State.t(), atom(), String.t(), term(), term(), function(), function()) :: term()
  def running_marker_result(state, action, identifier, {:running_unparked, issue_id, ref}, :ok, put_running_entry, resume_reply) do
    case State.find_running_by_identifier(state.running, identifier) do
      %{issue: %Issue{id: ^issue_id} = issue, ref: ^ref} = entry ->
        issue = %{issue | parked: false, labels: List.delete(issue.labels, park_label())}
        entry = Map.put(entry, :issue, issue)
        resume_reply.(put_running_entry.(state, issue_id, entry), action, identifier, entry)

      _ ->
        {:reply, {:error, :no_running_agent}, state}
    end
  end

  def running_marker_result(state, _action, _identifier, {:running_unparked, _issue_id, _ref}, {:error, reason}, _put_running_entry, _resume_reply),
    do: {:reply, {:error, {:park_marker_clear_failed, reason}}, state}

  @spec resume_running_issue(State.t(), map(), function()) :: term()
  def resume_running_issue(state, entry, resume_unparked) do
    issue = Map.get(entry, :issue)

    if is_struct(issue, Issue) and Issue.parked?(issue) do
      clear_parked_issue(state, entry, issue, resume_unparked)
    else
      resume_unparked.(state, entry, issue)
    end
  end

  defp clear_parked_issue(state, entry, issue, resume_unparked) do
    if TrackerTasks.running?(state, {:park_issue, issue.id}) do
      {{:error, :park_pending}, state}
    else
      case Tracker.remove_label(issue.identifier, park_label()) do
        :ok ->
          issue = %{issue | parked: false, labels: List.delete(issue.labels, park_label())}
          entry = Map.put(entry, :issue, issue)
          resume_unparked.(put_in(state.running[issue.id], entry), entry, issue)

        {:error, reason} ->
          {{:error, {:park_marker_clear_failed, reason}}, state}
      end
    end
  end

  @spec reconcile_deactivated(State.t(), map(), Issue.t(), function(), function()) :: State.t()
  def reconcile_deactivated(state, entry, issue, refresh, reactivate) do
    if Issue.parked?(issue, entry), do: refresh.(state, issue, entry), else: reactivate.(state, entry, issue)
  end

  @spec clear_and_resume_queued_issue(State.t(), Issue.t(), function(), function()) :: term()
  def clear_and_resume_queued_issue(state, issue, clear_pause, refresh) do
    case clear_pause.(state, issue) do
      {:ok, state, %Issue{} = cleared} -> resume_queued_issue(state, cleared, Issue.parked?(issue), refresh)
      {:error, reason} -> {{:error, {:pause_override_clear_failed, reason}}, state}
    end
  end

  defp resume_queued_issue(state, issue, true, refresh) do
    case Tracker.remove_label(issue.identifier, park_label()) do
      :ok ->
        issue = %{issue | parked: false, labels: List.delete(issue.labels, park_label())}
        refresh.(put_in(state.last_polled_issues[issue.id], issue), issue)

      {:error, reason} ->
        {{:error, {:park_marker_clear_failed, reason}}, state}
    end
  end

  defp resume_queued_issue(state, issue, false, refresh), do: refresh.(state, issue)

  defp park_paused_entry_call(state, entry, issue) do
    cond do
      match?(%{action: :resume}, ControlLifecycle.current_pending(state.control_lifecycle, issue.id)) ->
        {:reply, {:error, :resume_pending}, state}

      State.reserved_paused_running_count(%{issue.id => entry}) == 0 ->
        {:reply, {:error, :reservation_not_held}, state}

      Issue.parked?(issue) ->
        {:reply, {:ok, :already_parked}, park_paused_entry(state, issue)}

      true ->
        queue_park(state, entry, issue)
    end
  end

  defp queue_park(state, entry, issue) do
    state =
      TrackerTasks.run(state, {:park_issue, issue.id}, fn -> Tracker.add_label(issue.id, park_label()) end, fn current, result ->
        apply_park_result(current, entry, issue, result)
      end)

    {:reply, {:ok, :pending}, state}
  end

  defp apply_park_result(current, entry, issue, result) do
    case {Map.get(current.running, issue.id), result} do
      {%{control: %{status: :paused}, issue: %Issue{} = latest_issue} = latest, :ok} ->
        park_if_same_runner(current, latest, entry, latest_issue)

      {_latest, {:error, reason}} ->
        Logger.warning("Could not park #{issue.identifier}: #{inspect(reason)}")

        Alerts.emit_custom("ticket.#{issue.identifier}.agent.attention.park_failed", "Could not park #{issue.identifier}; its paused reservation remains held.",
          issue: issue.identifier,
          reason: "The parked marker could not be written: #{inspect(reason)}",
          needs_attention: true,
          severity: "warning",
          event_source: :system
        )

        current

      _ ->
        current
    end
  end

  defp park_if_same_runner(current, latest, entry, issue) do
    if Map.take(latest, [:pid, :ref]) == Map.take(entry, [:pid, :ref]), do: park_paused_entry(current, issue), else: current
  end

  defp park_paused_entry(state, issue) do
    parked_issue = %{issue | parked: true, labels: Enum.uniq([park_label() | issue.labels])}

    state =
      state
      |> put_in([Access.key(:running), issue.id, Access.key(:issue)], parked_issue)
      |> update_in([Access.key(:running), issue.id], &Map.put(&1, :operator_parked, true))

    AgentTeardown.deactivate_running_issue(state, issue.id)
  end

  defp pause_label, do: "#{Config.settings!().tracker.github.label_prefix}:paused"
  defp park_label, do: "#{Config.settings!().tracker.github.label_prefix}:parked"
end
