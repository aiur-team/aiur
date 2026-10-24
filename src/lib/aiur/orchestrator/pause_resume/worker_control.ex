defmodule Aiur.Orchestrator.PauseResume.WorkerControl do
  @moduledoc """
  Applies worker-reported control state and rejections to the running entry.
  """

  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DurationCapRelease
  alias Aiur.Orchestrator.GithubBudgetPause
  alias Aiur.Orchestrator.Lifecycle, as: OrchestratorLifecycle
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Orchestrator.PauseResume.Clocks
  alias Aiur.Orchestrator.PauseResume.ControlRequest
  alias Aiur.Orchestrator.PauseResume.PauseRequest
  alias Aiur.Orchestrator.PauseResume.Resume
  alias Aiur.Orchestrator.PushRouting
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackerTasks
  require Logger

  @doc false
  @spec handle_worker_control_state(State.t(), String.t(), :completed | :paused | :working, map()) ::
          {:noreply, State.t()}
  def handle_worker_control_state(%State{running: running} = state, issue_id, status, pause_payload) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        state = expire_pending_control_on_completion(state, running_entry, status)

        case apply_control_evidence(state, running_entry, status, pause_payload) do
          {:ignored, state} ->
            {:noreply, state}

          {:unrelated, state} ->
            apply_worker_control_state(state, issue_id, running_entry, status, pause_payload, nil)

          {:applied, request, state} ->
            apply_worker_control_state(state, issue_id, running_entry, status, pause_payload, request)
        end
    end
  end

  @doc false
  @spec handle_worker_control_rejected(State.t(), String.t(), pos_integer(), non_neg_integer(), atom()) ::
          {:noreply, State.t()}
  def handle_worker_control_rejected(%State{} = state, issue_id, request_id, generation, class) do
    with %{issue: %{id: ^issue_id}} = running_entry <- Map.get(state.running, issue_id),
         %{issue_id: ^issue_id, generation: ^generation, status: status} when status in [:requested, :accepted] <-
           ControlLifecycle.get(state.control_lifecycle, request_id),
         {:ok, rejected, lifecycle} <-
           ControlLifecycle.reject(state.control_lifecycle, request_id, class,
             now: DateTime.utc_now(),
             condition: %{
               control_status: get_in(running_entry, [:control, :status]) || :paused,
               pause_reason: Map.get(running_entry, :paused_reason)
             }
           ) do
      state = %{state | control_lifecycle: lifecycle} |> ControlRequest.persist_control_lifecycle() |> PauseResume.drop_stale_pending_pause_reason(issue_id)
      ControlRequest.publish_control_lifecycle(Map.get(running_entry, :identifier), rejected)
      StatusReport.notify_dashboard(state)
      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  defp apply_worker_control_state(state, issue_id, running_entry, status, pause_payload, request) do
    previous_status = get_in(running_entry, [:control, :status]) || :working
    previous_pause_reason = Map.get(running_entry, :paused_reason)
    pause_reason = worker_pause_reason(state, running_entry, pause_payload, request)
    transition_cause = control_transition_cause(request, status, pause_reason)

    updated_running_entry =
      running_entry
      |> put_control_status(status)
      |> State.apply_pause_runtime_clock(previous_status, status, DateTime.utc_now())
      |> maybe_put_worker_pause_reason(status, pause_reason)
      |> put_usage_limit_reset(status, pause_reason, pause_payload)
      |> put_usage_limit_session(status, pause_reason, pause_payload)
      |> maybe_clear_control_owned_pause(request, status)
      |> maybe_clear_pending_pause_reason(request, status)
      |> maybe_clear_interrupted_turn(status)

    maybe_log_worker_pause(status, updated_running_entry, pause_reason)
    ControlRequest.record_control_transition(updated_running_entry, previous_status, status, transition_cause)

    OperatorMessages.maybe_emit_agent_control_alert(
      previous_status,
      status,
      updated_running_entry,
      if(status == :working, do: previous_pause_reason, else: pause_reason)
    )

    state =
      state
      |> Map.put(:running, Map.put(state.running, issue_id, updated_running_entry))
      |> maybe_wake_after_first_active_resume(state)

    state = finalize_applied_resume(state, issue_id, request)
    state = maybe_auto_resume_spurious_worker_pause(state, updated_running_entry, status)
    state = DurationCapRelease.maybe_release(state, updated_running_entry, status)
    state = sync_pause_reason_label(state, running_entry, previous_status, previous_pause_reason, status, pause_reason)
    StatusReport.notify_dashboard(state)
    {:noreply, state}
  end

  defp put_usage_limit_reset(entry, :paused, :usage_limit_exhausted, %{reset_at: reset}) when is_binary(reset),
    do: Map.put(entry, :usage_limit_reset_at, reset)

  defp put_usage_limit_reset(entry, _status, _reason, _payload), do: Map.delete(entry, :usage_limit_reset_at)

  defp put_usage_limit_session(entry, :paused, :usage_limit_exhausted, payload),
    do: Map.put(entry, :usage_limit_session, Map.take(payload, [:session_id, :account_name, :cwd, :backend]))

  defp put_usage_limit_session(entry, _status, _reason, _payload), do: entry

  defp maybe_clear_interrupted_turn(running_entry, :paused),
    do: Map.delete(running_entry, :interrupted_turn_observed_at)

  defp maybe_clear_interrupted_turn(running_entry, _status), do: running_entry

  @doc false
  @spec maybe_wake_after_first_active_resume(term(), term()) :: term()
  def maybe_wake_after_first_active_resume(next_state, previous_state) do
    if State.active_running_count(previous_state.running) == 0 and
         State.active_running_count(next_state.running) > 0 do
      next_state |> OrchestratorLifecycle.request_refresh_state() |> elem(0)
    else
      next_state
    end
  end

  defp apply_control_evidence(state, running_entry, status, %{request_id: request_id, generation: generation})
       when is_integer(request_id) and is_integer(generation) do
    case ControlLifecycle.get(state.control_lifecycle, request_id) do
      nil ->
        {:ignored, state}

      request ->
        case control_evidence_outcome(running_entry, status, request) do
          :ignored ->
            {:ignored, state}

          {:rejected, class} ->
            reject_stale_control_evidence(state, running_entry, request, class)

          :applicable ->
            apply_control_request(state, running_entry, request_id, generation)
        end
    end
  end

  defp apply_control_evidence(state, _running_entry, _status, %{request_id: _request_id, generation: _generation}), do: {:ignored, state}
  defp apply_control_evidence(state, _running_entry, _status, _payload), do: {:unrelated, state}

  defp control_evidence_outcome(running_entry, status, request) do
    cond do
      request.issue_id != get_in(running_entry, [:issue, Access.key(:id)]) -> :ignored
      not action_matches_status?(request.action, status) -> :ignored
      not control_confirms_application?(running_entry) -> :ignored
      class = control_rejection_class(running_entry, request) -> {:rejected, class}
      true -> :applicable
    end
  end

  defp control_confirms_application?(running_entry) do
    running_entry
    |> Map.get(:control, %{})
    |> Map.get(:application_confirmation, :request_only)
    |> Kernel.==(:confirmed)
  end

  defp apply_control_request(state, running_entry, request_id, generation) do
    case ControlLifecycle.apply(state.control_lifecycle, request_id, generation, now: DateTime.utc_now()) do
      {:ok, applied, lifecycle} ->
        state = %{state | control_lifecycle: lifecycle} |> ControlRequest.persist_control_lifecycle()
        ControlRequest.publish_control_lifecycle(Map.get(running_entry, :identifier), applied)
        {:applied, applied, state}

      {:ignored, lifecycle} ->
        {:ignored, %{state | control_lifecycle: lifecycle}}
    end
  end

  defp control_rejection_class(running_entry, request) do
    control = Map.get(running_entry, :control, %{})

    cond do
      Map.get(control, :generation) != request.generation -> :stale_generation
      Map.get(control, :status, :working) != request.expected_status -> :already_in_state
      Map.get(control, :version, 0) != request.expected_version -> :already_in_state
      true -> nil
    end
  end

  defp reject_stale_control_evidence(state, running_entry, request, class) do
    case ControlLifecycle.reject(state.control_lifecycle, request.request_id, class, now: DateTime.utc_now()) do
      {:ok, rejected, lifecycle} ->
        state = %{state | control_lifecycle: lifecycle} |> ControlRequest.persist_control_lifecycle() |> PauseResume.drop_stale_pending_pause_reason(request.issue_id)
        ControlRequest.publish_control_lifecycle(Map.get(running_entry, :identifier), rejected)
        {:ignored, state}

      {:ignored, lifecycle} ->
        {:ignored, %{state | control_lifecycle: lifecycle}}
    end
  end

  defp expire_pending_control_on_completion(state, _running_entry, status) when status != :completed, do: state

  defp expire_pending_control_on_completion(state, running_entry, :completed) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])

    case ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
      nil ->
        state

      pending ->
        case ControlLifecycle.expire(state.control_lifecycle, pending.request_id, :worker_unavailable, now: DateTime.utc_now()) do
          {:ok, expired, lifecycle} ->
            state = %{state | control_lifecycle: lifecycle} |> ControlRequest.persist_control_lifecycle()
            ControlRequest.publish_control_lifecycle(Map.get(running_entry, :identifier), expired)
            state

          {:ignored, lifecycle} ->
            %{state | control_lifecycle: lifecycle}
        end
    end
  end

  defp action_matches_status?(:pause, :paused), do: true
  defp action_matches_status?(:resume, :working), do: true
  defp action_matches_status?(_action, _status), do: false

  defp put_control_status(running_entry, status) do
    running_entry = clear_agent_pause_on_work(running_entry, status)
    control = Map.get(running_entry, :control, %{})
    current_status = Map.get(control, :status, :working)

    control =
      control
      |> Map.put(:status, status)
      |> maybe_increment_control_version(current_status, status)

    Map.put(running_entry, :control, control)
  end

  defp clear_agent_pause_on_work(%{paused_reason: :agent_pause_request} = entry, :working),
    do: Map.delete(entry, :paused_reason)

  defp clear_agent_pause_on_work(entry, _status), do: entry

  defp maybe_increment_control_version(control, status, status), do: control

  defp maybe_increment_control_version(control, _previous_status, _status) do
    if Map.has_key?(control, :version), do: Map.update!(control, :version, &(&1 + 1)), else: control
  end

  defp maybe_clear_control_owned_pause(running_entry, %{action: :resume}, :working) do
    if Map.get(running_entry, :paused_reason) in [
         :agent_pause_request,
         :ci_wait,
         :global_pause,
         :input_required,
         :label_override,
         :operator_pause,
         :pause_containment,
         :blocker_dependency,
         :github_budget_hold
       ] do
      Map.delete(running_entry, :paused_reason)
    else
      running_entry
    end
  end

  defp maybe_clear_control_owned_pause(running_entry, _request, _status), do: running_entry

  defp maybe_clear_pending_pause_reason(running_entry, %{action: :pause, request_id: request_id}, :paused) do
    case Map.get(running_entry, :pending_pause_reason) do
      %{request_id: ^request_id} -> Map.delete(running_entry, :pending_pause_reason)
      _ -> running_entry
    end
  end

  defp maybe_clear_pending_pause_reason(running_entry, %{action: :resume}, :working),
    do: Map.delete(running_entry, :pending_pause_reason)

  defp maybe_clear_pending_pause_reason(running_entry, _request, _status), do: running_entry

  defp control_transition_cause(%{action: :resume, requester: :operator}, :working, _pause_reason),
    do: :operator_resume

  defp control_transition_cause(%{action: :resume}, :working, _pause_reason), do: :automatic_resume
  defp control_transition_cause(_request, _status, pause_reason), do: pause_reason

  defp finalize_applied_resume(state, issue_id, %{action: :resume, requester: requester}) do
    now = DateTime.utc_now()
    operator? = requester == :operator

    state
    |> PushRouting.finalize_applied_resume(issue_id)
    |> update_in([Access.key(:running)], &Clocks.reset_last_codex_timestamp(&1, issue_id, now))
    |> update_in([Access.key(:running)], &Clocks.reset_duration_clock_if_capped(&1, issue_id, now, operator?))
    |> then(fn state -> if operator?, do: Dispatcher.reset_thrash_budget(state, issue_id), else: state end)
  end

  defp finalize_applied_resume(state, _issue_id, _request), do: state

  @spec transition_control_status(State.t(), map(), atom(), String.t()) :: State.t()
  def transition_control_status(%State{} = state, running_entry, new_status, reason) do
    previous_pause_reason = Map.get(running_entry, :paused_reason)
    running_entry = running_entry |> normalize_pause_context(new_status) |> clear_agent_pause_on_work(new_status)
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    identifier = Map.get(running_entry, :identifier)
    existing = Map.get(running_entry, :control, %{})
    old_status = Map.get(existing, :status, :working)

    if old_status == new_status do
      %{state | running: Map.put(state.running, issue_id, running_entry)}
    else
      Logger.info("Control status: identifier=#{identifier} #{old_status} -> #{new_status} reason=#{reason}")

      now = DateTime.utc_now()

      next_entry =
        running_entry
        |> put_control_status(new_status)
        |> State.apply_pause_runtime_clock(old_status, new_status, now)

      next_state = %{state | running: Map.put(state.running, issue_id, next_entry)}
      ControlRequest.record_control_transition(next_entry, old_status, new_status, reason)
      OperatorMessages.maybe_emit_agent_control_alert(old_status, new_status, next_entry, previous_pause_reason)
      StatusReport.notify_dashboard(next_state)
      next_state
    end
  end

  defp normalize_pause_context(running_entry, :paused) do
    if Map.get(running_entry, :paused_reason) in [:blocker_dependency, :github_budget_hold] do
      running_entry
    else
      running_entry
      |> Map.delete(:blocker_pause)
      |> GithubBudgetPause.clear_context()
    end
  end

  defp normalize_pause_context(running_entry, _status), do: running_entry

  defp maybe_auto_resume_spurious_worker_pause(
         state,
         %{paused_reason: reason} = running_entry,
         :paused
       )
       when reason in [:input_required, :worker_pause_unknown, :pause_containment] do
    case Resume.resume_paused_issue(state, running_entry) do
      {{:ok, :resumed}, state} ->
        state

      {{:error, reason}, state} ->
        Logger.warning("orchestrator.pause_resume_deferred issue_identifier=#{Map.get(running_entry, :identifier)} cause=#{Map.get(running_entry, :paused_reason)} reason=#{inspect(reason)}")

        state
    end
  end

  defp maybe_auto_resume_spurious_worker_pause(state, _running_entry, _status), do: state

  defp worker_pause_reason(state, running_entry, pause_payload, request) do
    pending_pause_reason(running_entry, request) ||
      Map.get(running_entry, :paused_reason) ||
      pending_unclassified_pause_reason(state, running_entry, pause_payload) ||
      Map.get(pause_payload, :kind) ||
      Map.get(pause_payload, "kind") ||
      request_pause_reason(request, pause_payload)
  end

  defp pending_unclassified_pause_reason(state, running_entry, pause_payload) do
    if (Map.get(pause_payload, :kind) || Map.get(pause_payload, "kind")) in [nil, :worker_pause_unknown, "worker_pause_unknown"] do
      with reason when not is_nil(reason) and reason != :operator_pause <-
             get_in(running_entry, [:pending_pause_reason, :reason]),
           %{action: :pause} <- PauseRequest.matching_pending_pause(state, running_entry, reason) do
        reason
      else
        _ -> nil
      end
    end
  end

  defp request_pause_reason(%{action: :pause, requester: :operator}, _pause_payload), do: :operator_pause
  defp request_pause_reason(%{action: :pause}, _pause_payload), do: :automatic_pause

  defp request_pause_reason(_request, pause_payload) do
    if Map.has_key?(pause_payload, :request_id), do: :pause_containment, else: :worker_pause_unknown
  end

  defp maybe_put_worker_pause_reason(entry, :paused, pause_reason),
    do: Map.put(entry, :paused_reason, pause_reason)

  defp maybe_put_worker_pause_reason(entry, _status, _pause_reason), do: entry

  defp maybe_log_worker_pause(:paused, running_entry, pause_reason) do
    Logger.warning(
      "orchestrator.pause issue_id=#{get_in(running_entry, [:issue, Access.key(:id)])} issue_identifier=#{Map.get(running_entry, :identifier)} cause=#{pause_reason} source=worker_control_state"
    )
  end

  defp maybe_log_worker_pause(_status, _running_entry, _pause_reason), do: :ok

  defp pending_pause_reason(running_entry, %{action: :pause, request_id: request_id}) do
    case Map.get(running_entry, :pending_pause_reason) do
      %{request_id: ^request_id, reason: reason} -> reason
      _ -> nil
    end
  end

  defp pending_pause_reason(_running_entry, _request), do: nil

  defp sync_pause_reason_label(state, running_entry, previous_status, previous_reason, status, reason) do
    previous_modifier = if previous_status == :paused, do: pause_reason_modifier(previous_reason), else: nil
    current_modifier = if status == :paused, do: pause_reason_modifier(reason), else: nil

    if previous_modifier == current_modifier, do: state, else: schedule_pause_reason_label(state, running_entry, previous_modifier, current_modifier)
  end

  defp schedule_pause_reason_label(state, running_entry, previous_modifier, current_modifier) do
    issue = Map.get(running_entry, :issue)
    identifier = Map.get(issue || %{}, :identifier) || Map.get(issue || %{}, :id)

    if is_binary(identifier) do
      TrackerTasks.chain(
        state,
        {:runtime_reason_labels, identifier},
        fn -> write_pause_reason_labels(identifier, previous_modifier, current_modifier, Map.get(running_entry, :tracker_label_writer)) end,
        &log_pause_reason_label_result/2
      )
    else
      state
    end
  end

  defp write_pause_reason_labels(identifier, previous_modifier, current_modifier, writer) do
    case maybe_write_pause_reason_label(identifier, :add, current_modifier, writer) do
      :ok -> maybe_write_pause_reason_label(identifier, :remove, previous_modifier, writer)
      error -> error
    end
  end

  defp maybe_write_pause_reason_label(_identifier, _action, nil, _writer), do: :ok

  defp maybe_write_pause_reason_label(identifier, action, modifier, writer) when is_function(writer, 3),
    do: writer.(identifier, action, TicketTransition.reason_modifier_label(modifier))

  defp maybe_write_pause_reason_label(identifier, action, modifier, _writer),
    do: TicketTransition.write_reason_modifier(identifier, action, modifier, writer: :worker_control)

  defp log_pause_reason_label_result(state, :ok), do: state

  defp log_pause_reason_label_result(state, {:error, reason}) do
    Logger.warning("runtime pause reason label update failed: reason=#{inspect(reason)}")
    state
  end

  defp pause_reason_modifier(reason), do: TicketTransition.runtime_reason_modifier(reason)
end
