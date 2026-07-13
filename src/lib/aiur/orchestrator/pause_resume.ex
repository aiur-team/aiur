defmodule Aiur.Orchestrator.PauseResume do
  @moduledoc """
  Owns the pause, resume, and reactivation state machine for running agents.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.{Config, Issue, Tracker}
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

  @spec resume_issue(State.t(), String.t()) :: {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_issue(%State{} = state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        cond do
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

      %{control: %{status: :deactivated}} = running_entry ->
        Reconciler.refresh_running_entry_issue(state, issue, running_entry)

      %{control: %{status: :paused}} = running_entry ->
        running_entry =
          running_entry
          |> Map.put(:issue, issue)
          |> Map.put(:paused_reason, :label_override)

        transition_control_status(state, running_entry, :paused, "label_override")

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
  # without flipping state when all slots are full. The operator can
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

  # Operator pause from the list/CLI. Optimistically flip the entry to `:paused`
  # (mirrors `maybe_pause_on_request` and the Ctrl+C path) so the row reflects
  # the pause immediately — even mid-spin-up, before the worker reaches a
  # checkpoint — then queue the cooperative `{:pause_agent}` control message.
  defp pause_running_or_inactive(state, running_entry, issue_identifier) do
    if State.deactivated_running_entry?(running_entry) do
      {{:error, :already_inactive}, state}
    else
      reply = send_pause_control_message(state, issue_identifier)
      paused_entry = Map.put(running_entry, :paused_reason, :operator_pause)
      {reply, transition_control_status(state, paused_entry, :paused, "operator.pause")}
    end
  end

  @doc false
  @spec send_pause_control_message(State.t(), String.t()) :: term()
  def send_pause_control_message(state, issue_identifier) do
    OperatorMessages.send_running_control_message(state, issue_identifier, fn request_id ->
      {:pause_agent, request_id}
    end)
  end

  @spec handle_worker_control_state(State.t(), String.t(), :paused | :working, map()) ::
          {:noreply, State.t()}
  def handle_worker_control_state(%State{running: running} = state, issue_id, status, pause_payload) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        previous_status = get_in(running_entry, [:control, :status]) || :working
        pause_reason = worker_pause_reason(running_entry, pause_payload)

        updated_running_entry =
          running_entry
          |> put_in([:control, :status], status)
          |> State.apply_pause_runtime_clock(previous_status, status, DateTime.utc_now())
          |> maybe_put_worker_pause_reason(status, pause_reason)

        maybe_log_worker_pause(status, updated_running_entry, pause_reason)
        record_control_transition(updated_running_entry, previous_status, status, pause_reason)
        OperatorMessages.maybe_emit_agent_control_alert(previous_status, status, updated_running_entry)

        state = %{state | running: Map.put(running, issue_id, updated_running_entry)}
        state = maybe_auto_resume_spurious_worker_pause(state, updated_running_entry, status)
        StatusReport.notify_dashboard(state)
        {:noreply, state}
    end
  end

  @spec transition_control_status(State.t(), map(), atom(), String.t()) :: State.t()
  def transition_control_status(%State{} = state, running_entry, new_status, reason) do
    running_entry = normalize_pause_context(running_entry, new_status)
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
        |> Map.put(:control, Map.put(existing, :status, new_status))
        |> State.apply_pause_runtime_clock(old_status, new_status, now)

      next_state = %{state | running: Map.put(state.running, issue_id, next_entry)}
      record_control_transition(next_entry, old_status, new_status, reason)
      OperatorMessages.maybe_emit_agent_control_alert(old_status, new_status, next_entry)
      StatusReport.notify_dashboard(next_state)
      next_state
    end
  end

  defp normalize_pause_context(running_entry, :paused) do
    if Map.get(running_entry, :paused_reason) == :blocker_dependency do
      running_entry
    else
      running_entry
      |> Map.delete(:blocker_pause)
      |> Map.delete(:pending_auto_resume)
    end
  end

  defp normalize_pause_context(running_entry, _status), do: running_entry

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

    # Reactivation is a deliberate operator restart; clear the thrash
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
        # wake and the comment path can emit its durable operator alert.
        restored_state = %{dispatched_state | running: Map.put(dispatched_state.running, issue_id, running_entry)}
        {{:error, :dispatch_not_started}, TrackedSet.refresh(restored_state)}
    end
  end

  # `operator?` distinguishes a deliberate operator resume (label flip,
  # chat reply) from an automated/blocker auto-resume. It only matters
  # for a duration-capped pause: an operator resume is "check in, keep
  # going" and earns a fresh budget; an automated resume must PRESERVE
  # the cumulative overrun so a runaway is still bounded (see
  # `reset_duration_clock_if_capped/4`). Defaults to operator so the
  # operator-facing callers stay unchanged.
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
    case OperatorMessages.send_running_control_message(state, Map.get(running_entry, :identifier), fn request_id ->
           {:resume_agent, request_id}
         end) do
      {:ok, _request_id} ->
        issue_id = get_in(running_entry, [:issue, Access.key(:id)])
        previous_status = get_in(running_entry, [:control, :status]) || :working
        now = DateTime.utc_now()
        state = put_running_control_status(state, issue_id, :working)
        state = update_in(state.running, &State.thaw_pause_clock(&1, issue_id, previous_status, now))
        # Reset `last_codex_timestamp` to NOW so the stall watchdog
        # gives the freshly-resumed entry a full timeout window. A
        # blockee that paused for longer than `stall_timeout_ms` waiting
        # on its blocker would otherwise resume with a stale activity
        # timestamp and be killed on the very next reconcile tick before
        # any codex notification could refresh the field.
        state = update_in(state.running, &reset_last_codex_timestamp(&1, issue_id, now))
        # A duration-capped pause froze the entry after its *active*
        # runtime already exceeded `max_agent_duration`. An OPERATOR resume
        # is a deliberate "check in, keep going," so reset `started_at` to
        # NOW for a fresh budget (a plain thaw only excludes the paused
        # interval, leaving `running_seconds` over the cap, which the next
        # reconcile tick would re-pause in a loop). An AUTOMATED/blocker
        # auto-resume must NOT reset the clock — otherwise a duration-capped
        # agent that declared a blocker would get a fresh full budget on
        # every blocker push and a true runaway would never be bounded; the
        # preserved overrun re-trips the cap on the next tick. Either way we
        # drop the `:max_agent_duration` reason since the entry is now
        # working (the cap re-stamps it fresh if it overruns again).
        state =
          update_in(state.running, &reset_duration_clock_if_capped(&1, issue_id, now, operator?))

        # An operator-driven resume is a deliberate restart, so clear any
        # thrash budget the entry accrued before it paused — otherwise a
        # long-paused blockee could resume already over its window.
        state = Dispatcher.reset_thrash_budget(state, issue_id)
        # Sync-flip happens here so the cap accounting stays consistent.
        # That means the worker's later `:worker_control_state :working`
        # confirmation finds previous_status already :working and emits
        # no transition alert — so emit the unpause alert ourselves now.
        updated_entry = Map.get(state.running, issue_id, running_entry)
        resume_cause = if operator?, do: :operator_resume, else: :automatic_resume
        record_control_transition(updated_entry, previous_status, :working, resume_cause)
        OperatorMessages.maybe_emit_agent_control_alert(previous_status, :working, updated_entry)
        {{:ok, :resumed}, state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

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

  # Resume-side handling for a duration-capped pause. Always drops the
  # `paused_reason` marker so a later manual pause is attributed correctly
  # and so the overrun check re-stamps it fresh if the agent overruns again.
  #
  # `operator?: true` ALSO restarts the duration baseline (`started_at` ->
  # now) so an operator resume hands the agent a full fresh budget.
  #
  # `operator?: false` PRESERVES `started_at` (the cumulative overrun) so an
  # automated/blocker auto-resume cannot silently reset the budget: the
  # entry resumes already over the cap and the next overrun tick re-pauses
  # it, which is the runaway safety net — a wedged duration-capped agent
  # that keeps getting auto-resumed on blocker unblocked signals stays bounded
  # instead of running forever.
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

      %{paused_reason: _reason} = entry ->
        Map.put(running, issue_id, Map.delete(entry, :paused_reason))

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

  defp worker_pause_reason(running_entry, pause_payload) do
    Map.get(running_entry, :paused_reason) ||
      Map.get(pause_payload, :kind) ||
      Map.get(pause_payload, "kind") ||
      if(Map.has_key?(pause_payload, :request_id),
        do: :pause_containment,
        else: :worker_pause_unknown
      )
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

      # Manual start (operator pressed space on a queued ticket): paused
      # agents are excluded from the cap so the operator can fill a free
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
