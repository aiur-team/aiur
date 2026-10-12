defmodule Aiur.Orchestrator.PauseResume.Resume do
  @moduledoc """
  Resumes running, paused, and queued issues and reactivates stopped ones.
  """

  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.Parking
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Orchestrator.PauseResume.CompletedReplacement
  alias Aiur.Orchestrator.PauseResume.ControlRequest
  alias Aiur.Orchestrator.PauseResume.PauseRequest
  alias Aiur.Orchestrator.PauseResume.QueuedDispatch
  alias Aiur.Orchestrator.PauseResume.TrackerControl
  alias Aiur.Orchestrator.RemoteControlMode
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackedSet
  alias Aiur.Orchestrator.TrackerTasks
  require Logger

  @spec resume_issue(State.t(), String.t()) ::
          {{:ok, :resumed | :started | :reactivated | :already_running | :sleeping} | {:error, term()}, State.t()}
  def resume_issue(%State{} = state, issue_identifier) do
    if TrackerTasks.owner?(state) do
      {:reply, reply, next} = run_control_effect(state, :resume, issue_identifier)
      {reply, next}
    else
      resume_issue_with_opts(state, issue_identifier, [])
    end
  end

  defp run_control_effect(state, action, identifier, stage \\ :start, result \\ nil) do
    case TrackerControl.tracker_control_call(state, action, identifier, stage, result) do
      {:reply, {:tracker_io, {action, identifier, next_stage}, function, args}, next} ->
        next =
          TrackerTasks.start(next, {:control_effect, identifier}, fn -> TrackerControl.perform_tracker_io(function, args) end, fn current, response ->
            {:reply, _reply, current} = run_control_effect(current, action, identifier, next_stage, response)
            current
          end)

        {:reply, {:ok, :pending}, next}

      reply ->
        reply
    end
  end

  @doc false
  @spec resume_issue_with_opts(State.t(), term(), term()) :: term()
  def resume_issue_with_opts(%State{} = state, issue_identifier, opts) do
    if Keyword.get(opts, :probe_provider_limits?, true) do
      backends = Keyword.get(opts, :backends, DispatchPolicy.read_provider_backends())
      ModelAvailability.probe_stale_limits(backends, opts)
    end

    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        resume_running_issue(state, running_entry)

      nil ->
        QueuedDispatch.resume_queued_issue(state, issue_identifier)
    end
  end

  @doc false
  @spec resume_running_issue(State.t(), term()) :: term()
  def resume_running_issue(%State{} = state, running_entry), do: Parking.resume_running_issue(state, running_entry, &resume_unparked_running_issue/3)

  defp resume_unparked_running_issue(state, running_entry, issue) do
    if is_struct(issue, Issue) and Issue.paused?(issue) do
      run_running_effect(state, running_entry, :clear_pause, fn -> fetch_resuming_issue({running_entry}) end, fn arg1, arg2, arg3 ->
        apply_resuming_issue(arg1, arg2, arg3, {issue})
      end)
    else
      do_resume_running_issue(state, running_entry)
    end
  end

  @doc false
  @spec run_running_effect(State.t(), term(), term(), term(), term()) :: term()
  def run_running_effect(state, running_entry, key, fetch, apply_result) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    generation = running_generation(running_entry)

    if TrackerTasks.owner?(state) do
      next =
        TrackerTasks.start(state, {key, issue_id}, fetch, fn arg1, arg2 ->
          apply_running_effect(arg1, arg2, {apply_result, generation, issue_id})
        end)

      {{:ok, :pending}, next}
    else
      apply_result.(state, running_entry, fetch.())
    end
  end

  defp running_generation(entry), do: Map.take(entry, [:pid, :ref, :control, :paused_reason])

  @doc false
  @spec do_resume_running_issue(State.t(), term()) :: term()
  def do_resume_running_issue(state, running_entry) do
    cond do
      Issue.parked?(Map.get(running_entry, :issue)) ->
        {{:error, :ticket_parked}, state}

      State.completed_provenance?(running_entry) ->
        CompletedReplacement.restart_completed_provenance_issue(state, running_entry)

      State.deactivated_running_entry?(running_entry) ->
        reactivate_issue(state, Map.delete(running_entry, :operator_parked))

      PauseRequest.pending_pause_request?(state, running_entry) ->
        resume_pending_pause(state, running_entry)

      State.paused_running_entry?(running_entry) ->
        resume_paused_issue(state, running_entry)

      true ->
        resume_unpaused_running_issue(state, running_entry)
    end
  end

  # Nothing is paused and no pause is pending, so there is nothing to resume.
  # Say what the entry actually is instead of a blanket `:resumed` (#2699):
  #
  # * `:working` with a live worker is genuinely running (`:already_running`);
  #   with a dead worker it is not (`:worker_not_running`); with no pid yet it
  #   is a staged replacement that has not started (`:worker_not_started`).
  # * `:sleeping` is a live worker whose stream closed while idle. It wakes on
  #   its next event, so resume has nothing to do and says so (`:sleeping`).
  # * `:error` is a worker that failed to start. Resume refuses by name rather
  #   than starting a second worker behind the retry engine, which owns the
  #   restart of a failed start (and the dispatch budget that bounds it).
  # * Any other status is refused by name rather than reported as resumed.
  defp resume_unpaused_running_issue(state, running_entry) do
    case worker_liveness(running_entry) do
      :alive -> {{:ok, :already_running}, state}
      :dead -> {{:error, :worker_not_running}, state}
      :starting -> {{:error, :worker_not_started}, state}
      :sleeping -> {{:ok, :sleeping}, state}
      {:error, failure} -> {{:error, {:worker_startup_failed, failure}}, state}
      {:other, status} -> {{:error, {:not_resumable_control_status, status}}, state}
    end
  end

  # A `pid: nil` entry is staged: a replacement worker is being admitted
  # (for example a rate-limit fallback redispatch), so it has not started yet
  # rather than stopped.
  defp worker_liveness(running_entry) do
    case get_in(running_entry, [:control, :status]) || :working do
      :working -> working_worker_liveness(Map.get(running_entry, :pid))
      :sleeping -> :sleeping
      :error -> {:error, startup_failure_reason(running_entry)}
      status -> {:other, status}
    end
  end

  defp working_worker_liveness(nil), do: :starting
  defp working_worker_liveness(pid), do: if(worker_pid_alive?(pid), do: :alive, else: :dead)

  defp startup_failure_reason(running_entry) do
    case Map.get(running_entry, :runtime_terminal_failure) do
      %{reason: reason} when not is_nil(reason) -> reason
      _unknown -> :unknown
    end
  end

  # `Process.alive?/1` only answers for local pids; a remote pid cannot be
  # probed from here, so it is taken as alive rather than declared stopped.
  defp worker_pid_alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)
  defp worker_pid_alive?(pid) when is_pid(pid), do: true
  defp worker_pid_alive?(_pid), do: false

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

    dispatched_state =
      Dispatcher.do_dispatch_issue(state, issue, nil, worker_host, prior_work: Config.agent_prior_work_continuation?())

    case Map.get(dispatched_state.running, issue_id) do
      %{pid: pid} when is_pid(pid) ->
        unless DispatchPolicy.normalize_issue_state(issue.state) == "rework" do
          ControlRequest.record_control_transition(running_entry, Map.get(existing_control, :status), :working, :reactivation)
        end

        {{:ok, :reactivated}, dispatched_state}

      _ ->
        # `select_worker_host/2`, the thrash breaker, or Task.Supervisor can
        # decline a dispatch after the entry is optimistically made `:working`.
        # Restore the parked entry so the tracker still shows it as needing a
        # wake and the comment path can emit its durable Executor alert.
        reason = reactivation_failure_reason(dispatched_state, issue, worker_host)
        restored_state = %{dispatched_state | running: Map.put(dispatched_state.running, issue_id, running_entry)}
        {{:error, {:dispatch_failed, reason}}, TrackedSet.refresh(restored_state)}
    end
  end

  defp reactivation_failure_reason(state, issue, worker_host) do
    case QueuedDispatch.dispatch_failure_reason(state, issue) do
      :cause_unknown when not is_nil(worker_host) -> :preferred_worker_unavailable
      reason -> reason
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
    case resume_paused_issue_preflight(state, running_entry) do
      :ok -> ControlRequest.send_resume_control_message(state, running_entry, operator?)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @doc false
  @spec resume_paused_issue_preflight(State.t(), map()) :: :ok | {:error, :max_concurrent_agents_reached}
  def resume_paused_issue_preflight(%State{} = state, running_entry) do
    cond do
      # A worker still working under its own pending input pause holds its
      # slot; resuming it supersedes that pause and needs no new capacity.
      # An expired or rejected pause request does not qualify (#2730).
      pending_input_pause?(state, running_entry) ->
        :ok

      # A CI-wait pause releases its reservation; other pauses retain one.
      # In both cases, resume must wait if the active count is already at the
      # cap (for example, after CI-wait capacity was filled by other work).
      State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) ->
        {:error, :max_concurrent_agents_reached}

      not DispatchPolicy.state_slots_available?(Map.get(running_entry, :issue), state) ->
        {:error, :max_concurrent_agents_reached}

      not Slots.resume_worker_slot_available?(state, Map.get(running_entry, :worker_host)) ->
        {:error, :max_concurrent_agents_reached}

      true ->
        :ok
    end
  end

  @doc false
  @spec pending_input_pause?(State.t(), map()) :: boolean()
  def pending_input_pause?(%State{} = state, running_entry) when is_map(running_entry) do
    get_in(running_entry, [:control, :status]) == :working and
      PauseResume.input_pause_reason?(PauseResume.current_pending_pause_reason(state, running_entry))
  end

  defp resume_pending_pause(state, running_entry) do
    case ControlRequest.submit_resume_control_request(state, running_entry, :operator) do
      {{:ok, _request_id}, state} ->
        {{:ok, :resumed}, state}

      {error, state} ->
        {error, state}
    end
  end

  @doc false
  @spec put_running_entry(State.t(), term(), term()) :: term()
  def put_running_entry(state, issue_id, running_entry) when not is_nil(issue_id) do
    %{state | running: Map.put(state.running, issue_id, running_entry)}
  end

  def put_running_entry(state, _issue_id, _running_entry), do: state

  @doc false
  @spec clear_pause_override(term()) :: term()
  def clear_pause_override(%{issue: %Issue{} = issue} = running_entry) do
    case clear_pause_override(issue) do
      {:ok, cleared_issue} -> {:ok, Map.put(running_entry, :issue, cleared_issue)}
      {:error, _reason} = error -> error
    end
  end

  def clear_pause_override(%Issue{} = issue) do
    label = pause_override_label()

    case TicketTransition.write_marker(issue.identifier, :remove, label, writer: :pause_resume) do
      :ok ->
        {:ok,
         issue
         |> RemoteControlMode.remove_issue_label(label)
         |> Map.put(:paused, false)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec pause_override_label() :: term()
  def pause_override_label, do: "#{Config.settings!().tracker.github.label_prefix}:paused"

  defp pause_log_context(entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{Map.get(entry, :identifier)}"
  end

  defp fetch_resuming_issue({running_entry}) do
    clear_pause_override(running_entry)
  end

  defp apply_resuming_issue(current, entry, result, {issue}) do
    case result do
      {:ok, cleared_entry} ->
        cleared_entry = Map.put(entry, :issue, Map.fetch!(cleared_entry, :issue))
        current = put_running_entry(current, issue.id, cleared_entry)
        do_resume_running_issue(current, cleared_entry)

      {:error, reason} ->
        Logger.warning("Pause override clear failed: #{pause_log_context(entry)} reason=#{inspect(reason)}")

        {{:error, {:pause_override_clear_failed, reason}}, current}
    end
  end

  defp apply_running_effect(current, result, {apply_result, generation, issue_id}) do
    entry = Map.get(current.running, issue_id)

    if is_map(entry) and running_generation(entry) == generation do
      {_reply, next} = apply_result.(current, entry, result)
      next
    else
      current
    end
  end
end
