defmodule Aiur.Orchestrator do
  @moduledoc "Polls the issue tracker and dispatches repository copies to agent-backed workers."
  use GenServer
  require Logger

  alias Aiur.{Alerts, Issue}
  alias Aiur.Orchestrator.{AutoSubscriptions, BlockerPropagation, CiLifecycle, CommentPollingState, CommentWake, DispatchCycleLiveness, StaleApprovedHead, TicketTransition}
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, EventTopics, HumanReview, Interrupts}
  alias Aiur.Orchestrator.{Lifecycle, PauseResume, PushRouting, RetryEngine}
  alias Aiur.Orchestrator.{ReadyForReviewTransitions, RuntimeWatchdog, Slots, State, StatusReport}
  alias Aiur.Orchestrator.{TokenAccounting, TrackedSet, TrackerHealth, TrackerTasks, WorkspaceCleanup}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts), do: Lifecycle.init(opts, &issue_tracked?/1)

  @doc false
  @spec has_live_owner?(String.t()) :: boolean() | :unknown
  def has_live_owner?(identifier), do: StatusReport.has_live_owner_api(__MODULE__, identifier, 1_000)

  @impl true
  def terminate(reason, state), do: Lifecycle.terminate(reason, state)

  # The Aiur.Events publish boundary reads ETS here; a GenServer call back into this process would deadlock.
  @doc false
  @spec issue_tracked?(String.t() | integer() | nil) :: boolean()
  def issue_tracked?(nil), do: false

  def issue_tracked?(issue_number) do
    TrackedSet.member?(issue_number)
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) and state.poll_frozen != true,
      do: Lifecycle.handle_tick(state)

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state), do: if(Map.get(state, :poll_frozen), do: {:noreply, state}, else: Lifecycle.handle_tick(state))
  def handle_info({:dispatch_cycle_liveness_check, token}, state), do: DispatchCycleLiveness.handle_check(state, token)
  def handle_info(:propagate_blocker_tick, state), do: {:noreply, BlockerPropagation.flush(state)}
  # Freeze scheduled polls during tests to keep live polling from changing the load envelope.
  def handle_info(:run_poll_cycle, %State{poll_frozen: true} = state), do: {:noreply, state}
  def handle_info(:run_poll_cycle, %State{} = state), do: Dispatcher.run_poll_cycle(state)

  def handle_info({:github_webhook_reconcile, %{kind: :review_thread} = hint}, %State{} = state),
    do: {:noreply, CommentPollingState.request_reconcile(state, hint)}

  def handle_info({:github_pr_synchronize, ticket, pr_number}, %State{} = state)
      when is_binary(ticket) and is_integer(pr_number) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> StaleApprovedHead.reconcile(ticket, pr_number) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> StaleApprovedHead.task_start_failed(ticket, pr_number, reason)
    end

    {:noreply, state}
  end

  def handle_info({:github_pr_ready_transition, t, n, sha}, state), do: {:noreply, ReadyForReviewTransitions.observe_webhook_transition(state, t, n, sha)}

  def handle_info({:ci_readiness_result, token, result}, state) when is_reference(token) do
    state = Dispatcher.handle_ci_readiness_result(state, token, result)
    StatusReport.notify_dashboard(state)
    {:noreply, state}
  end

  def handle_info({:ci_readiness_timeout, token}, state) when is_reference(token) do
    state = Dispatcher.handle_ci_readiness_timeout(state, token)
    StatusReport.notify_dashboard(state)
    {:noreply, state}
  end

  def handle_info({:prewarm_phase, {:error, {:repo_base_dispatch_hold_stalled, _phase}} = stalled}, state) do
    {:noreply, Dispatcher.clear_prewarm_blocked_alert(state, stalled)}
  end

  def handle_info({:prewarm_phase, _phase}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case TrackerTasks.down(state, ref, reason) do
      {:handled, next_state} -> {:noreply, next_state}
      :unhandled -> handle_other_down(state, ref, reason)
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case TrackerTasks.result(state, ref, result) do
      {:handled, next_state} -> {:noreply, next_state}
      :unhandled -> {:noreply, state}
    end
  end

  def handle_info({:tracker_task_timeout, ref}, state),
    do: {:noreply, TrackerTasks.timeout(state, ref)}

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, state)
      when is_binary(issue_id) and is_map(runtime_info),
      do: State.handle_worker_runtime_info(state, issue_id, runtime_info)

  # Only runners surviving provisioning bill one lifetime dispatch unit (#1453); preflight failures do not.
  def handle_info({:dispatch_committed, issue_id}, state) when is_binary(issue_id) do
    state = state |> Dispatcher.record_dispatch_committed(issue_id) |> RetryEngine.clear_budget_hold_streak(issue_id)
    {:noreply, state}
  end

  def handle_info({:live_conversation_restarted, projection_epoch, observed_at}, state) do
    State.handle_live_conversation_restart(state, projection_epoch, observed_at)
  end

  def handle_info({:workspace_setup_contended, issue_id, identifier, owner, wait}, state)
      when is_binary(issue_id) and is_binary(identifier) do
    state = RetryEngine.wait_for_workspace_ownership(state, issue_id, identifier, owner, wait)
    StatusReport.notify_dashboard(state)
    {:noreply, state}
  end

  def handle_info({:workspace_ownership_available, identifier, guardian, generation}, state)
      when is_binary(identifier) and is_pid(guardian) and is_integer(generation) and generation > 0 do
    state = RetryEngine.release_workspace_wait(state, identifier, guardian, generation)
    {:noreply, Lifecycle.wake_tick(state)}
  end

  # A waiter without a guardian retries availability; any new owner makes
  # redispatch contend and subscribe again.
  def handle_info({:workspace_ownership_available, identifier, :none, nil}, state) when is_binary(identifier) do
    state = RetryEngine.release_workspace_wait(state, identifier)
    {:noreply, Lifecycle.wake_tick(state)}
  end

  # A pre-generation waiter cannot release a current guardian-bound wait row.
  def handle_info({:workspace_ownership_available, _identifier}, state), do: {:noreply, state}

  def handle_info({:repl_session_runtime, issue_id, info}, state)
      when is_binary(issue_id) and is_map(info),
      do: State.handle_repl_session_runtime(state, issue_id, info)

  def handle_info({:session_execution_info, issue_id, %{backend: backend} = info}, state)
      when is_binary(issue_id) and is_binary(backend),
      do: State.handle_session_execution_info(state, issue_id, info)

  def handle_info({:session_resolved_model, issue_id, model}, state)
      when is_binary(issue_id) and is_binary(model),
      do: State.handle_session_resolved_model(state, issue_id, model)

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        state
      ),
      do: TokenAccounting.handle_codex_worker_update(state, issue_id, update)

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:emit_system_alert, alert_name, %Issue{} = issue, worker_host}, state)
      when is_binary(alert_name) do
    Alerts.emit_system(alert_name, issue: issue, worker_host: worker_host)
    {:noreply, state}
  end

  def handle_info({:emit_system_alert, alert_name, issue_identifier, worker_host}, state)
      when is_binary(alert_name) and is_binary(issue_identifier) do
    Alerts.emit_system(alert_name, issue: issue_identifier, worker_host: worker_host)
    {:noreply, state}
  end

  def handle_info({:worker_control_state, issue_id, status}, state)
      when is_binary(issue_id) and status in [:completed, :paused, :working] do
    PauseResume.handle_worker_control_state(state, issue_id, status, %{})
  end

  def handle_info({:worker_control_state, issue_id, status, control_payload}, state)
      when is_binary(issue_id) and status in [:completed, :paused, :working] and is_map(control_payload) do
    PauseResume.handle_worker_control_state(state, issue_id, status, control_payload)
  end

  def handle_info({:worker_control_rejected, issue_id, request_id, generation, class}, state)
      when is_binary(issue_id) and is_integer(request_id) and request_id > 0 and is_integer(generation) and
             generation >= 0 and is_atom(class) do
    PauseResume.handle_worker_control_rejected(state, issue_id, request_id, generation, class)
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state),
    do: RetryEngine.handle_retry_message(state, issue_id, retry_token)

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:ci_wait_rewake, issue_id, token}, state)
      when is_binary(issue_id) and is_reference(token) do
    {:noreply, CiLifecycle.handle_ci_wait_rewake(state, issue_id, token)}
  end

  def handle_info({:retry_comment_rework, issue_number, source, event, attempt}, state)
      when is_integer(attempt) do
    # The tracked timer has now fired; drop its ref before the attempt runs so a
    # rescheduled retry replaces it rather than being cancelled as "superseded".
    state = CommentWake.forget_comment_rework_retry(state, issue_number, source)

    {:noreply, CommentWake.maybe_reactivate_on_comment(state, issue_number, source, event, attempt)}
  end

  def handle_info({:event, %{topic: topic} = event}, state) when is_binary(topic) do
    {:noreply, EventTopics.route(state, event)}
  end

  def handle_info({:github_listener_outcome, :comments, outcome}, state),
    do: {:noreply, CommentPollingState.apply_outcome(state, outcome)}

  # Quota observations arrive outside the tracker poll. A recovered window must
  # invalidate the persisted admission verdict immediately; otherwise `status`
  # can keep reporting the historical hold until some unrelated poll succeeds.
  def handle_info(:github_quota_recovered, state) do
    state = PushRouting.recover_github_budget_pauses(state)
    {:reply, _result, state} = Lifecycle.request_refresh(state)
    {:noreply, state}
  end

  def handle_info({:github_budget_pause_expired, identifier, generation}, state)
      when is_binary(identifier) and is_integer(generation) and generation > 0 do
    # The per-agent expiry path must also request a poll refresh. A fleet whose
    # agents are all budget-paused has active_running_count == 0 and is
    # classified idle under #2160, so without the refresh its poll backs off
    # and the capacity-deferred pending_auto_resume hint is never drained.
    state = PushRouting.recover_github_budget_pause(state, identifier, generation)
    {:reply, _result, state} = Lifecycle.request_refresh(state)
    {:noreply, state}
  end

  def handle_info({:deliver_pending_answers, _identifier, _store} = message, state) do
    :ok = Dispatcher.handle_pending_answer_delivery(message)
    {:noreply, state}
  end

  # A closed ticket's workspace save and delete finished in its task (#2743).
  # The task already logged and alerted anything that needs an operator.
  def handle_info({:workspace_cleanup_finished, workspace_identifier, result}, state) do
    Logger.debug("Terminal workspace cleanup finished workspace=#{workspace_identifier} result=#{inspect(result)}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_other_down(state, ref, reason) do
    RetryEngine.handle_agent_down(state, ref, reason)
  end

  @doc false
  @spec github_next_poll_delay_ms(State.t()) :: non_neg_integer() | nil
  def github_next_poll_delay_ms(state), do: TrackerHealth.github_next_poll_delay_ms(state)

  @doc false
  @spec ensure_tracker_preflight(State.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def ensure_tracker_preflight(state), do: TrackerHealth.ensure_tracker_preflight(state)

  @doc false
  @spec log_tracker_preflight_error(term()) :: :ok
  def log_tracker_preflight_error(reason), do: TrackerHealth.log_tracker_preflight_error(reason)

  @doc false
  @spec log_tracker_fetch_error(term()) :: :ok
  def log_tracker_fetch_error(reason), do: TrackerHealth.log_tracker_fetch_error(reason)

  @doc false
  @spec read_load(number() | nil) :: float() | :unavailable
  defdelegate read_load(threshold), to: DispatchPolicy

  @doc false
  @spec read_load(number() | nil, number() | nil) :: float() | :unavailable
  defdelegate read_load(hard_threshold, target), to: DispatchPolicy

  @doc false
  @spec read_cpu(number() | nil) :: Aiur.SystemCpu.snapshot() | :unavailable
  defdelegate read_cpu(target), to: DispatchPolicy

  @doc false
  @spec read_memory(integer() | nil) :: non_neg_integer() | :unavailable
  defdelegate read_memory(threshold), to: DispatchPolicy

  @doc false
  @spec prewarm_gate(boolean(), atom() | {:error, term()}) :: :dispatch | :hold
  defdelegate prewarm_gate(enabled?, phase), to: DispatchPolicy

  @doc false
  @spec load_gate(number() | :unavailable, number() | nil, pos_integer()) :: :dispatch | :hold
  defdelegate load_gate(load, threshold, schedulers), to: DispatchPolicy

  @doc false
  @spec memory_gate(non_neg_integer() | :unavailable, integer() | nil) :: :dispatch | :hold
  defdelegate memory_gate(available_mb, threshold), to: DispatchPolicy

  @spec fd_gate(Aiur.SystemFileDescriptors.sample_result()) :: :dispatch | :hold
  defdelegate fd_gate(sample), to: DispatchPolicy

  @spec fd_headroom_threshold(map()) :: pos_integer() | :unavailable
  defdelegate fd_headroom_threshold(sample), to: DispatchPolicy

  @doc false
  @spec load_envelope(integer() | nil, integer() | nil, number() | :unavailable, map()) ::
          {pos_integer(), integer() | nil}
  defdelegate load_envelope(effective, last_decrease_ms, load, options), to: DispatchPolicy

  @doc false
  @spec slot_status_for_test(State.t()) :: %{active: non_neg_integer(), paused: non_neg_integer()}
  def slot_status_for_test(%State{} = state), do: Slots.slot_status(state)

  @spec apply_overrun_check_for_test(State.t(), non_neg_integer()) :: State.t()
  def apply_overrun_check_for_test(%State{} = state, max_seconds)
      when is_integer(max_seconds) and max_seconds >= 0,
      do: RuntimeWatchdog.apply_overrun_check(state, max_seconds)

  @spec resume_paused_issue_for_test(State.t(), map(), boolean()) :: {term(), State.t()}
  def resume_paused_issue_for_test(%State{} = state, running_entry, operator? \\ true)
      when is_map(running_entry) and is_boolean(operator?),
      do: PauseResume.resume_paused_issue(state, running_entry, operator?)

  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state),
    do: DispatchPolicy.should_dispatch_issue?(issue, state)

  @spec dispatch_candidate_for_test(Issue.t(), term()) :: boolean()
  def dispatch_candidate_for_test(%Issue{} = issue, %State{} = state),
    do: DispatchPolicy.dispatch_candidate?(issue, state)

  @spec retry_dispatch_ready_for_test(Issue.t(), State.t(), String.t() | nil) :: boolean()
  def retry_dispatch_ready_for_test(%Issue{} = issue, %State{} = state, worker_host \\ nil),
    do: Dispatcher.retry_dispatch_ready?(issue, state, worker_host)

  @spec ci_wait_state?(binary() | term()) :: boolean()
  def ci_wait_state?(state_name), do: CiLifecycle.ci_wait_state?(state_name)
  @spec error_issue_state?(binary() | term()) :: boolean()
  def error_issue_state?(state_name) when is_binary(state_name),
    do: DispatchPolicy.normalize_issue_state(state_name) == "error"

  def error_issue_state?(_state_name), do: false

  @spec pause_issue_for_label_override(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_label_override(%State{} = state, %Issue{} = issue),
    do: PauseResume.pause_issue_for_label_override(state, issue)

  @spec cleanup_terminal_issue_artifacts(binary() | term(), binary() | nil) :: :ok
  def cleanup_terminal_issue_artifacts(identifier, worker_host \\ nil),
    do: WorkspaceCleanup.cleanup_terminal_issue_artifacts(identifier, worker_host)

  @spec human_review_state?(term()) :: boolean()
  def human_review_state?(state_name), do: HumanReview.human_review_state?(state_name)

  @spec overrunning_entry?(map(), DateTime.t(), non_neg_integer()) :: boolean()
  def overrunning_entry?(entry, now, max_seconds),
    do: RuntimeWatchdog.overrunning_entry?(entry, now, max_seconds)

  @type poll_status :: %{
          checking?: boolean(),
          next_poll_in_ms: integer() | nil,
          effective_interval_ms: integer() | nil,
          idle_backoff: %{active?: boolean(), factor: float()} | nil
        }

  defdelegate request_refresh(), to: Aiur.Orchestrator.Client
  defdelegate request_refresh(server), to: Aiur.Orchestrator.Client
  defdelegate note_queued_demand(identifiers), to: Aiur.Orchestrator.Client
  defdelegate note_queued_demand(server, identifiers), to: Aiur.Orchestrator.Client
  defdelegate send_operator_message(identifier, payload), to: Aiur.Orchestrator.Client
  defdelegate send_operator_message(server, identifier, payload), to: Aiur.Orchestrator.Client
  defdelegate send_correlated_operator_message(identifier, payload), to: Aiur.Orchestrator.Client
  defdelegate send_correlated_operator_message(server, identifier, payload), to: Aiur.Orchestrator.Client
  defdelegate pause_agent(identifier), to: Aiur.Orchestrator.Client
  defdelegate pause_agent(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate request_control(identifier, action, request_id), to: Aiur.Orchestrator.Client
  defdelegate request_control(server, identifier, action, request_id), to: Aiur.Orchestrator.Client
  defdelegate mark_sleeping(identifier), to: Aiur.Orchestrator.Client
  defdelegate mark_sleeping(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate interrupt_agent(identifier), to: Aiur.Orchestrator.Client
  defdelegate interrupt_agent(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate pane_interrupt(identifier), to: Aiur.Orchestrator.Client
  defdelegate pane_interrupt(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate pane_interrupt_by_pane_id(pane_id), to: Aiur.Orchestrator.Client
  defdelegate pane_interrupt_by_pane_id(server, pane_id), to: Aiur.Orchestrator.Client
  defdelegate resume_agent(identifier), to: Aiur.Orchestrator.Client
  defdelegate resume_agent(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate resume_agent_with_receipt(identifier), to: Aiur.Orchestrator.Client
  defdelegate resume_agent_with_receipt(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate prioritize_agent(identifier), to: Aiur.Orchestrator.Client
  defdelegate prioritize_agent(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate deprioritize_agent(identifier), to: Aiur.Orchestrator.Client
  defdelegate deprioritize_agent(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate control_lifecycle(identifier), to: Aiur.Orchestrator.Client
  defdelegate control_lifecycle(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate reset_dispatch_budget(identifier), to: Aiur.Orchestrator.Client
  defdelegate reset_dispatch_budget(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate max_concurrent_agents(), to: Aiur.Orchestrator.Client
  defdelegate max_concurrent_agents(server), to: Aiur.Orchestrator.Client
  defdelegate adjust_max_concurrent_agents(delta), to: Aiur.Orchestrator.Client
  defdelegate adjust_max_concurrent_agents(server, delta), to: Aiur.Orchestrator.Client
  defdelegate set_max_concurrent_agents(next), to: Aiur.Orchestrator.Client
  defdelegate set_max_concurrent_agents(server, next), to: Aiur.Orchestrator.Client
  defdelegate globally_paused?(), to: Aiur.Orchestrator.Client
  defdelegate global_pause_status(), to: Aiur.Orchestrator.Client
  defdelegate global_pause_status(server, timeout_ms), to: Aiur.Orchestrator.Client
  defdelegate set_global_pause(on?), to: Aiur.Orchestrator.Client
  defdelegate set_global_pause(on?, source), to: Aiur.Orchestrator.Client
  defdelegate control_capabilities(identifier), to: Aiur.Orchestrator.Client
  defdelegate control_capabilities(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate set_remote_control(identifier, on?), to: Aiur.Orchestrator.Client
  defdelegate set_remote_control(server, identifier, on?), to: Aiur.Orchestrator.Client
  defdelegate ensure_remote_control_trust(workspace), to: Aiur.Orchestrator.Client
  defdelegate ensure_remote_control_trust(server, workspace), to: Aiur.Orchestrator.Client
  defdelegate operator_message_status(server \\ Aiur.Orchestrator, item_id, timeout \\ 5_000), to: Aiur.Orchestrator.Client
  defdelegate claim_next_queue_item(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate claim_next_checkpoint_queue_item(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate claim_blocker_critical_events_digest(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate claim_next_operator_queue_item(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate claim_operator_response(server, identifier, command), to: Aiur.Orchestrator.Client
  defdelegate mark_queue_item_consumed(server, item_id), to: Aiur.Orchestrator.Client
  defdelegate restore_queue_item_pending(server, item_id), to: Aiur.Orchestrator.Client
  defdelegate mark_queue_item_failed(server, item_id, reason), to: Aiur.Orchestrator.Client
  defdelegate acknowledge_queue_item_delivery(server, item_id, provider_metadata), to: Aiur.Orchestrator.Client
  defdelegate consume_delivered_queue_items(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate restore_delivered_queue_items(server, identifier), to: Aiur.Orchestrator.Client
  defdelegate fail_delivered_queue_items(server, identifier, reason), to: Aiur.Orchestrator.Client
  defdelegate snapshot(), to: Aiur.Orchestrator.Client
  defdelegate list_active_identifiers(server \\ Aiur.Orchestrator, timeout \\ 1_000), to: Aiur.Orchestrator.Client
  defdelegate list_running_active_identifiers(server \\ Aiur.Orchestrator, timeout \\ 1_000), to: Aiur.Orchestrator.Client
  defdelegate poll_status(), to: Aiur.Orchestrator.Client
  defdelegate poll_status(server, timeout), to: Aiur.Orchestrator.Client
  defdelegate status(), to: Aiur.Orchestrator.Client
  defdelegate status(server, timeout), to: Aiur.Orchestrator.Client
  defdelegate status_with_capacity(server, timeout), to: Aiur.Orchestrator.Client
  defdelegate snapshot(server, timeout), to: Aiur.Orchestrator.Client
  defdelegate dashboard_snapshot(server \\ Aiur.Orchestrator, timeout \\ 15_000), to: Aiur.Orchestrator.Client
  defdelegate fleet_view(server \\ Aiur.Orchestrator, timeout, opts \\ []), to: Aiur.Orchestrator.Client

  @impl true
  defdelegate handle_call(message, from, state), to: Aiur.Orchestrator.Calls

  @doc false
  @spec resume_label_overridden_issue(State.t(), map()) :: {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_label_overridden_issue(%State{} = state, running_entry),
    do: PauseResume.resume_label_overridden_issue(state, running_entry)

  @doc false
  @spec send_pause_control_message(State.t(), String.t()) :: term()
  def send_pause_control_message(state, issue_identifier), do: PauseResume.send_pause_control_message(state, issue_identifier)
  @spec pane_interrupt_action(boolean(), non_neg_integer()) :: :close_pane | :interrupt | :pause
  def pane_interrupt_action(paused?, queue_depth) when is_boolean(paused?) and is_integer(queue_depth),
    do: Interrupts.pane_interrupt_action(paused?, queue_depth)

  @spec pane_interrupt_action_no_pane(boolean(), boolean()) :: :send_interrupt | :close_pane | :pause
  def pane_interrupt_action_no_pane(paused?, working?) when is_boolean(paused?) and is_boolean(working?),
    do: Interrupts.pane_interrupt_action_no_pane(paused?, working?)

  @doc "Refresh an agent's liveness timestamp on claude-hook activity (fire-and-forget)."
  @spec note_agent_activity(GenServer.server(), String.t()) :: :ok
  def note_agent_activity(server \\ __MODULE__, identifier) when is_binary(identifier) do
    GenServer.cast(server, {:note_agent_activity, identifier})
  end

  @doc false
  @spec note_agent_activity_state(State.t(), String.t()) :: State.t()
  def note_agent_activity_state(%State{} = state, identifier) when is_binary(identifier),
    do: State.note_agent_activity(state, identifier)

  @impl true
  def handle_cast({:note_agent_activity, identifier}, state) do
    {:noreply, note_agent_activity_state(state, identifier)}
  end

  @impl true
  def handle_cast({:mark_sleeping, identifier}, state) when is_binary(identifier) do
    {next, effects} = PushRouting.sleeping_effects(state, identifier)
    {:noreply, TicketTransition.apply_effects(next, effects)}
  end

  @doc false
  @spec retry_candidate_issue?(Issue.t(), MapSet.t()) :: boolean()
  defdelegate retry_candidate_issue?(issue, terminal_states), to: DispatchPolicy

  @spec subscribe_for_declared_blocker(String.t() | integer(), String.t() | integer()) :: :ok | {:error, term()}
  def subscribe_for_declared_blocker(blockee_identifier, blocker_identifier),
    do: AutoSubscriptions.subscribe_for_declared_blocker(blockee_identifier, blocker_identifier)

  @spec unsubscribe_for_declared_blocker(String.t() | integer(), String.t() | integer()) :: :ok
  def unsubscribe_for_declared_blocker(blockee_identifier, blocker_identifier),
    do: AutoSubscriptions.unsubscribe_for_declared_blocker(blockee_identifier, blocker_identifier)
end
