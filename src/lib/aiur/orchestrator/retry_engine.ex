defmodule Aiur.Orchestrator.RetryEngine do
  @moduledoc """
  Retry scheduling and budget semantics for agent dispatch failures.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger
  import Bitwise, only: [<<<: 2]

  alias Aiur.{AgentPubSub, AgentQueueStore, Alerts, Config, CurrentRunMembership, Issue, Tracker, TrackerIdentity}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Workspace.Ownership

  alias Aiur.Orchestrator.{
    AgentTeardown,
    AutoResume,
    ControlLifecycle,
    ControlLifecycleStore,
    DispatchPolicy,
    MembershipLifecycle,
    Reconciler,
    Slots,
    State,
    StatusReport,
    TokenAccounting
  }

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @max_retry_poll_failures 3

  @spec handle_retry_message(State.t(), String.t(), reference()) :: {:noreply, State.t()}
  def handle_retry_message(%State{} = state, issue_id, retry_token) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, next_state} ->
          handle_retry_issue(next_state, issue_id, attempt, metadata)

        :missing ->
          {:noreply, state}
      end

    publish_final_retry_state(result)
  end

  @doc false
  @spec publish_final_retry_state({:noreply, State.t()}) :: {:noreply, State.t()}
  def publish_final_retry_state({:noreply, final_state} = result) do
    StatusReport.notify_dashboard(final_state)
    result
  end

  @spec handle_agent_down(State.t(), reference(), term()) :: {:noreply, State.t()}
  def handle_agent_down(%State{running: running} = state, ref, reason) do
    case State.find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        running_entry = running |> Map.fetch!(issue_id) |> clear_completed_fallback_replacement()
        state = expire_pending_control(state, running_entry, issue_id)
        state = TokenAccounting.record_session_completion_totals(state, running_entry)
        state = maybe_reap_orphaned_agent_shell(state, running_entry)
        session_id = State.running_entry_session_id(running_entry)
        state = handle_running_agent_down(state, issue_id, running_entry, reason, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        StatusReport.notify_dashboard(state)
        {:noreply, state}
    end
  end

  defp handle_running_agent_down(
         state,
         issue_id,
         %{runtime_terminal_failure: %{kind: :startup_failed} = failure} = running_entry,
         _reason,
         session_id
       ) do
    reason = Map.get(failure, :reason)

    Logger.warning("Agent startup failed for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling failure retry")

    state
    |> remove_stopped_running_entry(issue_id, running_entry)
    |> schedule_issue_retry(
      issue_id,
      next_retry_attempt_from_running(running_entry),
      runtime_terminal_failure_retry_metadata(running_entry, reason)
    )
  end

  defp handle_running_agent_down(state, issue_id, running_entry, :normal, session_id) do
    if State.completed_running_entry?(running_entry) do
      Logger.info("Completed agent task exited normally for issue_id=#{issue_id} session_id=#{session_id}; parking replaceable entry")
      park_completed_entry(state, issue_id, running_entry)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> remove_stopped_running_entry(issue_id, running_entry)
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, continuation_retry_metadata(running_entry))
    end
  end

  defp handle_running_agent_down(state, issue_id, running_entry, reason, session_id) do
    if State.completed_running_entry?(running_entry) do
      Logger.warning("Completed agent task exited abnormally for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; preserving completed boundary")
      park_completed_entry(state, issue_id, running_entry)
    else
      Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

      state
      |> remove_stopped_running_entry(issue_id, running_entry)
      |> schedule_issue_retry(issue_id, exit_retry_attempt(running_entry, reason), exit_retry_metadata(running_entry, reason))
    end
  end

  # A local GitHub budget hold in an agent exit reason is definitionally
  # transient: retrying before its own `reset_at` is guaranteed to fail, so the
  # retry is scheduled after `reset_at` and must not consume the ticket's
  # failure retry budget. Without this, a seconds-long hold exhausts
  # `max_retry_attempts` and stamps the ticket `agent:error` — the #2339
  # casualty, where a hold with 97% of the real budget free killed the ticket
  # (#2429). `local_budget_hold_reason/1` is the single extraction used by both
  # this path and retry-poll deferral, so every shape a hold can arrive in
  # (raw, `:local_hold`, legacy transport, workspace preflight wrapper, preflight
  # diagnostic) is treated identically.
  #
  # A hold-caused exit must also leave the failure attempt counter untouched:
  # the retry reuses the attempt this run was dispatched at rather than
  # incrementing it. Incrementing would let repeated holds push the stored
  # attempt above `Config.max_retry_attempts()`, so the *first* genuine failure
  # after them would hit the `next_attempt > max` give-up branch and stamp
  # `agent:error` on attempt one of the real work — the same #2339 casualty,
  # one step removed. A fresh dispatch (`retry_attempt` absent or 0) schedules
  # its first retry at attempt 1, matching the non-hold path.
  defp exit_retry_attempt(running_entry, reason) do
    case local_budget_hold_reason(reason) do
      %{} ->
        case Map.get(running_entry, :retry_attempt) do
          attempt when is_integer(attempt) and attempt > 0 -> attempt
          _ -> 1
        end

      nil ->
        next_retry_attempt_from_running(running_entry)
    end
  end

  defp exit_retry_metadata(running_entry, reason) do
    case local_budget_hold_reason(reason) do
      %{} = hold ->
        running_entry
        |> failure_retry_metadata(reason)
        |> Map.merge(%{delay_type: :local_budget_hold, local_budget_hold: hold})

      nil ->
        failure_retry_metadata(running_entry, reason)
    end
  end

  defp remove_stopped_running_entry(state, issue_id, running_entry) do
    if fallback_replacement?(running_entry) do
      park_failed_fallback_replacement(state, issue_id, running_entry)
    else
      {_running_entry, popped_state} = State.pop_running_entry(state, issue_id)
      popped_state
    end
  end

  defp continuation_retry_metadata(running_entry) do
    issue = Map.get(running_entry, :issue)

    %{
      identifier: running_entry.identifier,
      tracker_identity: Issue.tracker_identity(issue),
      priority: Map.get(issue || %{}, :priority),
      issue_state: Map.get(issue || %{}, :state),
      delay_type: :continuation,
      prior_work: prior_work_for_retry?(running_entry),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    }
  end

  defp failure_retry_metadata(running_entry, reason) do
    issue = Map.get(running_entry, :issue)

    %{
      identifier: running_entry.identifier,
      tracker_identity: Issue.tracker_identity(issue),
      priority: Map.get(issue || %{}, :priority),
      issue_state: Map.get(issue || %{}, :state),
      error: "agent exited: #{inspect(reason)}",
      # Structured failure reason retained so retry exhaustion can classify it
      # as a transient infrastructure fault for the #1453 automatic
      # re-dispatch (the formatted `error` string cannot).
      transient_reason: reason,
      prior_work: prior_work_for_retry?(running_entry),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    }
  end

  defp runtime_terminal_failure_retry_metadata(running_entry, reason) do
    running_entry
    |> failure_retry_metadata({:startup_failed, reason})
    |> Map.put(:error, "startup failed: #{inspect(reason)}")
  end

  defp maybe_reap_orphaned_agent_shell(state, running_entry) do
    if State.completed_running_entry?(running_entry) do
      state
    else
      case AgentTeardown.reap_orphaned_agent_shell(running_entry) do
        :reaped ->
          count = Map.get(state, :orphaned_agent_reap_count, 0) + 1
          identifier = Map.get(running_entry, :identifier)

          _ =
            Alerts.emit_custom(
              "ticket.#{identifier}.agent.orphan_reaped",
              "Reaped orphaned agent shell for #{identifier}; orphaned_agent_reap_count=#{count}",
              issue: Map.get(running_entry, :issue),
              workspace: Map.get(running_entry, :workspace_path),
              worker_host: Map.get(running_entry, :worker_host),
              reason: "agent runner exited while its tracked shell process tree remained live",
              needs_attention: true
            )

          %{state | orphaned_agent_reap_count: count}

        :gone ->
          state
      end
    end
  end

  defp expire_pending_control(state, running_entry, issue_id) do
    case ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
      nil ->
        state

      pending ->
        case ControlLifecycle.expire(state.control_lifecycle, pending.request_id, :worker_unavailable, now: DateTime.utc_now()) do
          {:ok, expired, lifecycle} ->
            :ok = ControlLifecycleStore.save(lifecycle)
            AgentPubSub.broadcast_control_lifecycle(Map.get(running_entry, :identifier), ControlLifecycle.event_payload(expired))
            %{state | control_lifecycle: lifecycle}

          {:ignored, lifecycle} ->
            %{state | control_lifecycle: lifecycle}
        end
    end
  end

  defp park_completed_entry(state, issue_id, running_entry) do
    parked_entry =
      running_entry
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)
      |> Map.put(:completion_totals_recorded, true)

    %{
      state
      | running: Map.put(state.running, issue_id, parked_entry),
        completed: MapSet.put(state.completed, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  # Fallback startup can fail after its Task is admitted (for example, a
  # provider rejects a model). Keep the replacement entry parked with the
  # original lifecycle fence, and put only its authoritative failed queue
  # items back to pending before the retry. This prevents the replacement's
  # failure from silently dropping the fenced rework packet.
  defp park_failed_fallback_replacement(state, issue_id, running_entry) do
    queue_store = restore_fenced_failed_items(state.queue_store, Map.get(running_entry, :lifecycle_fence))

    parked_entry =
      running_entry
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)
      |> Map.update(:control, %{status: :completed}, &Map.put(&1, :status, :completed))

    %{state | queue_store: queue_store, running: Map.put(state.running, issue_id, parked_entry)}
  end

  defp fallback_replacement?(running_entry), do: Map.get(running_entry, :rate_limit_fallback_replacement) == true

  # The marker protects only a replacement that has not completed any work:
  # its startup exit must retain the lifecycle fence for retry. Once the
  # replacement completes a turn, its next task exit is the pop boundary, so
  # a later dispatch selects the provider from the freshly fetched issue.
  defp clear_completed_fallback_replacement(running_entry) do
    if fallback_replacement?(running_entry) and
         positive_turn_count?(Map.get(running_entry, :completed_turn_count)) do
      Map.delete(running_entry, :rate_limit_fallback_replacement)
    else
      running_entry
    end
  end

  defp restore_fenced_failed_items(queue_store, %{pending_item_ids: %MapSet{} = item_ids}) do
    Enum.reduce(item_ids, queue_store, fn item_id, store ->
      {next_store, _item} = AgentQueueStore.restore_failed_pending(store, item_id)
      next_store
    end)
  end

  defp restore_fenced_failed_items(queue_store, _fence), do: queue_store

  @doc false
  @spec wait_for_workspace_ownership(State.t(), String.t(), String.t(), term(), term()) :: State.t()
  def wait_for_workspace_ownership(%State{} = state, issue_id, identifier, owner, wait)
      when is_binary(issue_id) and is_binary(identifier) do
    context = workspace_wait_context(state, issue_id)
    demonitor_workspace_runner(context.running)
    waiting_state = install_workspace_wait(state, issue_id, identifier, owner, context)
    synchronize_workspace_wait(waiting_state, identifier, wait)
  end

  def wait_for_workspace_ownership(state, _issue_id, _identifier, _owner, _wait), do: state

  defp workspace_wait_context(state, issue_id) do
    %{running: Map.get(state.running, issue_id), retry: Map.get(state.retry_attempts, issue_id, %{})}
  end

  defp demonitor_workspace_runner(%{ref: ref}) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp demonitor_workspace_runner(_running), do: :ok

  defp install_workspace_wait(state, issue_id, identifier, owner, context) do
    workspace_ownership = state.dispatch_recovery.workspace_ownership
    envelope = workspace_wait_envelope(issue_id, identifier, owner, context)
    workspace_ownership = %{workspace_ownership | waits: Map.put(workspace_ownership.waits, identifier, envelope)}

    state
    |> cancel_pending_retry(issue_id)
    |> Map.put(:running, Map.delete(state.running, issue_id))
    |> Map.put(:claimed, MapSet.put(state.claimed, issue_id))
    |> Map.put(:completed, MapSet.delete(state.completed, issue_id))
    |> put_in([Access.key(:dispatch_recovery), Access.key(:workspace_ownership)], workspace_ownership)
  end

  # A contention report can arrive after the runner's :DOWN. Retain the whole
  # redispatch envelope from either source so a wakeup does not drop the SSH
  # host, retry attempt, tracker identity, or prior-work status.
  defp workspace_wait_envelope(issue_id, identifier, owner, %{running: running, retry: retry}) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      owner: owner,
      worker_host: value_from(running, retry, :worker_host),
      retry_attempt: Map.get(running || %{}, :retry_attempt) || Map.get(retry, :attempt),
      prior_work: value_from(running, retry, :prior_work) == true,
      workspace_path: value_from(running, retry, :workspace_path),
      tracker_identity: value_from(running, retry, :tracker_identity)
    }
  end

  defp value_from(running, retry, key), do: Map.get(running || %{}, key) || Map.get(retry, key)

  # The runner's initial subscription can release before its contention notice
  # reaches the orchestrator. Subscribe again only after the row exists, then
  # store the acknowledged guardian generation that is allowed to release it.
  defp synchronize_workspace_wait(state, identifier, :available), do: release_workspace_wait(state, identifier)

  defp synchronize_workspace_wait(state, identifier, _wait) do
    case Ownership.wait_for_release(identifier, self()) do
      :available -> release_workspace_wait(state, identifier)
      {:waiting, guardian, generation} -> bind_workspace_wait(state, identifier, guardian, generation)
    end
  end

  defp bind_workspace_wait(state, identifier, guardian, generation) do
    update_in(state.dispatch_recovery.workspace_ownership.waits, fn waits ->
      Map.update(waits, identifier, nil, &Map.merge(&1, %{guardian: guardian, generation: generation}))
    end)
  end

  defp cancel_pending_retry(state, issue_id) do
    case Map.pop(state.retry_attempts, issue_id) do
      {nil, _retry_attempts} ->
        %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}

      {%{timer_ref: timer_ref}, retry_attempts} when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)
        %{state | retry_attempts: retry_attempts}

      {_retry, retry_attempts} ->
        %{state | retry_attempts: retry_attempts}
    end
  end

  @doc false
  @spec release_workspace_wait(State.t(), String.t()) :: State.t()
  def release_workspace_wait(%State{} = state, identifier) when is_binary(identifier) do
    workspace_ownership = state.dispatch_recovery.workspace_ownership

    case Map.pop(workspace_ownership.waits, identifier) do
      {nil, _workspace_waits} ->
        state

      {%{issue_id: issue_id} = envelope, workspace_waits} ->
        workspace_ownership = %{
          workspace_ownership
          | waits: workspace_waits,
            ready: Map.put(workspace_ownership.ready, issue_id, envelope)
        }

        %{
          state
          | claimed: MapSet.delete(state.claimed, issue_id),
            dispatch_recovery: %{state.dispatch_recovery | workspace_ownership: workspace_ownership}
        }
    end
  end

  @doc false
  @spec release_workspace_wait(State.t(), String.t(), pid(), pos_integer()) :: State.t()
  def release_workspace_wait(%State{} = state, identifier, guardian, generation)
      when is_binary(identifier) and is_pid(guardian) and is_integer(generation) and generation > 0 do
    waits = state.dispatch_recovery.workspace_ownership.waits

    case Map.get(waits, identifier) do
      %{guardian: ^guardian, generation: ^generation} -> release_workspace_wait(state, identifier)
      _ -> state
    end
  end

  @spec prior_work_for_retry?(map(), boolean()) :: boolean()
  def prior_work_for_retry?(running_entry, continuation_enabled? \\ Config.agent_prior_work_continuation?())
      when is_map(running_entry) and is_boolean(continuation_enabled?) do
    continuation_enabled? and
      (Map.get(running_entry, :prior_work, false) == true or
         positive_turn_count?(Map.get(running_entry, :completed_turn_count)))
  end

  defp positive_turn_count?(turn_count), do: is_integer(turn_count) and turn_count > 0

  @doc false
  @spec preserve_running_issue_on_external_error(State.t(), Issue.t()) :: State.t()
  def preserve_running_issue_on_external_error(%State{} = state, %Issue{} = issue) do
    previous_state =
      case Map.get(state.running, issue.id) do
        %{issue: %Issue{state: state_name}} -> DispatchPolicy.normalize_issue_state(state_name)
        %{issue: %{state: state_name}} -> DispatchPolicy.normalize_issue_state(state_name)
        _ -> ""
      end

    if previous_state == "error" do
      Logger.debug("Issue remains in error state while agent is still active: #{State.issue_context(issue)}")
    else
      Logger.warning("Issue reported error state while agent is still active; preserving runner pending local completion: #{State.issue_context(issue)} state=#{issue.state}")
    end

    Reconciler.refresh_running_issue_state(state, issue)
  end

  @spec complete_issue(State.t(), String.t()) :: State.t()
  def complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  @spec schedule_issue_retry(State.t(), String.t(), integer() | nil, map()) :: State.t()
  def schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    transient_reason = pick_retry_transient_reason(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    tracker_identity = pick_retry_tracker_identity(previous_retry, metadata)
    priority = pick_retry_priority(previous_retry, metadata)
    issue_state = pick_retry_issue_state(previous_retry, metadata)
    prior_work? = pick_retry_prior_work(previous_retry, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_poll_failures = pick_retry_poll_failures(previous_retry, metadata)

    if failure_retry?(metadata) and next_attempt > Config.max_retry_attempts() do
      if is_reference(old_timer), do: Process.cancel_timer(old_timer)

      error_suffix = if is_binary(error), do: " error=#{error}", else: ""
      failed_attempts = max(next_attempt - 1, Map.get(previous_retry, :attempt, 0))

      Logger.warning("Giving up on issue_id=#{issue_id} issue_identifier=#{identifier} after #{failed_attempts} failed attempt(s); max_retry_attempts=#{Config.max_retry_attempts()}#{error_suffix}")

      alert_message = retry_exhausted_alert_message(error)

      Alerts.emit_custom("ticket.#{identifier}.agent.retry_exhausted", alert_message,
        issue: identifier,
        reason: alert_message,
        needs_attention: true,
        severity: "warning"
      )

      error_alert_emitted? = move_exhausted_issue_to_error_state(issue_id, identifier, error) == :alert_emitted

      # Release the claim so a later label-driven re-dispatch (Executor moves the
      # ticket from `error` back to an active state) is picked up without a full
      # daemon restart (#699). The crash path pops `running` but deliberately
      # holds the claim across retries; on give-up that hold must end, otherwise
      # the issue lingers in `claimed` and `dispatch_candidate?/4` refuses it for
      # the daemon's lifetime. Mirrors the retry-poll exhaustion path, which
      # already releases the claim.
      #
      # The `move_exhausted_issue_to_error_state/2` above is best-effort: if that
      # tracker write fails the issue keeps its active-state label, so releasing
      # the claim leaves it eligible for an immediate re-dispatch with a fresh
      # retry budget. That re-dispatch thrash is the class the per-issue
      # `check_thrash_budget/3` breaker exists to bound (it trips with a
      # needs_attention `thrash_circuit_open` alert), and a recovered tracker
      # write parks the ticket in `error` on the next give-up — keeping the
      # ticket recoverable without a restart rather than stranding it in
      # `claimed`, which is the behaviour #699 is fixing.
      #
      # When the exhaustion cause is a transient infrastructure fault (tracker
      # 403 / rate limit / provider timeout), also schedule a bounded automatic
      # re-dispatch so the ticket recovers once the cause clears instead of
      # parking until an operator notices (#1453). The structured transient
      # reason wins when recorded; otherwise the formatted error string is the
      # fallback (which `AutoResume.classify/1` treats as terminal).
      exhaustion_reason = effective_exhaustion_reason(transient_reason, error)

      released =
        state
        |> release_issue_claim(issue_id)
        |> record_claim_release(issue_id, exhaustion_reason)

      released =
        maybe_schedule_transient_auto_resume(
          released,
          issue_id,
          exhaustion_reason
        )

      emit_claim_released_alert(released, issue_id, identifier, failed_attempts, exhaustion_reason, %{worker_host: worker_host})

      released
      |> Map.put(:retry_attempts, Map.delete(released.retry_attempts, issue_id))
      |> maybe_mark_observed_error_alert(issue_id, error_alert_emitted?)
    else
      delay_ms = retry_delay(next_attempt, metadata)
      retry_token = make_ref()
      due_at_ms = System.monotonic_time(:millisecond) + delay_ms

      if is_reference(old_timer), do: Process.cancel_timer(old_timer)

      timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

      error_suffix = if is_binary(error), do: " error=#{error}", else: ""

      log_scheduled_retry(
        issue_id,
        identifier,
        delay_ms,
        next_attempt,
        retry_poll_failures,
        metadata,
        error_suffix
      )

      %{
        state
        | retry_attempts:
            Map.put(state.retry_attempts, issue_id, %{
              attempt: next_attempt,
              timer_ref: timer_ref,
              retry_token: retry_token,
              due_at_ms: due_at_ms,
              identifier: identifier,
              error: error,
              transient_reason: transient_reason,
              retry_poll_failures: retry_poll_failures,
              prior_work: prior_work?,
              worker_host: worker_host,
              workspace_path: workspace_path,
              tracker_identity: tracker_identity,
              priority: priority,
              issue_state: issue_state,
              terminal_membership_pending?: metadata[:terminal_membership_pending?] == true,
              # Persisted so the non-consuming classification is observable and
              # asserted directly: a `:local_budget_hold` retry is bounded by
              # the hold's own `reset_at` and never advances toward give-up
              # (#2429 rework round 2). `pop_retry_attempt_state/3` deliberately
              # does not round-trip it — the retry path reclassifies the failure
              # it sees at dispatch time rather than trusting stale metadata.
              delay_type: metadata[:delay_type],
              local_budget_hold: metadata[:local_budget_hold]
            })
      }
    end
  end

  @spec failure_retry?(map()) :: boolean()
  def failure_retry?(metadata) when is_map(metadata) do
    Map.get(metadata, :delay_type) not in [
      :continuation,
      :capacity_wait,
      :model_limit_wait,
      :local_budget_hold,
      :precondition,
      :terminal_verification
    ]
  end

  @spec pop_retry_attempt_state(State.t(), String.t(), reference()) ::
          {:ok, integer(), map(), State.t()} | :missing
  def pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
      when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          transient_reason: Map.get(retry_entry, :transient_reason),
          retry_poll_failures: Map.get(retry_entry, :retry_poll_failures),
          prior_work: Map.get(retry_entry, :prior_work, false),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          tracker_identity: Map.get(retry_entry, :tracker_identity),
          priority: Map.get(retry_entry, :priority),
          issue_state: Map.get(retry_entry, :issue_state),
          terminal_membership_pending?: Map.get(retry_entry, :terminal_membership_pending?, false)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  @spec handle_retry_issue(State.t(), String.t(), integer(), map(), keyword()) :: {:noreply, State.t()}
  def handle_retry_issue(%State{} = state, issue_id, attempt, metadata, opts \\ []) do
    if retry_capacity_available?(state, metadata) do
      ensure_tracker_preflight = Keyword.get(opts, :ensure_tracker_preflight_fun, &Orchestrator.ensure_tracker_preflight/1)

      case ensure_tracker_preflight.(state) do
        {:ok, state} ->
          handle_retry_tracker_poll(state, issue_id, attempt, metadata, opts)

        {:error, reason, state} ->
          formatted = format_retry_preflight_error(reason)

          Logger.warning("Retry poll skipped for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{formatted}")

          # Pass the structured reason (not the formatted string) so retry-poll
          # exhaustion can classify a transient tracker fault for the #1453
          # automatic re-dispatch.
          {:noreply, handle_retry_poll_failure(state, issue_id, attempt, metadata, reason)}
      end
    else
      Logger.debug("No available slots for retrying issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}; retrying again")

      {:noreply, schedule_capacity_retry(state, issue_id, attempt, metadata)}
    end
  end

  defp retry_capacity_available?(%State{} = state, metadata) when is_map(metadata) do
    Slots.available_slots(state) > 0 and
      Slots.worker_slots_available?(state, metadata[:worker_host]) and
      retry_state_capacity_available?(state, metadata[:issue_state])
  end

  defp retry_state_capacity_available?(%State{} = state, issue_state) when is_binary(issue_state) do
    DispatchPolicy.state_slots_available?(%Issue{state: issue_state}, state)
  end

  defp retry_state_capacity_available?(%State{}, _issue_state), do: true

  defp handle_retry_tracker_poll(state, issue_id, attempt, metadata, opts) do
    fetch_candidate_issues = Keyword.get(opts, :fetch_candidate_issues_fun, &Tracker.fetch_candidate_issues/0)
    fetch_issue_states_by_ids = Keyword.get(opts, :fetch_issue_states_by_ids_fun, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, issues} <- fetch_candidate_issues.(),
         {:ok, issue} <- fetch_retry_issue(issues, issue_id, fetch_issue_states_by_ids) do
      handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata, opts)
    else
      {:error, reason} ->
        {:noreply, handle_retry_poll_failure(state, issue_id, attempt, metadata, reason)}
    end
  end

  defp schedule_capacity_retry(state, issue_id, attempt, metadata) do
    schedule_issue_retry(
      state,
      issue_id,
      attempt,
      Map.merge(metadata, %{
        error: "no available orchestrator slots",
        delay_type: :capacity_wait
      })
    )
  end

  @spec release_issue_claim(State.t(), String.t()) :: State.t()
  def release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  @doc false
  @spec record_claim_release(State.t(), String.t(), term()) :: State.t()
  def record_claim_release(%State{} = state, issue_id, reason) when is_binary(issue_id) do
    {cause, details} = claim_release_reason(reason)

    release = %{
      cause: cause,
      details: details,
      released_at_ms: System.monotonic_time(:millisecond)
    }

    %{state | released_claims: Map.put(state.released_claims || %{}, issue_id, release)}
  end

  @doc false
  @spec fetch_retry_issue(
          [term()],
          String.t(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()})
        ) :: {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_retry_issue(candidate_issues, issue_id, fetch_issue_states_by_ids_fun)
      when is_list(candidate_issues) and is_binary(issue_id) and is_function(fetch_issue_states_by_ids_fun, 1) do
    case find_issue_by_id(candidate_issues, issue_id) do
      %Issue{} = issue ->
        {:ok, issue}

      nil ->
        case fetch_issue_states_by_ids_fun.([issue_id]) do
          {:ok, issues} when is_list(issues) -> {:ok, find_issue_by_id(issues, issue_id)}
          {:error, reason} -> {:error, reason}
          result -> {:error, {:invalid_retry_issue_lookup, result}}
        end
    end
  end

  @spec retry_delay(integer(), map()) :: non_neg_integer()
  def retry_delay(attempt, %{delay_type: :continuation})
      when is_integer(attempt) and attempt == 1 do
    @continuation_retry_delay_ms
  end

  def retry_delay(_attempt, %{delay_type: :capacity_wait}) do
    @continuation_retry_delay_ms
  end

  def retry_delay(_attempt, %{delay_type: :model_limit_wait}) do
    max(Config.poll_interval_seconds() * 1_000, 10_000)
  end

  def retry_delay(_attempt, %{delay_type: :local_budget_hold, local_budget_hold: hold}) do
    reset_delay = local_budget_reset_delay(hold)
    min(max(reset_delay, 1_000), Config.settings!().agent.max_retry_backoff_ms)
  end

  def retry_delay(_attempt, %{
        delay_type: :precondition,
        retry_poll_failures: retry_poll_failures
      }) do
    retry_poll_failures
    |> normalize_retry_poll_failures()
    |> max(1)
    |> failure_retry_delay()
  end

  def retry_delay(attempt, metadata)
      when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    failure_retry_delay(attempt)
  end

  @spec failure_retry_delay(integer()) :: non_neg_integer()
  def failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  @spec normalize_retry_attempt(integer() | term()) :: non_neg_integer()
  def normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  def normalize_retry_attempt(_attempt), do: 0

  @spec next_retry_attempt_from_running(map()) :: pos_integer() | nil
  def next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  # On genuine retry exhaustion, surface the ticket in an Executor-visible
  # state instead of silently leaving it in `rework` with no live agent (#699).
  # `error` ("agent hit an error") is a valid state in neither the active nor
  # the terminal set, so it does not get auto-redispatched. Best-effort: a
  # failed tracker write must not crash the orchestrator.
  defp move_exhausted_issue_to_error_state(issue_id, identifier, error) when is_binary(identifier) do
    Logger.warning("Moving exhausted issue to error state: issue_id=#{issue_id} issue_identifier=#{identifier} reason=retry_exhausted caller=Aiur.Orchestrator.move_exhausted_issue_to_error_state")

    case Tracker.update_issue_state(identifier, "error") do
      :ok ->
        message =
          "Agent entered error after retry exhaustion; automatic retry is no longer scheduled." <>
            retry_exhausted_error_suffix(error)

        Alerts.emit_custom("ticket.#{identifier}.agent.attention.error-retry_exhausted", message,
          issue: identifier,
          reason: message,
          needs_attention: true,
          severity: "warning",
          # Must reach the central feed: IssueSync rediscovers the persisted
          # error cause from there after a restart.
          central: true
        )

        :alert_emitted

      {:error, reason} ->
        Logger.warning("Failed moving exhausted issue identifier=#{identifier} to error state: #{inspect(reason)}")

        :ok
    end
  end

  defp move_exhausted_issue_to_error_state(_issue_id, _identifier, _error), do: :ok

  defp maybe_mark_observed_error_alert(state, issue_id, true) do
    %{
      state
      | observed_error_alerts: MapSet.put(state.observed_error_alerts, issue_id),
        observed_error_alert_causes: Map.put(state.observed_error_alert_causes, issue_id, :retry_exhausted)
    }
  end

  defp maybe_mark_observed_error_alert(state, _issue_id, false), do: state

  defp retry_exhausted_error_suffix(error) when is_binary(error) and error != "", do: " Last error: #{error}"
  defp retry_exhausted_error_suffix(_error), do: ""

  defp log_scheduled_retry(
         issue_id,
         identifier,
         delay_ms,
         attempt,
         retry_poll_failures,
         metadata,
         error_suffix
       ) do
    case Map.get(metadata, :delay_type) do
      :continuation ->
        Logger.warning("Scheduling continuation retry issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{attempt})#{error_suffix}")

      :capacity_wait ->
        Logger.warning("Retrying capacity precondition issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (agent_attempt #{attempt})#{error_suffix}")

      :local_budget_hold ->
        Logger.warning("Retrying local GitHub budget hold issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (agent_attempt #{attempt})#{error_suffix}")

      :precondition ->
        Logger.warning(
          "Retrying retry-poll precondition issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (agent_attempt #{attempt}, retry_poll_failure #{retry_poll_failures}/#{@max_retry_poll_failures})#{error_suffix}"
        )

      _ ->
        Logger.warning("Retrying agent failure issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{attempt})#{error_suffix}")
    end
  end

  @doc false
  @spec format_retry_preflight_error(term()) :: String.t()
  def format_retry_preflight_error({:github_auth_preflight_failed, _diagnostic} = reason),
    do: GitHubClient.format_auth_preflight_error(reason)

  def format_retry_preflight_error(reason), do: inspect(reason)

  # Schedules a bounded automatic re-dispatch when an exhaustion cause is a
  # classifiably transient infrastructure fault (#1453). Returns `state`
  # unchanged for terminal causes, operator pauses, or when the latch is
  # disabled/irrelevant — the ticket parks for normal (operator) recovery.
  @doc false
  @spec maybe_schedule_transient_auto_resume(State.t(), String.t(), term()) :: State.t()
  def maybe_schedule_transient_auto_resume(%State{} = state, issue_id, reason)
      when is_binary(issue_id) do
    case AutoResume.classify(reason) do
      nil ->
        state

      cause ->
        Logger.info("Scheduling transient auto-resume issue_id=#{issue_id} cause=#{cause} reason=#{inspect(reason)}")

        AutoResume.schedule(state, issue_id, cause, recovery_delay_options(reason))
    end
  end

  @doc false
  @spec handle_retry_poll_failure(State.t(), String.t(), integer(), map(), term()) :: State.t()
  # A tracker poll failure can be a local GitHub budget hold in several shapes:
  # raw `{:aiur, :locally_held, hold}`, the `:local_hold` classification
  # `{:github, :local_hold, %{hold: hold}}` (#2429), the legacy
  # `{:github, :transport, %{reason: ...}}` wrapper old classifier versions
  # produced, the `{:github_auth_preflight_failed, %{classification:
  # :local_hold}}` diagnostic `ensure_tracker_preflight` surfaces when the
  # preflight probe itself is held, and any of those wrapped in
  # `{:workspace_github_connectivity_failed, workspace, inner}`. All must take
  # the non-consuming `:local_budget_hold` retry instead of counting against
  # the retry budget meant for genuine agent failures (#2409, #2339).
  # `local_budget_hold_reason/1` is the single extraction shared with agent-exit
  # retry metadata, so a seconds-long hold can never exhaust a budget or stamp
  # `agent:error` (#2429).
  def handle_retry_poll_failure(%State{} = state, issue_id, attempt, metadata, reason) do
    case local_budget_hold_reason(reason) do
      %{} = hold ->
        defer_retry_poll_for_budget_hold(state, issue_id, attempt, metadata, hold, reason)

      nil ->
        handle_generic_retry_poll_failure(state, issue_id, attempt, metadata, reason)
    end
  end

  defp handle_generic_retry_poll_failure(%State{} = state, issue_id, attempt, metadata, reason) do
    identifier = metadata[:identifier] || issue_id
    retry_poll_failures = normalize_retry_poll_failures(metadata[:retry_poll_failures]) + 1

    Logger.warning(
      "Retry poll failed for issue_id=#{issue_id} issue_identifier=#{identifier} retry_poll_failure=#{retry_poll_failures}/#{@max_retry_poll_failures} agent_attempt=#{attempt} tracker_error=#{inspect(reason)}"
    )

    if retry_poll_failures >= @max_retry_poll_failures and not metadata[:terminal_membership_pending?] do
      # A transient tracker failure (403 / rate limit / provider timeout) that
      # exhausted retry polling schedules a bounded automatic re-dispatch once
      # the cause clears, instead of parking until an operator notices (#1453).
      released =
        state
        |> release_issue_claim(issue_id)
        |> record_claim_release(issue_id, reason)
        |> maybe_schedule_transient_auto_resume(issue_id, reason)

      emit_claim_released_alert(released, issue_id, identifier, attempt, reason, metadata)
      released
    else
      schedule_issue_retry(
        state,
        issue_id,
        attempt,
        Map.merge(metadata, %{
          delay_type: :precondition,
          error: "retry poll failed: #{inspect(reason)}",
          retry_poll_failures: retry_poll_failures,
          terminal_membership_pending?: metadata[:terminal_membership_pending?] == true
        })
      )
    end
  end

  defp defer_retry_poll_for_budget_hold(state, issue_id, attempt, metadata, hold, reason) do
    identifier = metadata[:identifier] || issue_id

    Logger.warning(
      "Retry poll deferred by local GitHub budget for issue_id=#{issue_id} issue_identifier=#{identifier} " <>
        "agent_attempt=#{attempt} hold=#{inspect(hold)}"
    )

    schedule_issue_retry(
      state,
      issue_id,
      attempt,
      Map.merge(metadata, %{
        delay_type: :local_budget_hold,
        local_budget_hold: hold,
        error: "retry poll locally held: #{inspect(reason)}",
        retry_poll_failures: normalize_retry_poll_failures(metadata[:retry_poll_failures])
      })
    )
  end

  # Unwraps a local GitHub budget hold from every shape it can arrive in, so
  # `recovery_delay_options/1` can name the hold's own release time for the
  # automatic resume and agent-exit retry scheduling can route it to the
  # non-consuming `:local_budget_hold` retry (#2409, #2429):
  #
  #   * raw `{:aiur, :locally_held, hold}`
  #   * the `:local_hold` classification `Errors.classify_error` now assigns
  #     (`{:github, :local_hold, %{hold: hold}}`)
  #   * the legacy transport-classified `{:github, :transport, %{reason: ...}}`
  #     wrapper older classifier versions produced
  #   * a workspace preflight failure `{:workspace_github_connectivity_failed,
  #     workspace, inner}` — the shape an agent exits with when its workspace
  #     preflight is held (#2339)
  #   * the preflight diagnostic `{:github_auth_preflight_failed,
  #     %{classification: :local_hold, detail: ...}}` that `ensure_preflight/1`
  #     surfaces when the held request is the preflight probe itself.
  defp local_budget_hold_reason({:aiur, :locally_held, hold}) when is_map(hold), do: hold
  defp local_budget_hold_reason({:github, :local_hold, %{hold: hold}}) when is_map(hold), do: hold

  defp local_budget_hold_reason({:github, :local_hold, %{reason: {:aiur, :locally_held, hold}}}) when is_map(hold),
    do: hold

  defp local_budget_hold_reason({:github, :transport, %{reason: {:aiur, :locally_held, hold}}}) when is_map(hold), do: hold

  defp local_budget_hold_reason({:workspace_github_connectivity_failed, _workspace, inner}),
    do: local_budget_hold_reason(inner)

  defp local_budget_hold_reason({:github_auth_preflight_failed, %{classification: :local_hold} = diagnostic}),
    do: local_budget_hold_reason(Map.get(diagnostic, :detail))

  defp local_budget_hold_reason(%{hold: hold}) when is_map(hold), do: hold
  defp local_budget_hold_reason(%{reason: {:aiur, :locally_held, hold}}) when is_map(hold), do: hold
  defp local_budget_hold_reason(_reason), do: nil

  defp local_budget_reset_delay(hold) do
    case Map.get(hold, :reset_at) || Map.get(hold, "reset_at") do
      %DateTime{} = reset_at -> max(DateTime.diff(reset_at, DateTime.utc_now(), :millisecond), 1_000)
      _missing -> max(Config.poll_interval_seconds() * 1_000, 10_000)
    end
  end

  defp emit_claim_released_alert(state, issue_id, identifier, attempt, reason, metadata) do
    {reason_code, details} = claim_release_reason(reason)
    auto_reclaim = Map.get(state.auto_resume, issue_id)
    recovery = claim_recovery_message(auto_reclaim)

    message =
      "Released claim for ticket=#{identifier} agent=#{metadata[:worker_host] || identifier} after #{@max_retry_poll_failures} tracker failures " <>
        "(reason=#{reason_code}, credential=#{credential_identity()}#{claim_release_detail_suffix(details)}). #{recovery}"

    Logger.error(
      "Claim released for issue_id=#{issue_id} issue_identifier=#{identifier} agent_attempt=#{attempt} " <>
        "max_retry_poll_failures=#{@max_retry_poll_failures} reason=#{reason_code} tracker_error=#{inspect(reason)}"
    )

    Alerts.emit_custom(
      "orchestrator.claim_released",
      message,
      issue: identifier,
      worker_host: metadata[:worker_host],
      reason: message,
      needs_attention: true,
      severity: "warning"
    )
  end

  defp claim_release_reason({:github, :rate_limited, details}) when is_map(details), do: {:rate_limit_exhausted, details}
  defp claim_release_reason(_reason), do: {:tracker_retry_exhausted, %{}}

  defp recovery_delay_options({:github, :rate_limited, details}) when is_map(details) do
    [retry_after: details[:retry_after], reset_at: details[:reset_at]]
  end

  # A local budget hold names its own release time (`reset_at`); the automatic
  # resume should not fire before it, or it would re-dispatch straight back into
  # the same hold. Handles the raw `{:aiur, :locally_held, hold}` and the
  # `:local_hold` / legacy transport-classified `{:github, ...}` forms (#2409,
  # #2429).
  defp recovery_delay_options(reason) do
    case local_budget_hold_reason(reason) do
      %{reset_at: %DateTime{} = reset_at} ->
        [reset_at: DateTime.to_iso8601(reset_at)]

      _other ->
        []
    end
  end

  # Identify the credential that actually made the rate-limited request, not the
  # one the operator configured. `GitHubConfig.bot_account/0` is a config string:
  # under a GitHub App installation token it names a different principal than the
  # token in use, and naming the wrong principal on a security-adjacent alert is
  # worse than naming none. A fingerprint of the token that was actually used is
  # verifiable; when there is no token, say `unknown`.
  #
  # The verified login (`Aiur.GitHub.BotIdentity.fetch_authenticated_viewer_login/2`)
  # is deliberately not used here: it costs a live GitHub API call, and this code
  # path runs precisely when GitHub has stopped answering (#1475).
  defp credential_identity do
    case GitHubConfig.token() do
      token when is_binary(token) and byte_size(token) > 0 ->
        "token-sha256:" <> (:crypto.hash(:sha256, token) |> Base.encode16(case: :lower) |> binary_part(0, 12))

      _ ->
        "unknown"
    end
  end

  defp claim_release_detail_suffix(details) do
    [:remaining, :reset_at, :retry_after]
    |> Enum.flat_map(fn key ->
      case Map.get(details, key) do
        nil -> []
        value -> [", #{key}=#{value}"]
      end
    end)
    |> Enum.join()
  end

  defp claim_recovery_message(%{cause: :rate_limit, attempt: attempt}) do
    "Automatic re-claim is scheduled after rate-limit recovery (attempt #{attempt}/#{AutoResume.max_attempts()})."
  end

  defp claim_recovery_message(%{cause: :local_budget_hold, attempt: attempt}) do
    "Automatic re-claim is scheduled after the local GitHub budget hold lifts (attempt #{attempt}/#{AutoResume.max_attempts()})."
  end

  defp claim_recovery_message(%{cause: cause, attempt: attempt}) do
    "Automatic re-claim is scheduled after #{cause} recovery (attempt #{attempt}/#{AutoResume.max_attempts()})."
  end

  defp claim_recovery_message(_auto_reclaim), do: "Automatic re-claim is not scheduled; operator recovery is required."

  @doc false
  @spec handle_retry_issue_lookup(
          Issue.t() | nil,
          State.t(),
          String.t(),
          integer(),
          map(),
          keyword()
        ) ::
          {:noreply, State.t()}
  def handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata, opts \\ [])

  def handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata, opts) do
    terminal_states = Keyword.get(opts, :terminal_states, DispatchPolicy.terminal_state_set())

    terminal_retry_funs = terminal_retry_funs(opts)

    cond do
      DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) ->
        handle_terminal_retry_issue(
          state,
          issue,
          issue_id,
          attempt,
          metadata,
          terminal_retry_funs
        )

      Orchestrator.retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata, opts)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  def handle_retry_issue_lookup(nil, state, issue_id, attempt, metadata, _opts) do
    if metadata[:terminal_membership_pending?] do
      Logger.warning(
        "Terminal membership is still pending for unavailable retry issue_id=#{issue_id}; " <>
          "retaining claim"
      )

      {:noreply,
       schedule_issue_retry(
         state,
         issue_id,
         attempt,
         Map.merge(metadata, %{
           delay_type: :terminal_verification,
           error: "terminal membership verification could not refetch issue",
           terminal_membership_pending?: true
         })
       )}
    else
      Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
      {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_terminal_retry_issue(
         state,
         issue,
         issue_id,
         attempt,
         metadata,
         terminal_retry_funs
       ) do
    Logger.info(
      "Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} " <>
        "state=#{issue.state}; removing associated workspace"
    )

    case MembershipLifecycle.record(
           issue,
           MembershipLifecycle.terminal_lifecycle(issue.state),
           terminal_retry_funs.observe_membership
         ) do
      :ok ->
        finish_terminal_retry_issue(
          state,
          issue,
          issue_id,
          attempt,
          metadata,
          terminal_retry_funs.cleanup_terminal_issue_artifacts,
          terminal_retry_funs.set_terminal_verification_pending
        )

      {:error, :membership_observation_failed} ->
        retain_terminal_retry_claim(
          state,
          issue,
          issue_id,
          attempt,
          metadata,
          terminal_retry_funs.mark_reconciled,
          terminal_retry_funs.set_terminal_verification_pending
        )
    end
  end

  defp terminal_retry_funs(opts) do
    %{
      observe_membership: Keyword.get(opts, :observe_membership_fun, &MembershipLifecycle.observe/2),
      cleanup_terminal_issue_artifacts:
        Keyword.get(
          opts,
          :cleanup_terminal_issue_artifacts_fun,
          &Orchestrator.cleanup_terminal_issue_artifacts/2
        ),
      mark_reconciled: Keyword.get(opts, :mark_reconciled_fun, &CurrentRunMembership.mark_reconciled/1),
      set_terminal_verification_pending:
        Keyword.get(
          opts,
          :set_terminal_verification_pending_fun,
          &CurrentRunMembership.set_terminal_verification_pending/2
        )
    }
  end

  defp finish_terminal_retry_issue(
         state,
         issue,
         issue_id,
         attempt,
         metadata,
         cleanup_terminal_issue_artifacts_fun,
         set_terminal_verification_pending_fun
       ) do
    case safely_set_terminal_verification_pending(
           set_terminal_verification_pending_fun,
           issue.tracker_identity,
           false
         ) do
      :ok ->
        cleanup_terminal_issue_artifacts_fun.(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      :error ->
        {:noreply, schedule_terminal_verification_retry(state, issue, issue_id, attempt, metadata)}
    end
  end

  defp retain_terminal_retry_claim(
         state,
         issue,
         issue_id,
         attempt,
         metadata,
         mark_reconciled_fun,
         set_terminal_verification_pending_fun
       ) do
    safely_mark_membership_unavailable(
      mark_reconciled_fun,
      set_terminal_verification_pending_fun,
      issue.tracker_identity
    )

    {:noreply, schedule_terminal_verification_retry(state, issue, issue_id, attempt, metadata)}
  end

  defp handle_active_retry(state, issue, attempt, metadata, opts) do
    if Orchestrator.retry_candidate_issue?(issue, DispatchPolicy.terminal_state_set()) and
         Slots.dispatch_slots_available?(issue, state) and
         Slots.worker_slots_available?(state, metadata[:worker_host]) do
      dispatch = Keyword.get(opts, :dispatch_fun, &Dispatcher.dispatch_issue/5)
      prior_work? = Keyword.get(opts, :prior_work?, metadata[:prior_work] == true)

      next_state =
        dispatch.(state, issue, attempt, metadata[:worker_host], prior_work: prior_work?)

      {:noreply, ensure_active_retry_started(next_state, issue, attempt, metadata, opts)}
    else
      Logger.debug("No available slots for retrying #{State.issue_context(issue)}; retrying again")

      capacity_metadata =
        Map.merge(metadata, %{
          identifier: issue.identifier,
          tracker_identity: Issue.tracker_identity(issue),
          priority: issue.priority,
          issue_state: issue.state
        })

      {:noreply, schedule_capacity_retry(state, issue.id, attempt, capacity_metadata)}
    end
  end

  defp ensure_active_retry_started(state, issue, attempt, metadata, opts) do
    if live_running_entry?(Map.get(state.running, issue.id)) or
         Map.has_key?(state.retry_attempts, issue.id) do
      state
    else
      schedule_retry = Keyword.get(opts, :schedule_retry_fun, &schedule_issue_retry/4)

      delay_type =
        if MapSet.member?(state.model_fallback_waiting, issue.id),
          do: :model_limit_wait,
          else: :capacity_wait

      schedule_retry.(state, issue.id, attempt, %{
        identifier: issue.identifier,
        tracker_identity: Issue.tracker_identity(issue),
        error: "retry dispatch did not start",
        delay_type: delay_type,
        prior_work: metadata[:prior_work] == true,
        worker_host: metadata[:worker_host],
        workspace_path: metadata[:workspace_path]
      })
    end
  end

  defp live_running_entry?(%{pid: pid}) when is_pid(pid), do: true
  defp live_running_entry?(_entry), do: false

  defp schedule_terminal_verification_retry(state, issue, issue_id, attempt, metadata) do
    schedule_issue_retry(
      state,
      issue_id,
      attempt,
      Map.merge(metadata, %{
        identifier: issue.identifier,
        tracker_identity: Issue.tracker_identity(issue),
        error: "terminal membership persistence failed",
        delay_type: :terminal_verification,
        terminal_membership_pending?: true
      })
    )
  end

  defp safely_mark_membership_unavailable(mark_reconciled_fun, set_terminal_verification_pending_fun, identity) do
    _ = safely_set_terminal_verification_pending(set_terminal_verification_pending_fun, identity, true)
    _ = mark_reconciled_fun.(:unavailable)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safely_set_terminal_verification_pending(set_terminal_verification_pending_fun, identity, pending?) do
    if match?(%TrackerIdentity{}, identity) and TrackerIdentity.joinable?(identity) do
      case set_terminal_verification_pending_fun.(identity, pending?) do
        :ok -> :ok
        _ -> :error
      end
    else
      :ok
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp normalize_retry_poll_failures(failures) when is_integer(failures) and failures > 0,
    do: failures

  defp normalize_retry_poll_failures(_failures), do: 0

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  # The structured (non-formatted) failure reason, retained so retry exhaustion
  # can classify a transient infrastructure fault for the #1453 auto-resume.
  defp pick_retry_transient_reason(previous_retry, metadata) do
    if Map.has_key?(metadata, :transient_reason) do
      Map.get(metadata, :transient_reason)
    else
      Map.get(previous_retry, :transient_reason)
    end
  end

  # The cause passed to `AutoResume.classify/1` at retry exhaustion: the
  # structured transient reason when one was recorded, else the formatted error
  # string (which classifies as terminal, so an infra fault with no structured
  # record still parks for operator recovery rather than auto-resuming on an
  # unclassifiable cause).
  defp effective_exhaustion_reason(nil, error), do: error
  defp effective_exhaustion_reason(transient_reason, _error), do: transient_reason

  # The generic "retry budget exhausted" alert text alone forces the operator
  # to grep the daemon log to find the actual failure (e.g. a workspace
  # provisioning error); fold the last recorded error into the operator-facing
  # message so it is visible without leaving the alert.
  defp retry_exhausted_alert_message(error) when is_binary(error) do
    "Agent retry attempts were exhausted; the ticket needs Executor review. Last error: #{error}"
  end

  defp retry_exhausted_alert_message(_error) do
    "Agent retry attempts were exhausted; the ticket needs Executor review."
  end

  defp pick_retry_poll_failures(previous_retry, metadata) do
    metadata
    |> Map.get(:retry_poll_failures, Map.get(previous_retry, :retry_poll_failures))
    |> normalize_retry_poll_failures()
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_tracker_identity(previous_retry, metadata) do
    if Map.has_key?(metadata, :tracker_identity) do
      Map.get(metadata, :tracker_identity)
    else
      Map.get(previous_retry, :tracker_identity)
    end
  end

  defp pick_retry_priority(previous_retry, metadata) do
    if Map.has_key?(metadata, :priority) do
      Map.get(metadata, :priority)
    else
      Map.get(previous_retry, :priority)
    end
  end

  defp pick_retry_issue_state(previous_retry, metadata) do
    if Map.has_key?(metadata, :issue_state) do
      Map.get(metadata, :issue_state)
    else
      Map.get(previous_retry, :issue_state)
    end
  end

  defp pick_retry_prior_work(previous_retry, metadata) do
    Map.get(metadata, :prior_work, Map.get(previous_retry, :prior_work, false)) == true
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end
end
