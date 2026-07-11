defmodule Aiur.Orchestrator.PauseResume do
  @moduledoc """
  Owns the pause, resume, and reactivation state machine for running agents.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  require Logger

  @spec resume_issue(State.t(), String.t()) :: {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_issue(%State{} = state, issue_identifier) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        cond do
          State.deactivated_running_entry?(running_entry) ->
            reactivate_issue(state, running_entry)

          State.paused_running_entry?(running_entry) ->
            Orchestrator.resume_label_overridden_issue(state, running_entry)

          true ->
            {{:ok, :resumed}, state}
        end

      nil ->
        resume_queued_issue(state, issue_identifier)
    end
  end

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
      {reply, Orchestrator.transition_control_status(state, paused_entry, :paused, "operator.pause")}
    end
  end

  @doc false
  @spec send_pause_control_message(State.t(), String.t()) :: term()
  def send_pause_control_message(state, issue_identifier) do
    OperatorMessages.send_running_control_message(state, issue_identifier, fn request_id ->
      {:pause_agent, request_id}
    end)
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
    state = Orchestrator.refresh_tracked_set(state)

    Logger.info("Reactivating deactivated issue: identifier=#{Map.get(running_entry, :identifier)}; spawning fresh agent task")

    # Reactivation is a deliberate operator restart; clear the thrash
    # budget so the fresh task starts with a full window.
    state = Dispatcher.reset_thrash_budget(state, issue_id)

    dispatched_state = Dispatcher.do_dispatch_issue(state, issue, nil, worker_host)

    case Map.get(dispatched_state.running, issue_id) do
      %{pid: pid} when is_pid(pid) ->
        {{:ok, :reactivated}, dispatched_state}

      _ ->
        # `select_worker_host/2`, the thrash breaker, or Task.Supervisor can
        # decline a dispatch after the entry is optimistically made `:working`.
        # Restore the parked entry so the tracker still shows it as needing a
        # wake and the comment path can emit its durable operator alert.
        restored_state = %{dispatched_state | running: Map.put(dispatched_state.running, issue_id, running_entry)}
        {{:error, :dispatch_not_started}, Orchestrator.refresh_tracked_set(restored_state)}
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
      # The paused agent already holds a slot, so the limit only blocks
      # resume if the *active* count is already at the cap (which can
      # happen if `max` was lowered while the agent was paused).
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
        OperatorMessages.maybe_emit_agent_control_alert(previous_status, :working, updated_entry)
        {{:ok, :resumed}, state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

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

      %{paused_reason: _reason} = entry ->
        Map.put(running, issue_id, Map.delete(entry, :paused_reason))

      _ ->
        running
    end
  end

  defp maybe_reset_started_at(entry, now, true), do: Map.put(entry, :started_at, now)
  defp maybe_reset_started_at(entry, _now, false), do: entry

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
