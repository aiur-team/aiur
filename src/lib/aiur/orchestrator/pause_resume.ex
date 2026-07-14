defmodule Aiur.Orchestrator.PauseResume do
  @moduledoc """
  Owns the pause, resume, and reactivation state machine for running agents.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.{AgentPubSub, Config, Issue, Tracker}
  alias Aiur.Orchestrator.AgentTeardown
  alias Aiur.Orchestrator.{ControlLifecycle, ControlLifecycleStore}
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.RemoteControlMode
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.Orchestrator.TrackedSet
  alias Aiur.RunTelemetry.Lifecycle
  require Logger

  @spec pause_agent(String.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(issue_identifier), do: pause_agent(Aiur.Orchestrator, issue_identifier)

  @spec pause_agent(GenServer.server(), String.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(server, issue_identifier),
    do: control_api_call(server, {:pause_agent, issue_identifier})

  @spec resume_agent(String.t()) :: {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(issue_identifier), do: resume_agent(Aiur.Orchestrator, issue_identifier)

  @spec resume_agent(GenServer.server(), String.t()) ::
          {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(server, issue_identifier),
    do: control_api_call(server, {:resume_agent, issue_identifier})

  @spec request_control(String.t(), :pause | :resume, pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def request_control(issue_identifier, action, request_id), do: request_control(Aiur.Orchestrator, issue_identifier, action, request_id)

  @spec request_control(GenServer.server(), String.t(), :pause | :resume, pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def request_control(server, issue_identifier, action, request_id)
      when is_binary(issue_identifier) and action in [:pause, :resume] and is_integer(request_id) and request_id > 0 do
    control_api_call(server, {:request_control, issue_identifier, action, request_id})
  end

  @spec control_lifecycle(String.t()) :: {:ok, map()} | {:error, term()}
  def control_lifecycle(issue_identifier), do: control_lifecycle(Aiur.Orchestrator, issue_identifier)

  @spec control_lifecycle(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def control_lifecycle(server, issue_identifier),
    do: control_api_call(server, {:control_lifecycle, issue_identifier})

  @spec resume_issue_call(State.t(), String.t()) :: {:reply, term(), State.t()}
  def resume_issue_call(%State{} = state, issue_identifier) do
    {reply, state} = resume_issue(state, issue_identifier)
    StatusReport.notify_dashboard(state)
    {:reply, reply, state}
  end

  @spec pause_agent_call(State.t(), String.t()) :: {:reply, term(), State.t()}
  def pause_agent_call(%State{} = state, issue_identifier) do
    {reply, state} = pause_agent_reply(state, issue_identifier)
    {:reply, reply, state}
  end

  @spec request_control_call(State.t(), String.t(), :pause | :resume, pos_integer()) :: {:reply, {:ok, pos_integer()} | {:error, term()}, State.t()}
  def request_control_call(%State{} = state, issue_identifier, action, request_id)
      when is_binary(issue_identifier) and action in [:pause, :resume] and is_integer(request_id) and request_id > 0 do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        {reply, state} =
          case action do
            :pause -> submit_control_request(state, running_entry, issue_identifier, :pause, :operator, request_id)
            :resume -> submit_resume_control_request(state, running_entry, :operator, request_id)
          end

        {:reply, reply, state}

      nil ->
        {:reply, {:error, :no_running_agent}, state}
    end
  end

  @spec control_lifecycle_call(State.t(), String.t()) :: {:reply, {:ok, map()} | {:error, term()}, State.t()}
  def control_lifecycle_call(%State{} = state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      %{issue: %{id: issue_id}} ->
        history = ControlLifecycle.history(state.control_lifecycle, issue_id)

        projection = %{
          current_pending:
            case ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
              nil -> nil
              request -> ControlLifecycle.event_payload(request)
            end,
          history: Enum.map(history, &ControlLifecycle.event_payload/1)
        }

        {:reply, {:ok, projection}, state}

      _ ->
        {:reply, {:error, :no_running_agent}, state}
    end
  end

  @doc false
  @spec expire_pending_controls(State.t(), DateTime.t(), non_neg_integer()) :: State.t()
  def expire_pending_controls(%State{} = state, %DateTime{} = now, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    {expired, lifecycle} = ControlLifecycle.expire_due(state.control_lifecycle, timeout_ms, now: now)

    if expired == [] do
      state
    else
      state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()

      Enum.each(expired, fn request ->
        case Map.get(state.running, request.issue_id) do
          %{identifier: identifier} when is_binary(identifier) -> publish_control_lifecycle(identifier, request)
          _ -> :ok
        end
      end)

      state
    end
  end

  @spec resume_issue(State.t(), String.t()) ::
          {{:ok, :resumed | :started} | {:error, term()}, State.t()}
  def resume_issue(%State{} = state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        cond do
          State.completed_provenance?(running_entry) ->
            restart_completed_provenance_issue(state, running_entry)

          State.deactivated_running_entry?(running_entry) ->
            reactivate_issue(state, running_entry)

          State.paused_running_entry?(running_entry) ->
            resume_label_overridden_issue(state, running_entry)

          true ->
            {{:ok, :resumed}, state}
        end

      nil ->
        resume_queued_issue(state, issue_identifier)
    end
  end

  @spec pause_issue_for_label_override(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_label_override(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      nil ->
        RetryEngine.release_issue_claim(state, issue.id)

      %{completed_provenance: true} = running_entry ->
        pause_completed_issue_for_label_override(state, running_entry, issue)

      %{control: %{status: :completed}} = running_entry ->
        pause_completed_issue_for_label_override(state, running_entry, issue)

      %{control: %{status: status}} = running_entry when status in [:deactivated, :paused] ->
        Reconciler.refresh_running_entry_issue(state, issue, running_entry)

      running_entry when is_map(running_entry) ->
        identifier = Map.get(running_entry, :identifier, issue.identifier || issue.id)

        Logger.info("Issue pause override detected: #{State.issue_context(issue)}; pausing active agent")

        _ = send_pause_control_message(state, identifier)

        running_entry =
          running_entry
          |> Map.put(:issue, issue)
          |> Map.put(:paused_reason, :label_override)

        transition_control_status(state, running_entry, :paused, "label_override")

      _ ->
        state
    end
  end

  @spec resume_label_overridden_issue(State.t(), map()) ::
          {{:ok, :resumed} | {:error, term()}, State.t()}
  # Clear the durable tracker override before waking or the next poll parks it again.
  def resume_label_overridden_issue(
        %State{} = state,
        %{paused_reason: :label_override} = running_entry
      ) do
    case clear_pause_override(running_entry) do
      {:ok, cleared_entry} ->
        issue_id = get_in(cleared_entry, [:issue, Access.key(:id)])
        state = %{state | running: Map.put(state.running, issue_id, cleared_entry)}
        resume_paused_issue(state, cleared_entry)

      {:error, reason} ->
        Logger.warning("Pause override clear failed: #{pause_log_context(running_entry)} reason=#{inspect(reason)}")

        {{:error, {:pause_override_clear_failed, reason}}, state}
    end
  end

  def resume_label_overridden_issue(%State{} = state, running_entry),
    do: resume_paused_issue(state, running_entry)

  defp pause_completed_issue_for_label_override(state, running_entry, issue) do
    if State.paused_running_entry?(running_entry) and
         Map.get(running_entry, :paused_reason) == :label_override do
      Reconciler.refresh_running_entry_issue(state, issue, running_entry)
    else
      state = Reconciler.refresh_running_entry_issue(state, issue, running_entry)
      state = AgentTeardown.deactivate_running_issue(state, issue.id)
      parked_entry = Map.fetch!(state.running, issue.id)

      parked_entry =
        parked_entry
        |> Map.put(:issue, issue)
        |> Map.put(:paused_reason, :label_override)

      transition_control_status(state, parked_entry, :paused, "label_override.completed")
    end
  end

  @spec recover_startup_pause_overrides(State.t(), [term()]) :: [term()]
  def recover_startup_pause_overrides(
        %State{initial_dispatch_cycle: true} = state,
        issues
      )
      when is_list(issues) do
    Enum.map(issues, fn
      %Issue{} = issue -> recover_startup_pause_override(state, issue)
      issue -> issue
    end)
  end

  def recover_startup_pause_overrides(_state, issues), do: issues

  # Wake a `:deactivated` running entry: flip its control status to
  # `:working`, re-add the id to the publisher tracked set, and spawn
  # a fresh agent task on the same issue. Mirrors `resume_paused_issue`
  # in shape but uses `do_dispatch_issue` because the deactivated
  # entry has no live pid to send a resume-control message to.
  #
  # Capacity check: returns `{:error, :max_concurrent_agents_reached}`
  # without flipping state when all slots are full. The Executor can
  # retry once a slot opens (a working agent flips to `:deactivated`
  # or merges its PR). No `pending_reactivation` flag — the existing
  # `max_concurrent_agents` gate is the natural backpressure.
  @doc false
  @spec reactivate_issue(State.t(), map()) :: {{:ok, :reactivated} | {:error, term()}, State.t()}
  def reactivate_issue(%State{} = state, running_entry) do
    if State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) do
      {{:error, :max_concurrent_agents_reached}, state}
    else
      do_reactivate(state, running_entry)
    end
  end

  # Pause-key behaviour, split out so the GenServer clause stays at
  # max-depth 2. A `:deactivated` row has no live pid to pause; we
  # return `:already_inactive` and rely on `:resume_agent` to handle
  # the wake path on the same space-key.
  @spec pause_agent_reply(State.t(), String.t()) :: {term(), State.t()}
  def pause_agent_reply(state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        pause_running_or_inactive(state, running_entry, issue_identifier)

      _ ->
        {send_pause_control_message(state, issue_identifier), state}
    end
  end

  # A control admission means the request reached the expected live worker; it
  # is deliberately not a status transition. Only the worker's correlated
  # acknowledgement below may move this entry to `:paused`.
  defp pause_running_or_inactive(state, running_entry, issue_identifier) do
    if State.deactivated_running_entry?(running_entry) or
         State.completed_provenance?(running_entry) do
      {{:error, :already_inactive}, state}
    else
      submit_control_request(state, running_entry, issue_identifier, :pause, :operator)
    end
  end

  @doc false
  @spec send_pause_control_message(State.t(), String.t()) :: term()
  def send_pause_control_message(state, issue_identifier) do
    OperatorMessages.send_running_control_message(state, issue_identifier, fn request_id ->
      {:pause_agent, request_id}
    end)
  end

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

  defp apply_worker_control_state(state, issue_id, running_entry, status, pause_payload, request) do
    previous_status = get_in(running_entry, [:control, :status]) || :working
    pause_reason = worker_pause_reason(running_entry, pause_payload, request)
    transition_cause = control_transition_cause(request, status, pause_reason)

    updated_running_entry =
      running_entry
      |> put_control_status(status)
      |> State.apply_pause_runtime_clock(previous_status, status, DateTime.utc_now())
      |> maybe_put_worker_pause_reason(status, pause_reason)
      |> maybe_clear_control_owned_pause(request, status)

    maybe_log_worker_pause(status, updated_running_entry, pause_reason)
    record_control_transition(updated_running_entry, previous_status, status, transition_cause)
    OperatorMessages.maybe_emit_agent_control_alert(previous_status, status, updated_running_entry)

    state = %{state | running: Map.put(state.running, issue_id, updated_running_entry)}
    state = finalize_applied_resume(state, issue_id, request)
    state = maybe_auto_resume_spurious_worker_pause(state, updated_running_entry, status)
    StatusReport.notify_dashboard(state)
    {:noreply, state}
  end

  defp apply_control_evidence(state, running_entry, status, %{request_id: request_id, generation: generation})
       when is_integer(request_id) and is_integer(generation) do
    case ControlLifecycle.get(state.control_lifecycle, request_id) do
      nil ->
        {:ignored, state}

      request ->
        cond do
          request.issue_id != get_in(running_entry, [:issue, Access.key(:id)]) ->
            {:ignored, state}

          not action_matches_status?(request.action, status) ->
            {:ignored, state}

          control_rejection = control_rejection_class(running_entry, request) ->
            reject_stale_control_evidence(state, running_entry, request, control_rejection)

          true ->
            case ControlLifecycle.apply(state.control_lifecycle, request_id, generation, now: DateTime.utc_now()) do
              {:ok, applied, lifecycle} ->
                state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
                publish_control_lifecycle(Map.get(running_entry, :identifier), applied)
                {:applied, applied, state}

              {:ignored, lifecycle} ->
                {:ignored, %{state | control_lifecycle: lifecycle}}
            end
        end
    end
  end

  defp apply_control_evidence(state, _running_entry, _status, %{request_id: _request_id, generation: _generation}), do: {:ignored, state}
  defp apply_control_evidence(state, _running_entry, _status, _payload), do: {:unrelated, state}

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
        state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
        publish_control_lifecycle(Map.get(running_entry, :identifier), rejected)
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
            state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
            publish_control_lifecycle(Map.get(running_entry, :identifier), expired)
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
    control = Map.get(running_entry, :control, %{})
    current_status = Map.get(control, :status, :working)

    control =
      control
      |> Map.put(:status, status)
      |> maybe_increment_control_version(current_status, status)

    Map.put(running_entry, :control, control)
  end

  defp maybe_increment_control_version(control, status, status), do: control

  defp maybe_increment_control_version(control, _previous_status, _status) do
    if Map.has_key?(control, :version), do: Map.update!(control, :version, &(&1 + 1)), else: control
  end

  defp maybe_clear_control_owned_pause(running_entry, %{action: :resume}, :working) do
    if Map.get(running_entry, :paused_reason) in [:operator_pause, :pause_containment] do
      Map.delete(running_entry, :paused_reason)
    else
      running_entry
    end
  end

  defp maybe_clear_control_owned_pause(running_entry, _request, _status), do: running_entry

  defp control_transition_cause(%{action: :resume, requester: :operator}, :working, _pause_reason),
    do: :operator_resume

  defp control_transition_cause(%{action: :resume}, :working, _pause_reason), do: :automatic_resume
  defp control_transition_cause(_request, _status, pause_reason), do: pause_reason

  defp finalize_applied_resume(state, issue_id, %{action: :resume, requester: requester}) do
    now = DateTime.utc_now()
    operator? = requester == :operator

    state
    |> update_in([Access.key(:running)], &reset_last_codex_timestamp(&1, issue_id, now))
    |> update_in([Access.key(:running)], &reset_duration_clock_if_capped(&1, issue_id, now, operator?))
    |> then(fn state -> if operator?, do: Dispatcher.reset_thrash_budget(state, issue_id), else: state end)
  end

  defp finalize_applied_resume(state, _issue_id, _request), do: state

  @spec transition_control_status(State.t(), map(), atom(), String.t()) :: State.t()
  def transition_control_status(%State{} = state, running_entry, new_status, reason) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    identifier = Map.get(running_entry, :identifier)
    existing = Map.get(running_entry, :control, %{})
    old_status = Map.get(existing, :status, :working)

    if old_status == new_status do
      state
    else
      Logger.info("Control status: identifier=#{identifier} #{old_status} -> #{new_status} reason=#{reason}")

      now = DateTime.utc_now()

      next_entry =
        running_entry
        |> put_control_status(new_status)
        |> State.apply_pause_runtime_clock(old_status, new_status, now)

      next_state = %{state | running: Map.put(state.running, issue_id, next_entry)}
      record_control_transition(next_entry, old_status, new_status, reason)
      OperatorMessages.maybe_emit_agent_control_alert(old_status, new_status, next_entry)
      StatusReport.notify_dashboard(next_state)
      next_state
    end
  end

  @doc false
  @spec replace_completed_issue(State.t(), map(), Issue.t()) :: State.t()
  def replace_completed_issue(%State{} = state, running_entry, %Issue{} = issue) do
    if State.completed_provenance?(running_entry) do
      revalidate_completed_replacement(state, running_entry, issue)
    else
      state
    end
  end

  defp normalize_completed_entry(running_entry, issue) do
    running_entry
    |> Map.put(:issue, issue)
    |> Map.put(:completed_provenance, true)
    |> Map.delete(:paused_reason)
    |> put_in([:control, :status], :completed)
  end

  defp revalidate_completed_replacement(state, running_entry, issue) do
    case Dispatcher.revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           DispatchPolicy.terminal_state_set()
         ) do
      {:ok, refreshed_issue} ->
        dispatch_completed_replacement(state, running_entry, refreshed_issue)

      {:skip, %Issue{} = refreshed_issue} ->
        Reconciler.refresh_running_entry_issue(state, refreshed_issue, running_entry)

      {:skip, :missing} ->
        state

      {:error, reason} ->
        Logger.warning("Completed runner replacement skipped; issue refresh failed: #{State.issue_context(issue)} reason=#{inspect(reason)}")

        state
    end
  end

  defp dispatch_completed_replacement(state, running_entry, issue) do
    running_entry = normalize_completed_entry(running_entry, issue)

    state =
      state
      |> Map.update!(:running, &Map.put(&1, issue.id, running_entry))
      |> Aiur.Orchestrator.cancel_ci_wait_rewake(issue.id)

    worker_host = Map.get(running_entry, :worker_host)

    with true <- Slots.dispatch_slots_available?(issue, state),
         :ok <- Dispatcher.redispatch_ready?(state, issue, worker_host) do
      replace_completed_entry(state, running_entry, issue, worker_host)
    else
      _declined -> state
    end
  end

  defp replace_completed_entry(state, running_entry, issue, worker_host) do
    replace_admitted_completed_entry(
      state,
      running_entry,
      issue,
      worker_host,
      &Dispatcher.do_dispatch_issue/4
    )
  end

  @doc false
  @spec replace_admitted_completed_entry(State.t(), map(), Issue.t(), String.t() | nil, function()) ::
          State.t()
  def replace_admitted_completed_entry(
        state,
        running_entry,
        issue,
        worker_host,
        dispatch_fun
      )
      when is_function(dispatch_fun, 4) do
    issue_id = issue.id

    Logger.info("Replacing completed runner: issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

    _ = Aiur.PauseContainment.release_target(issue.identifier || issue.id)

    next_state =
      state
      |> AgentTeardown.terminate_running_issue(issue_id, false)
      |> dispatch_fun.(issue, nil, worker_host)

    if live_replacement?(next_state, issue_id) do
      next_state
    else
      restore_completed_entry(next_state, running_entry, issue)
    end
  end

  defp live_replacement?(state, issue_id) do
    case Map.get(state.running, issue_id) do
      %{pid: pid, ref: ref, control: %{status: :working}} ->
        is_pid(pid) and Process.alive?(pid) and is_reference(ref)

      _ ->
        false
    end
  end

  defp restore_completed_entry(state, running_entry, issue) do
    issue_id = issue.id

    completed_entry =
      running_entry
      |> Map.put(:issue, issue)
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)
      |> Map.put(:completed_provenance, true)
      |> Map.put(:completion_totals_recorded, true)
      |> put_in([:control, :status], :completed)

    %{
      state
      | running: Map.put(state.running, issue_id, completed_entry),
        claimed: MapSet.put(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp restart_completed_issue(state, running_entry) do
    issue = Map.fetch!(running_entry, :issue)
    next_state = replace_completed_issue(state, running_entry, issue)

    if live_replacement?(next_state, issue.id) do
      {{:ok, :started}, next_state}
    else
      {{:error, :redispatch_deferred}, next_state}
    end
  end

  defp restart_completed_provenance_issue(
         state,
         %{paused_reason: :label_override} = running_entry
       ) do
    case clear_pause_override(running_entry) do
      {:ok, cleared_entry} ->
        issue_id = get_in(cleared_entry, [:issue, Access.key(:id)])
        state = %{state | running: Map.put(state.running, issue_id, cleared_entry)}
        restart_completed_issue(state, cleared_entry)

      {:error, reason} ->
        {{:error, {:pause_override_clear_failed, reason}}, state}
    end
  end

  defp restart_completed_provenance_issue(state, running_entry),
    do: restart_completed_issue(state, running_entry)

  defp do_reactivate(%State{} = state, running_entry) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    existing_control = Map.get(running_entry, :control, %{})
    worker_host = Map.get(running_entry, :worker_host)
    issue = Map.get(running_entry, :issue)

    # Flip the entry to :working before dispatch so any concurrent
    # slot-count lookups see this entry as holding a slot (prevents a
    # double-claim race against another dispatch tick).
    new_entry = Map.put(running_entry, :control, Map.put(existing_control, :status, :working))
    state = %{state | running: Map.put(state.running, issue_id, new_entry)}
    state = TrackedSet.refresh(state)

    Logger.info("Reactivating deactivated issue: identifier=#{Map.get(running_entry, :identifier)}; spawning fresh agent task")

    # Reactivation is a deliberate Executor restart; clear the thrash
    # budget so the fresh task starts with a full window.
    state = Dispatcher.reset_thrash_budget(state, issue_id)

    dispatched_state = Dispatcher.do_dispatch_issue(state, issue, nil, worker_host)

    case Map.get(dispatched_state.running, issue_id) do
      %{pid: pid} when is_pid(pid) ->
        unless DispatchPolicy.normalize_issue_state(issue.state) == "rework" do
          record_control_transition(running_entry, Map.get(existing_control, :status), :working, :reactivation)
        end

        {{:ok, :reactivated}, dispatched_state}

      _ ->
        # `select_worker_host/2`, the thrash breaker, or Task.Supervisor can
        # decline a dispatch after the entry is optimistically made `:working`.
        # Restore the parked entry so the tracker still shows it as needing a
        # wake and the comment path can emit its durable Executor alert.
        restored_state = %{dispatched_state | running: Map.put(dispatched_state.running, issue_id, running_entry)}
        {{:error, :dispatch_not_started}, TrackedSet.refresh(restored_state)}
    end
  end

  # `operator?` distinguishes a deliberate Executor resume (label flip,
  # chat reply) from an automated/blocker auto-resume. It only matters
  # for a duration-capped pause: an Executor resume is "check in, keep
  # going" and earns a fresh budget; an automated resume must PRESERVE
  # the cumulative overrun so a runaway is still bounded (see
  # `reset_duration_clock_if_capped/4`). Defaults to Executor so the
  # Executor-facing callers stay unchanged.
  @doc false
  @spec resume_paused_issue(State.t(), map(), boolean()) :: {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_paused_issue(%State{} = state, running_entry, operator? \\ true) do
    cond do
      # A CI-wait pause releases its reservation; other pauses retain one.
      # In both cases, resume must wait if the active count is already at the
      # cap (for example, after CI-wait capacity was filled by other work).
      State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) ->
        {{:error, :max_concurrent_agents_reached}, state}

      not DispatchPolicy.state_slots_available?(Map.get(running_entry, :issue), state) ->
        {{:error, :max_concurrent_agents_reached}, state}

      not Slots.resume_worker_slot_available?(state, Map.get(running_entry, :worker_host)) ->
        {{:error, :max_concurrent_agents_reached}, state}

      true ->
        send_resume_control_message(state, running_entry, operator?)
    end
  end

  defp send_resume_control_message(%State{} = state, running_entry, operator?) do
    requester = if operator?, do: :operator, else: :automatic

    case submit_resume_control_request(state, running_entry, requester) do
      {{:ok, _request_id}, state} ->
        {{:ok, :resumed}, state}

      {error, state} ->
        {error, state}
    end
  end

  defp submit_resume_control_request(%State{} = state, running_entry, requester, request_id \\ nil) do
    if Map.get(running_entry, :control, %{}) |> Map.get(:status, :working) == :paused do
      cond do
        State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) ->
          {{:error, :max_concurrent_agents_reached}, state}

        not DispatchPolicy.state_slots_available?(Map.get(running_entry, :issue), state) ->
          {{:error, :max_concurrent_agents_reached}, state}

        not Slots.resume_worker_slot_available?(state, Map.get(running_entry, :worker_host)) ->
          {{:error, :max_concurrent_agents_reached}, state}

        true ->
          submit_control_request(
            state,
            running_entry,
            Map.get(running_entry, :identifier),
            :resume,
            requester,
            request_id
          )
      end
    else
      submit_control_request(
        state,
        running_entry,
        Map.get(running_entry, :identifier),
        :resume,
        requester,
        request_id
      )
    end
  end

  defp submit_control_request(%State{} = state, running_entry, issue_identifier, action, requester, request_id \\ nil)
       when action in [:pause, :resume] and is_binary(issue_identifier) and is_atom(requester) do
    request_id = request_id || :erlang.unique_integer([:positive])

    case ControlLifecycle.get(state.control_lifecycle, request_id) do
      nil -> submit_new_control_request(state, running_entry, issue_identifier, action, requester, request_id)
      request -> retry_control_request(state, running_entry, action, requester, request)
    end
  end

  defp retry_control_request(state, running_entry, action, requester, request) do
    if request.issue_id == get_in(running_entry, [:issue, Access.key(:id)]) and request.action == action and request.requester == requester do
      {retry_control_reply(request), state}
    else
      {{:error, :control_request_conflict}, state}
    end
  end

  defp retry_control_reply(%{status: status, request_id: request_id}) when status in [:requested, :accepted, :applied],
    do: {:ok, request_id}

  defp retry_control_reply(%{status: :rejected, rejection: rejection}),
    do: {:error, {:control_rejected, rejection}}

  defp retry_control_reply(%{status: :expired, expiry: expiry}), do: {:error, {:control_expired, expiry}}

  defp submit_new_control_request(%State{} = state, running_entry, issue_identifier, action, requester, request_id) do
    control = Map.get(running_entry, :control, %{})

    attrs = %{
      request_id: request_id,
      issue_id: get_in(running_entry, [:issue, Access.key(:id)]),
      tracker_identity: Issue.tracker_identity(Map.get(running_entry, :issue)),
      action: action,
      generation: Map.get(control, :generation),
      expected_status: Map.get(control, :status, :working),
      expected_version: Map.get(control, :version, 0),
      requester: requester
    }

    case preflight_rejection(control, action) do
      nil ->
        admit_and_route_control_request(state, issue_identifier, action, attrs)

      class ->
        admit_and_reject_control_request(state, issue_identifier, attrs, class)
    end
  end

  defp preflight_rejection(control, :pause) do
    cond do
      Map.get(control, :status, :working) == :paused -> :already_in_state
      Map.get(control, :status, :working) not in [:working, :paused] -> :not_eligible
      Map.get(control, :application_confirmation, :request_only) != :confirmed -> :unsupported
      true -> nil
    end
  end

  defp preflight_rejection(control, :resume) do
    cond do
      Map.get(control, :status, :working) == :working -> :already_in_state
      Map.get(control, :status, :working) not in [:working, :paused] -> :not_eligible
      Map.get(control, :application_confirmation, :request_only) != :confirmed -> :unsupported
      true -> nil
    end
  end

  defp admit_and_reject_control_request(state, issue_identifier, attrs, class) do
    pending = ControlLifecycle.current_pending(state.control_lifecycle, attrs.issue_id)

    case ControlLifecycle.request(state.control_lifecycle, attrs, now: DateTime.utc_now()) do
      {:ok, requested, lifecycle} ->
        state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
        publish_superseded_control_lifecycle(issue_identifier, pending, lifecycle)
        publish_control_lifecycle(issue_identifier, requested)

        case ControlLifecycle.reject(state.control_lifecycle, requested.request_id, class, now: DateTime.utc_now()) do
          {:ok, rejected, lifecycle} ->
            state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
            publish_control_lifecycle(issue_identifier, rejected)
            {{:error, {:control_rejected, rejected.rejection}}, state}

          {:ignored, lifecycle} ->
            {{:error, {:control_rejected, %{class: class}}}, %{state | control_lifecycle: lifecycle}}
        end

      {:duplicate, request, lifecycle} ->
        {retry_control_reply(request), %{state | control_lifecycle: lifecycle}}

      {:error, rejection, lifecycle} ->
        {{:error, {:control_rejected, rejection}}, %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()}
    end
  end

  defp admit_and_route_control_request(state, issue_identifier, action, attrs) do
    pending = ControlLifecycle.current_pending(state.control_lifecycle, attrs.issue_id)

    case ControlLifecycle.request(state.control_lifecycle, attrs, now: DateTime.utc_now()) do
      {:ok, request, lifecycle} ->
        state = %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
        publish_superseded_control_lifecycle(issue_identifier, pending, lifecycle)
        publish_control_lifecycle(issue_identifier, request)

        case OperatorMessages.send_running_control_message(state, issue_identifier, request.request_id, fn _request_id ->
               control_message(action, request)
             end) do
          {:ok, request_id} ->
            case ControlLifecycle.accept(state.control_lifecycle, request_id, request.generation, now: DateTime.utc_now()) do
              {:ok, accepted, lifecycle} ->
                if action == :pause, do: Aiur.PauseContainment.arm(issue_identifier)
                publish_control_lifecycle(issue_identifier, accepted)
                {{:ok, request_id}, %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()}

              {:ignored, lifecycle} ->
                {{:error, :stale_generation}, %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()}
            end

          {:error, reason} ->
            state = reject_routing_failure(state, request.request_id, reason)

            case ControlLifecycle.get(state.control_lifecycle, request.request_id) do
              nil -> :ok
              rejected -> publish_control_lifecycle(issue_identifier, rejected)
            end

            {{:error, reason}, state}
        end

      {:duplicate, request, lifecycle} ->
        {{:ok, request.request_id}, %{state | control_lifecycle: lifecycle}}

      {:error, rejection, lifecycle} ->
        {{:error, {:control_rejected, rejection}}, %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()}
    end
  end

  defp control_message(:pause, request) do
    {:pause_agent, request.request_id, request.generation}
  end

  defp control_message(:resume, request) do
    {:resume_agent, request.request_id, request.generation}
  end

  defp reject_routing_failure(state, request_id, reason) do
    class = if reason in [:agent_finished, :no_running_agent], do: :worker_unavailable, else: :control_failed

    case ControlLifecycle.reject(state.control_lifecycle, request_id, class, now: DateTime.utc_now()) do
      {:ok, _request, lifecycle} -> %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
      {:ignored, lifecycle} -> %{state | control_lifecycle: lifecycle} |> persist_control_lifecycle()
    end
  end

  defp persist_control_lifecycle(%State{} = state) do
    :ok = ControlLifecycleStore.save(state.control_lifecycle)
    state
  end

  defp publish_control_lifecycle(identifier, request) when is_binary(identifier) and is_map(request) do
    AgentPubSub.broadcast_control_lifecycle(identifier, ControlLifecycle.event_payload(request))
  end

  defp publish_control_lifecycle(_identifier, _request), do: :ok

  defp publish_superseded_control_lifecycle(identifier, %{request_id: request_id}, lifecycle) do
    case ControlLifecycle.get(lifecycle, request_id) do
      %{status: :rejected, rejection: %{class: :superseded}} = request ->
        publish_control_lifecycle(identifier, request)

      _ ->
        :ok
    end
  end

  defp publish_superseded_control_lifecycle(_identifier, _pending, _lifecycle), do: :ok

  defp record_control_transition(_running_entry, status, status, _cause), do: :ok

  defp record_control_transition(running_entry, _old_status, :paused, cause) do
    Lifecycle.record(
      Map.get(running_entry, :identifier),
      Map.get(running_entry, :telemetry_attempt_id),
      :agent_pause,
      :point,
      %{cause: cause}
    )
  end

  defp record_control_transition(running_entry, old_status, :working, cause)
       when old_status in [:paused, :deactivated] do
    Lifecycle.record(
      Map.get(running_entry, :identifier),
      Map.get(running_entry, :telemetry_attempt_id),
      :agent_resume,
      :point,
      %{cause: cause}
    )
  end

  defp record_control_transition(_running_entry, _old_status, _new_status, _cause), do: :ok

  @doc false
  @spec reset_last_codex_timestamp(map(), term(), DateTime.t()) :: map()
  def reset_last_codex_timestamp(running, issue_id, %DateTime{} = now) when is_map(running) do
    case Map.get(running, issue_id) do
      entry when is_map(entry) ->
        Map.put(running, issue_id, Map.put(entry, :last_codex_timestamp, now))

      _ ->
        running
    end
  end

  # Resume-side handling for a duration-capped pause. Only this control path
  # owns the `:max_agent_duration` marker; other pause/wait reasons must stay
  # intact until the subsystem that created them clears them.
  #
  # `operator?: true` ALSO restarts the duration baseline (`started_at` ->
  # now) so an Executor resume hands the agent a full fresh budget.
  #
  # `operator?: false` PRESERVES `started_at` (the cumulative overrun) so an
  # automated/blocker auto-resume cannot silently reset the budget: the
  # entry resumes already over the cap and the next overrun tick re-pauses
  # it, which is the runaway safety net — a wedged duration-capped agent
  # that keeps getting auto-resumed on blocker pushes stays bounded instead
  # of running forever.
  #
  # Label-override pauses have no special duration semantics; resuming just
  # clears their attribution marker after the normal pause-clock thaw.
  #
  # A no-op for manually/blocker-paused entries (no marker).
  @doc false
  @spec reset_duration_clock_if_capped(map(), term(), DateTime.t(), boolean()) :: map()
  def reset_duration_clock_if_capped(running, issue_id, %DateTime{} = now, operator?)
      when is_map(running) do
    case Map.get(running, issue_id) do
      %{paused_reason: :max_agent_duration} = entry ->
        updated =
          entry
          |> maybe_reset_started_at(now, operator?)
          |> Map.delete(:paused_reason)

        Map.put(running, issue_id, updated)

      _ ->
        running
    end
  end

  defp maybe_reset_started_at(entry, now, true), do: Map.put(entry, :started_at, now)
  defp maybe_reset_started_at(entry, _now, false), do: entry

  defp maybe_auto_resume_spurious_worker_pause(
         state,
         %{paused_reason: reason} = running_entry,
         :paused
       )
       when reason in [:input_required, :worker_pause_unknown, :pause_containment] do
    case resume_paused_issue(state, running_entry) do
      {{:ok, :resumed}, state} ->
        state

      {{:error, reason}, state} ->
        Logger.warning("orchestrator.pause_resume_deferred issue_identifier=#{Map.get(running_entry, :identifier)} cause=#{Map.get(running_entry, :paused_reason)} reason=#{inspect(reason)}")

        state
    end
  end

  defp maybe_auto_resume_spurious_worker_pause(state, _running_entry, _status), do: state

  defp worker_pause_reason(running_entry, pause_payload, request) do
    Map.get(running_entry, :paused_reason) ||
      Map.get(pause_payload, :kind) ||
      Map.get(pause_payload, "kind") ||
      request_pause_reason(request, pause_payload)
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

  defp resume_queued_issue(%State{} = state, issue_identifier) do
    issue =
      state.last_polled_issues
      |> Map.values()
      |> Enum.find(fn
        %Issue{identifier: ^issue_identifier} -> true
        _ -> false
      end)

    cond do
      is_nil(issue) ->
        {{:error, :no_running_agent}, state}

      # Manual start (Executor pressed space on a queued ticket): paused
      # agents are excluded from the cap so the Executor can fill a free
      # active slot even when a paused agent is parked in `running`.
      State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) ->
        {{:error, :max_concurrent_agents_reached}, state}

      not DispatchPolicy.dispatch_candidate?(
        issue,
        state,
        DispatchPolicy.active_state_set(),
        DispatchPolicy.terminal_state_set()
      ) ->
        {{:error, :not_resumable}, state}

      true ->
        next_state = Dispatcher.dispatch_issue(state, issue)

        if MapSet.member?(next_state.claimed, issue.id) do
          {{:ok, :started}, next_state}
        else
          {{:error, :dispatch_failed}, next_state}
        end
    end
  end

  defp recover_startup_pause_override(%State{} = state, %Issue{} = issue) do
    active_states = DispatchPolicy.active_state_set()

    if Issue.paused?(issue) and
         DispatchPolicy.active_issue_state?(issue.state, active_states) and
         not Map.has_key?(state.running, issue.id) do
      case clear_pause_override(issue) do
        {:ok, cleared_issue} ->
          Logger.info("Recovered stale pause override on startup: #{State.issue_context(issue)}")
          cleared_issue

        {:error, reason} ->
          Logger.warning("Startup pause override recovery deferred: #{State.issue_context(issue)} reason=#{inspect(reason)}")

          issue
      end
    else
      issue
    end
  end

  defp clear_pause_override(%{issue: %Issue{} = issue} = running_entry) do
    case clear_pause_override(issue) do
      {:ok, cleared_issue} -> {:ok, Map.put(running_entry, :issue, cleared_issue)}
      {:error, _reason} = error -> error
    end
  end

  defp clear_pause_override(%Issue{} = issue) do
    label = pause_override_label()

    case Tracker.remove_label(issue.identifier, label) do
      :ok ->
        {:ok,
         issue
         |> RemoteControlMode.remove_issue_label(label)
         |> Map.put(:paused, false)}

      {:error, _reason} = error ->
        error
    end
  end

  defp pause_override_label, do: "#{Config.settings!().tracker.github.label_prefix}:paused"

  defp pause_log_context(entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{Map.get(entry, :identifier)}"
  end

  defp control_api_call(server, request) do
    if GenServer.whereis(server) do
      GenServer.call(server, request, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  @spec put_running_control_status(State.t(), String.t(), :paused | :working) :: State.t()
  def put_running_control_status(%State{} = state, issue_id, status)
      when is_binary(issue_id) and status in [:paused, :working] do
    update_in(state.running, fn running ->
      case Map.get(running, issue_id) do
        nil -> running
        entry -> Map.put(running, issue_id, put_in(entry, [:control, :status], status))
      end
    end)
  end

  def put_running_control_status(%State{} = state, _issue_id, _status), do: state
end
