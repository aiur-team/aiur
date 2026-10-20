defmodule Aiur.Orchestrator.CommentWake.Dispatch do
  @moduledoc "Trusted comment digest seeding and dispatch admission."

  require Logger

  alias Aiur.Alerts
  alias Aiur.Events.UniversalSubscriptions
  alias Aiur.Issue
  alias Aiur.Orchestrator.CommentWakeDecline
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.Lifecycle, as: OrchestratorLifecycle
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Signal
  alias Aiur.Tracker

  @doc false
  @spec seed_idle_comment_wake_event(State.t(), String.t() | integer(), map()) :: State.t()
  def seed_idle_comment_wake_event(%State{} = state, issue_number, event) do
    identifier = to_string(issue_number)

    UniversalSubscriptions.attach(identifier)

    state
    |> OperatorMessages.enqueue_event_digest_item(identifier, [event], event)
    |> dispatch_reworked_comment_issue(identifier, event)
  end

  defp dispatch_reworked_comment_issue(%State{} = state, identifier, event) when is_binary(identifier) do
    TrackerTasks.run(state, {:comment_dispatch, identifier, make_ref()}, fn -> fetch_comment_dispatch_issue(identifier, event) end, fn current, result ->
      apply_comment_dispatch(current, identifier, result)
    end)
  end

  defp dispatch_reworked_comment_issue(%State{} = state, %Issue{} = issue) do
    active = DispatchPolicy.active_state_set()
    terminal = DispatchPolicy.terminal_state_set()

    if DispatchPolicy.should_dispatch_issue?(issue, state, active, terminal) do
      Dispatcher.maybe_choose_under_load(state, [issue], fn admitted, [admitted_issue] ->
        admitted
        |> Dispatcher.dispatch_issue(admitted_issue)
        |> maybe_record_comment_rework_resume(admitted_issue)
      end)
    else
      # #2806: this refusal used to fall through to a bare reschedule with no
      # log at all — a paused, parked, already-running or unauthorized ticket
      # simply never woke and nothing said why. #2797 owns the general
      # silent-decline pattern; this is the one on the rework-comment path.
      reason_details = CommentWakeDecline.reason_details(issue, Map.has_key?(state.running, issue.id))

      Alerts.emit_custom(
        "ticket.#{issue.identifier}.agent.attention.comment_wake_dispatch_declined",
        "Comment on issue #{issue.identifier} was not acted on: #{reason_details}",
        issue: issue.identifier,
        reason: CommentWakeDecline.describe(reason_details, issue),
        needs_attention: false,
        severity: "info",
        event_source: :system
      )

      OrchestratorLifecycle.schedule_poll_cycle_start()
      state
    end
  end

  defp apply_comment_dispatch(state, identifier, result) do
    case result do
      {:ok, %Issue{} = issue} ->
        dispatch_reworked_comment_issue(state, issue)

      {:skip, reason} ->
        Logger.info("Trusted comment dispatch deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        OrchestratorLifecycle.schedule_poll_cycle_start()
        state

      {:error, reason} ->
        Logger.warning("Trusted comment dispatch deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        OrchestratorLifecycle.schedule_poll_cycle_start()
        state
    end
  end

  # The successful state transition above captures the comment's rework intent,
  # but dispatch admission must continue to use the subsequently fetched state.
  # When that read is stale-but-active, record the intent only after a worker is
  # actually admitted; Dispatcher records the normal fetched-`rework` case.
  defp maybe_record_comment_rework_resume(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{pid: pid, issue: %Issue{} = dispatched_issue} = entry when is_pid(pid) ->
        if DispatchPolicy.normalize_issue_state(dispatched_issue.state) != "rework" do
          Signal.lifecycle(
            issue.identifier,
            Map.get(entry, :telemetry_attempt_id),
            :agent_resume,
            :point,
            %{cause: :rework_dispatch}
          )
        end

      _other ->
        :ok
    end

    state
  end

  defp fetch_comment_dispatch_issue(identifier, event) do
    fetcher = Map.get(event, :comment_dispatch_issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    case fetcher.([identifier]) do
      {:ok, [%Issue{} = issue | _]} ->
        {:ok, issue}

      {:ok, []} ->
        fetch_comment_dispatch_issue_from_candidates(identifier)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_comment_dispatch_issue_from_candidates(identifier) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        case find_issue_by_identifier_or_id(issues, identifier) do
          %Issue{} = issue -> {:ok, issue}
          nil -> {:skip, :missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_issue_by_identifier_or_id(issues, identifier) when is_list(issues) do
    Enum.find(issues, fn
      %Issue{id: id, identifier: issue_identifier} ->
        id == identifier or issue_identifier == identifier

      _ ->
        false
    end)
  end
end
