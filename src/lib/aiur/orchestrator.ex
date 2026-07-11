defmodule Aiur.Orchestrator do
  @moduledoc "Polls the issue tracker and dispatches repository copies to agent-backed workers."

  use GenServer
  require Logger

  alias Aiur.{AgentQueueItem, AgentQueueStore, Alerts, Issue}
  alias Aiur.Orchestrator.{AgentTeardown, AutoSubscriptions, CiLifecycle, CommandScan, CommentPolling, CommentWake}
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, EventTopics, HumanReview, Interrupts, IssueSync}
  alias Aiur.Orchestrator.{Lifecycle, PauseResume, PrAnchored, PushRouting, Reconciler, RetryEngine}
  alias Aiur.Orchestrator.{RuntimeWatchdog, Slots, State, StatusReport}
  alias Aiur.Orchestrator.{TokenAccounting, TrackedSet, TrackerHealth, WorkspaceCleanup}

  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.RemoteControlMode, as: RC
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts), do: Lifecycle.init(opts, &issue_tracked?/1)

  @impl true
  def terminate(reason, state), do: Lifecycle.terminate(reason, state)

  # Publisher reads ETS here; a GenServer call back into this process would deadlock.
  @doc false
  @spec issue_tracked?(String.t() | integer() | nil) :: boolean()
  def issue_tracked?(nil), do: false

  def issue_tracked?(issue_number) do
    TrackedSet.member?(issue_number)
  end

  @doc false
  @spec refresh_tracked_set(State.t()) :: State.t()
  def refresh_tracked_set(state), do: TrackedSet.refresh(state)

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token),
      do: Lifecycle.handle_tick(state)

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state), do: Lifecycle.handle_tick(state)

  def handle_info(:run_poll_cycle, state), do: Dispatcher.run_poll_cycle(state)

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    RetryEngine.handle_agent_down(state, ref, reason)
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, state)
      when is_binary(issue_id) and is_map(runtime_info),
      do: State.handle_worker_runtime_info(state, issue_id, runtime_info)

  def handle_info({:repl_session_runtime, issue_id, info}, state)
      when is_binary(issue_id) and is_map(info),
      do: State.handle_repl_session_runtime(state, issue_id, info)

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
      when is_binary(issue_id) and status in [:paused, :working] do
    PauseResume.handle_worker_control_state(state, issue_id, status, %{})
  end

  def handle_info({:worker_control_state, issue_id, :paused, pause_payload}, state)
      when is_binary(issue_id) and is_map(pause_payload) do
    PauseResume.handle_worker_control_state(state, issue_id, :paused, pause_payload)
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state),
    do: RetryEngine.handle_retry_message(state, issue_id, retry_token)

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:retry_comment_rework, issue_number, source, event, attempt}, state)
      when is_integer(attempt) do
    {:noreply, CommentWake.maybe_reactivate_on_comment(state, issue_number, source, event, attempt)}
  end

  def handle_info({:event, %{topic: topic} = event}, state) when is_binary(topic) do
    {:noreply, EventTopics.route(state, event)}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  @doc false
  @spec transition_control_status(State.t(), map(), atom(), String.t()) :: State.t()
  def transition_control_status(state, running_entry, new_status, reason),
    do: PauseResume.transition_control_status(state, running_entry, new_status, reason)

  @doc false
  @spec note_github_connectivity_success(State.t(), atom()) :: State.t()
  def note_github_connectivity_success(state, source),
    do: TrackerHealth.note_github_connectivity_success(state, source)

  @doc false
  @spec note_github_connectivity_failure(State.t(), atom(), term()) :: State.t()
  def note_github_connectivity_failure(state, source, reason),
    do: TrackerHealth.note_github_connectivity_failure(state, source, reason)

  @doc false
  @spec connectivity_detail(term()) :: map()
  def connectivity_detail({:github, _classification, detail}) when is_map(detail), do: detail

  def connectivity_detail({:github_api_status, status}) when is_integer(status),
    do: %{status: status}

  def connectivity_detail(_reason), do: %{}

  @doc false
  @spec note_github_poll_interval(State.t(), atom(), pos_integer() | nil) :: State.t()
  def note_github_poll_interval(state, source, seconds),
    do: TrackerHealth.note_github_poll_interval(state, source, seconds)

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
  @spec prewarm_gate(boolean(), atom() | {:error, term()}) :: :dispatch | :hold
  defdelegate prewarm_gate(enabled?, phase), to: DispatchPolicy

  @doc false
  @spec load_gate(number() | :unavailable, number() | nil, pos_integer()) :: :dispatch | :hold
  defdelegate load_gate(load, threshold, schedulers), to: DispatchPolicy

  @doc false
  @spec load_envelope(integer() | nil, integer() | nil, number() | :unavailable, map()) ::
          {pos_integer(), integer() | nil}
  defdelegate load_envelope(effective, last_decrease_ms, load, options), to: DispatchPolicy

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues),
    do: Reconciler.reconcile_running_issue_states(issues, state)

  def reconcile_issue_states_for_test(issues, state) when is_list(issues),
    do:
      Reconciler.reconcile_running_issue_states(
        issues,
        state,
        DispatchPolicy.active_state_set(),
        DispatchPolicy.terminal_state_set()
      )

  @spec run_terminal_workspace_cleanup_for_test(State.t()) :: State.t()
  def run_terminal_workspace_cleanup_for_test(%State{} = state),
    do: WorkspaceCleanup.run_terminal_workspace_cleanup(state)

  @spec run_startup_todo_workspace_cleanup_for_test(State.t()) :: State.t()
  def run_startup_todo_workspace_cleanup_for_test(%State{} = state),
    do: WorkspaceCleanup.run_startup_todo_workspace_cleanup(state)

  @spec slot_status_for_test(State.t()) :: %{active: non_neg_integer(), paused: non_neg_integer()}
  def slot_status_for_test(%State{} = state), do: Slots.slot_status(state)
  @spec parse_pr_review_comment_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pr_review_comment_topic_for_test(topic) when is_binary(topic),
    do: EventTopics.parse_pr_review_comment_topic(topic)

  @spec parse_issue_commented_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_issue_commented_topic_for_test(topic) when is_binary(topic),
    do: EventTopics.parse_issue_commented_topic(topic)

  @spec parse_ci_failed_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_ci_failed_topic_for_test(topic) when is_binary(topic),
    do: EventTopics.parse_ci_failed_topic(topic)

  @spec poll_github_firehose_for_test(State.t(), keyword()) :: State.t()
  def poll_github_firehose_for_test(%State{} = state, opts) when is_list(opts),
    do: CommentPolling.poll_github_firehose(state, opts)

  @spec poll_github_comments_for_test(State.t(), keyword()) :: State.t()
  def poll_github_comments_for_test(%State{} = state, opts) when is_list(opts),
    do: CommentPolling.poll_github_comments(state, opts)

  @spec poll_github_ci_for_test(State.t(), keyword()) :: State.t()
  def poll_github_ci_for_test(%State{} = state, opts) when is_list(opts),
    do: CiLifecycle.poll_github_ci(state, opts)

  @spec scan_pr_commands_for_test(State.t(), keyword()) :: State.t()
  def scan_pr_commands_for_test(%State{} = state, opts) when is_list(opts),
    do: CommandScan.scan_pr_commands(state, opts)

  @spec maybe_stop_closed_pr_anchored_agents_for_test(State.t(), keyword()) :: State.t()
  def maybe_stop_closed_pr_anchored_agents_for_test(%State{} = state, opts)
      when is_list(opts),
      do: PrAnchored.maybe_stop_closed_pr_anchored_agents(state, opts)

  @spec github_next_poll_delay_for_test(State.t()) :: non_neg_integer() | nil
  def github_next_poll_delay_for_test(%State{} = state),
    do: TrackerHealth.github_next_poll_delay_ms(state)

  @spec parse_pause_request_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pause_request_topic_for_test(topic) when is_binary(topic),
    do: EventTopics.parse_pause_request_topic(topic)

  @spec parse_branch_push_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_branch_push_topic_for_test(topic) when is_binary(topic),
    do: EventTopics.parse_branch_push_topic(topic)

  @spec parse_system_branch_push_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_system_branch_push_topic_for_test(topic) when is_binary(topic),
    do: EventTopics.parse_system_branch_push_topic(topic)

  @spec apply_pause_request_for_test(State.t(), String.t()) :: State.t()
  def apply_pause_request_for_test(%State{} = state, identifier) when is_binary(identifier),
    do: PushRouting.maybe_pause_on_request(state, identifier)

  @spec apply_mark_sleeping_for_test(State.t(), String.t()) :: State.t()
  def apply_mark_sleeping_for_test(%State{} = state, identifier) when is_binary(identifier),
    do: PushRouting.maybe_mark_sleeping(state, identifier)

  @spec apply_branch_push_for_test(State.t(), String.t()) :: State.t()
  def apply_branch_push_for_test(%State{} = state, blocker_identifier)
      when is_binary(blocker_identifier),
      do: PushRouting.apply_branch_push(state, blocker_identifier)

  @spec apply_system_branch_push_for_test(State.t(), String.t(), map()) :: State.t()
  def apply_system_branch_push_for_test(%State{} = state, branch, event \\ %{})
      when is_binary(branch) and is_map(event),
      do: PushRouting.maybe_notify_agents_on_default_branch_push(state, branch, event)

  @spec apply_stall_check_for_test(State.t(), pos_integer()) :: State.t()
  def apply_stall_check_for_test(%State{} = state, timeout_ms) when is_integer(timeout_ms),
    do: RuntimeWatchdog.apply_stall_check(state, timeout_ms)

  @spec apply_overrun_check_for_test(State.t(), non_neg_integer()) :: State.t()
  def apply_overrun_check_for_test(%State{} = state, max_seconds)
      when is_integer(max_seconds) and max_seconds >= 0,
      do: RuntimeWatchdog.apply_overrun_check(state, max_seconds)

  @spec resume_paused_issue_for_test(State.t(), map(), boolean()) :: {term(), State.t()}
  def resume_paused_issue_for_test(%State{} = state, running_entry, operator? \\ true)
      when is_map(running_entry) and is_boolean(operator?),
      do: PauseResume.resume_paused_issue(state, running_entry, operator?)

  @spec apply_thrash_check_for_test(State.t(), String.t(), integer()) ::
          {:ok, State.t()} | {:trip, State.t()}
  def apply_thrash_check_for_test(%State{} = state, issue_id, now_ms)
      when is_binary(issue_id) and is_integer(now_ms),
      do: Dispatcher.check_thrash_budget(state, issue_id, now_ms)

  @spec sync_polled_issue_state_for_test(State.t(), [Issue.t()]) :: State.t()
  def sync_polled_issue_state_for_test(%State{} = state, issues) when is_list(issues),
    do: IssueSync.sync_polled_issue_state(state, issues)

  @spec sync_todo_capacity_alert_for_test(State.t(), [Issue.t()]) :: State.t()
  def sync_todo_capacity_alert_for_test(%State{} = state, issues) when is_list(issues),
    do: IssueSync.sync_todo_capacity_alert(state, issues)

  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state),
    do: DispatchPolicy.should_dispatch_issue?(issue, state)

  @spec dispatch_candidate_for_test(Issue.t(), term()) :: boolean()
  def dispatch_candidate_for_test(%Issue{} = issue, %State{} = state),
    do: DispatchPolicy.dispatch_candidate?(issue, state)

  @spec recover_startup_pause_overrides_for_test(State.t(), [term()]) :: [term()]
  def recover_startup_pause_overrides_for_test(%State{} = state, issues)
      when is_list(issues),
      do: PauseResume.recover_startup_pause_overrides(state, issues)

  @spec retry_dispatch_ready_for_test(Issue.t(), State.t(), String.t() | nil) :: boolean()
  def retry_dispatch_ready_for_test(%Issue{} = issue, %State{} = state, worker_host \\ nil),
    do: Dispatcher.retry_dispatch_ready?(issue, state, worker_host)

  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1),
      do:
        Dispatcher.revalidate_issue_for_dispatch(
          issue,
          issue_fetcher,
          DispatchPolicy.terminal_state_set()
        )

  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues),
    do: DispatchPolicy.sort_issues_for_dispatch(issues)

  @spec select_worker_host_for_test(term(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host),
    do: Slots.select_worker_host(state, preferred_worker_host)

  @spec set_remote_control_for_test(State.t(), String.t(), boolean()) :: {term(), State.t()}
  def set_remote_control_for_test(%State{} = state, identifier, on?)
      when is_binary(identifier) and is_boolean(on?),
      do: RC.set_remote_control_reply(state, identifier, on?)

  @spec reactivate_issue_for_test(State.t(), map()) :: {term(), State.t()}
  def reactivate_issue_for_test(%State{} = state, running_entry) when is_map(running_entry),
    do: PauseResume.reactivate_issue(state, running_entry)

  @spec remote_control_summary_for_test(map()) :: map() | nil
  def remote_control_summary_for_test(entry), do: RC.remote_control_summary(entry)
  @spec terminate_running_issue_for_test(State.t(), String.t(), boolean()) :: State.t()
  def terminate_running_issue_for_test(%State{} = state, issue_id, cleanup_workspace)
      when is_binary(issue_id) and is_boolean(cleanup_workspace),
      do: AgentTeardown.terminate_running_issue(state, issue_id, cleanup_workspace)

  @spec ci_wait_state?(binary() | term()) :: boolean()
  def ci_wait_state?(state_name), do: CiLifecycle.ci_wait_state?(state_name)
  @spec error_issue_state?(binary() | term()) :: boolean()
  def error_issue_state?(state_name) when is_binary(state_name),
    do: DispatchPolicy.normalize_issue_state(state_name) == "error"

  def error_issue_state?(_state_name), do: false
  @spec preserve_running_issue_on_external_error(State.t(), Issue.t()) :: State.t()
  def preserve_running_issue_on_external_error(state, issue),
    do: RetryEngine.preserve_running_issue_on_external_error(state, issue)

  @spec pause_issue_for_label_override(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_label_override(%State{} = state, %Issue{} = issue),
    do: PauseResume.pause_issue_for_label_override(state, issue)

  @spec pause_issue_for_ci_wait(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_ci_wait(state, issue), do: CiLifecycle.pause_issue_for_ci_wait(state, issue)
  @spec reconcile_pending_auto_resumes(State.t()) :: State.t()
  def reconcile_pending_auto_resumes(%State{} = state),
    do: PushRouting.reconcile_pending_auto_resumes(state)

  @spec cleanup_terminal_issue_artifacts(binary() | term(), binary() | nil) :: :ok
  def cleanup_terminal_issue_artifacts(identifier, worker_host \\ nil),
    do: WorkspaceCleanup.cleanup_terminal_issue_artifacts(identifier, worker_host)

  @spec clear_session_handle(binary() | term()) :: :ok
  def clear_session_handle(identifier), do: WorkspaceCleanup.clear_session_handle(identifier)
  @spec human_review_state?(term()) :: boolean()
  def human_review_state?(state_name), do: HumanReview.human_review_state?(state_name)
  @spec maybe_deactivate_human_review_issue(State.t(), Issue.t()) :: State.t()
  def maybe_deactivate_human_review_issue(state, issue),
    do: HumanReview.maybe_deactivate_human_review_issue(state, issue)

  @spec terminate_running_issue(State.t(), String.t(), boolean()) :: State.t()
  def terminate_running_issue(state, issue_id, cleanup_workspace),
    do: AgentTeardown.terminate_running_issue(state, issue_id, cleanup_workspace)

  @spec kill_repl_session(map()) :: :ok
  def kill_repl_session(entry), do: AgentTeardown.kill_repl_session(entry)
  @spec close_active_chat_streams(String.t() | term(), term()) :: :ok
  def close_active_chat_streams(identifier, reason),
    do: AgentTeardown.close_active_chat_streams(identifier, reason)

  @spec terminate_task(term()) :: :ok
  def terminate_task(pid), do: AgentTeardown.terminate_task(pid)
  @spec reconcile_overrunning_agents(State.t()) :: State.t()
  def reconcile_overrunning_agents(state),
    do: RuntimeWatchdog.reconcile_overrunning_agents(state)

  @spec reconcile_stalled_running_issues(State.t()) :: State.t()
  def reconcile_stalled_running_issues(state),
    do: RuntimeWatchdog.reconcile_stalled_running_issues(state)

  @spec overrunning_entry?(map(), DateTime.t(), non_neg_integer()) :: boolean()
  def overrunning_entry?(entry, now, max_seconds),
    do: RuntimeWatchdog.overrunning_entry?(entry, now, max_seconds)

  # Public RPC facade; implementations live with their owning submodules.
  @spec request_refresh() :: map() | :unavailable
  def request_refresh, do: Lifecycle.request_refresh_api()
  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server), do: Lifecycle.request_refresh_api(server)
  @spec send_operator_message(String.t(), map()) :: {:ok, integer()} | {:error, term()}
  def send_operator_message(identifier, payload),
    do: OM.send_operator_message(identifier, payload)

  @spec send_operator_message(GenServer.server(), String.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(server, identifier, payload),
    do: OM.send_operator_message(server, identifier, payload)

  @spec pause_agent(String.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(identifier), do: PauseResume.pause_agent(identifier)
  @spec pause_agent(GenServer.server(), String.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(server, identifier), do: PauseResume.pause_agent(server, identifier)
  @spec mark_sleeping(String.t()) :: :ok
  def mark_sleeping(identifier), do: PushRouting.mark_sleeping(identifier)
  @spec mark_sleeping(GenServer.server(), String.t()) :: :ok
  def mark_sleeping(server, identifier), do: PushRouting.mark_sleeping(server, identifier)
  @spec interrupt_agent(String.t()) :: :ok | {:error, term()}
  def interrupt_agent(identifier), do: Interrupts.interrupt_agent(identifier)
  @spec interrupt_agent(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def interrupt_agent(server, identifier), do: Interrupts.interrupt_agent(server, identifier)

  @spec pane_interrupt(String.t()) ::
          {:ok, :interrupted | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt(identifier), do: Interrupts.pane_interrupt(identifier)

  @spec pane_interrupt(GenServer.server(), String.t()) ::
          {:ok, :interrupted | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt(server, identifier), do: Interrupts.pane_interrupt(server, identifier)

  @spec pane_interrupt_by_pane_id(String.t()) ::
          {:ok, :interrupted | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt_by_pane_id(pane_id), do: Interrupts.pane_interrupt_by_pane_id(pane_id)

  @spec pane_interrupt_by_pane_id(GenServer.server(), String.t()) ::
          {:ok, :interrupted | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt_by_pane_id(server, pane_id),
    do: Interrupts.pane_interrupt_by_pane_id(server, pane_id)

  @spec resume_agent(String.t()) :: {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(identifier), do: PauseResume.resume_agent(identifier)

  @spec resume_agent(GenServer.server(), String.t()) ::
          {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(server, identifier), do: PauseResume.resume_agent(server, identifier)
  @spec max_concurrent_agents() :: map() | :unavailable
  def max_concurrent_agents, do: Slots.max_concurrent_agents()
  @spec max_concurrent_agents(GenServer.server()) :: map() | :unavailable
  def max_concurrent_agents(server), do: Slots.max_concurrent_agents(server)
  @spec adjust_max_concurrent_agents(integer()) :: {:ok, map()} | {:error, term()}
  def adjust_max_concurrent_agents(delta), do: Slots.adjust_max_concurrent_agents(delta)

  @spec adjust_max_concurrent_agents(GenServer.server(), integer()) ::
          {:ok, map()} | {:error, term()}
  def adjust_max_concurrent_agents(server, delta),
    do: Slots.adjust_max_concurrent_agents(server, delta)

  @spec set_max_concurrent_agents(pos_integer()) :: {:ok, map()} | {:error, term()}
  def set_max_concurrent_agents(next), do: Slots.set_max_concurrent_agents(next)

  @spec set_max_concurrent_agents(GenServer.server(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def set_max_concurrent_agents(server, next),
    do: Slots.set_max_concurrent_agents(server, next)

  @spec control_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def control_capabilities(identifier), do: OM.control_capabilities(identifier)
  @spec control_capabilities(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def control_capabilities(server, identifier),
    do: OM.control_capabilities(server, identifier)

  @spec set_remote_control(String.t(), boolean()) :: {:ok, :on | :off} | {:error, term()}
  def set_remote_control(identifier, on?), do: RC.set_remote_control(identifier, on?)

  @spec set_remote_control(GenServer.server(), String.t(), boolean()) ::
          {:ok, :on | :off} | {:error, term()}
  def set_remote_control(server, identifier, on?),
    do: RC.set_remote_control(server, identifier, on?)

  @spec ensure_remote_control_trust(Path.t()) :: :ok | {:error, term()}
  def ensure_remote_control_trust(workspace), do: RC.ensure_remote_control_trust(workspace)
  @spec ensure_remote_control_trust(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def ensure_remote_control_trust(server, workspace),
    do: RC.ensure_remote_control_trust(server, workspace)

  @spec claim_next_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_queue_item(server, identifier),
    do: OM.claim_next_queue_item(server, identifier)

  @spec claim_next_checkpoint_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_checkpoint_queue_item(server, identifier),
    do: OM.claim_next_checkpoint_queue_item(server, identifier)

  @spec claim_blocker_critical_events_digest(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_blocker_critical_events_digest(server, identifier),
    do: OM.claim_blocker_critical_events_digest(server, identifier)

  @spec claim_next_operator_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_operator_queue_item(server, identifier),
    do: OM.claim_next_operator_queue_item(server, identifier)

  @spec claim_next_queue_item_for_test(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_queue_item_for_test(server, identifier),
    do: OM.claim_next_queue_item(server, identifier)

  @spec mark_queue_item_consumed(GenServer.server(), integer()) :: :ok | {:error, term()}
  def mark_queue_item_consumed(server, item_id),
    do: OM.mark_queue_item_consumed(server, item_id)

  @spec restore_queue_item_pending(GenServer.server(), integer()) :: :ok | {:error, term()}
  def restore_queue_item_pending(server, item_id),
    do: OM.restore_queue_item_pending(server, item_id)

  @spec mark_queue_item_consumed_for_test(GenServer.server(), integer()) :: :ok | {:error, term()}
  def mark_queue_item_consumed_for_test(server, item_id),
    do: OM.mark_queue_item_consumed(server, item_id)

  @spec mark_queue_item_failed(GenServer.server(), integer(), term()) :: :ok | {:error, term()}
  def mark_queue_item_failed(server, item_id, reason),
    do: OM.mark_queue_item_failed(server, item_id, reason)

  @spec consume_delivered_queue_items(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def consume_delivered_queue_items(server, identifier),
    do: OM.consume_delivered_queue_items(server, identifier)

  @spec restore_delivered_queue_items(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def restore_delivered_queue_items(server, identifier),
    do: OM.restore_delivered_queue_items(server, identifier)

  @spec fail_delivered_queue_items(GenServer.server(), String.t(), term()) :: :ok | {:error, term()}
  def fail_delivered_queue_items(server, identifier, reason),
    do: OM.fail_delivered_queue_items(server, identifier, reason)

  @spec mark_queue_item_failed_for_test(GenServer.server(), integer(), term()) ::
          :ok | {:error, term()}
  def mark_queue_item_failed_for_test(server, item_id, reason),
    do: OM.mark_queue_item_failed(server, item_id, reason)

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: StatusReport.snapshot_api()
  @spec list_active_identifiers(GenServer.server(), timeout()) :: [String.t()]
  def list_active_identifiers(server \\ __MODULE__, timeout \\ 1_000),
    do: StatusReport.list_active_identifiers_api(server, timeout)

  @spec list_running_active_identifiers(GenServer.server(), timeout()) :: [String.t()]
  def list_running_active_identifiers(server \\ __MODULE__, timeout \\ 1_000),
    do: StatusReport.list_running_active_identifiers_api(server, timeout)

  @spec poll_status() :: %{checking?: boolean(), next_poll_in_ms: integer() | nil} | :unavailable
  def poll_status, do: StatusReport.poll_status_api()

  @spec poll_status(GenServer.server(), timeout()) ::
          %{checking?: boolean(), next_poll_in_ms: integer() | nil} | :unavailable
  def poll_status(server, timeout), do: StatusReport.poll_status_api(server, timeout)
  @spec status() :: [map()] | :timeout | :unavailable
  def status, do: StatusReport.status_api()
  @spec status(GenServer.server(), timeout()) :: [map()] | :timeout | :unavailable
  def status(server, timeout), do: StatusReport.status_api(server, timeout)
  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout), do: StatusReport.snapshot_api(server, timeout)

  @impl true
  def handle_call({:enqueue_event_digest, identifier, event}, _from, state),
    do: OM.enqueue_event_digest_call(state, identifier, event)

  def handle_call({:enqueue_event_digest_batch, identifier, events}, _from, state)
      when is_binary(identifier) and is_list(events),
      do: OM.enqueue_event_digest_batch_call(state, identifier, events)

  def handle_call(:poll_status, _from, state), do: StatusReport.poll_status(state)

  def handle_call(:list_active_identifiers, _from, state),
    do: StatusReport.list_active_identifiers(state)

  def handle_call(:list_running_active_identifiers, _from, state),
    do: StatusReport.list_running_active_identifiers(state)

  def handle_call(:status, _from, state), do: StatusReport.status(state)

  def handle_call(:snapshot, _from, state), do: StatusReport.snapshot(state)

  def handle_call(:request_refresh, _from, state) do
    Lifecycle.request_refresh(state)
  end

  def handle_call({:send_operator_message, issue_identifier, payload}, _from, state),
    do: OM.send_operator_message_call(state, issue_identifier, payload)

  def handle_call({:control_capabilities, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.control_capabilities_call(state, issue_identifier)

  def handle_call({:pause_agent, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: PauseResume.pause_agent_call(state, issue_identifier)

  def handle_call({:pause_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:interrupt_agent, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: Interrupts.interrupt_agent_call(state, issue_identifier)

  def handle_call({:interrupt_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:pane_interrupt, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: Interrupts.pane_interrupt_call(state, issue_identifier)

  def handle_call({:pane_interrupt, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:pane_interrupt_by_pane_id, pane_id}, _from, state)
      when is_binary(pane_id),
      do: Interrupts.pane_interrupt_by_pane_id_call(state, pane_id)

  def handle_call({:resume_agent, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: PauseResume.resume_issue_call(state, issue_identifier)

  def handle_call({:resume_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:set_remote_control, issue_identifier, on?}, _from, state)
      when is_binary(issue_identifier) and is_boolean(on?),
      do: RC.set_remote_control_call(state, issue_identifier, on?)

  def handle_call({:set_remote_control, _issue_identifier, _on?}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:ensure_remote_control_trust, workspace}, _from, state)
      when is_binary(workspace),
      do: RC.ensure_remote_control_trust_call(state, workspace)

  def handle_call(:max_concurrent_agents, _from, state),
    do: Slots.max_concurrent_agents_call(state)

  def handle_call({:adjust_max_concurrent_agents, delta}, _from, state)
      when is_integer(delta),
      do: Slots.adjust_max_concurrent_agents_call(state, delta)

  def handle_call({:set_max_concurrent_agents, n}, _from, state)
      when is_integer(n) and n > 0,
      do: Slots.set_max_concurrent_agents_call(state, n)

  def handle_call({:claim_next_queue_item, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.claim_next_queue_item_call(state, issue_identifier)

  def handle_call({:claim_next_checkpoint_queue_item, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.claim_next_checkpoint_queue_item_call(state, issue_identifier)

  def handle_call({:claim_blocker_critical_events_digest, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.claim_blocker_critical_events_digest_call(state, issue_identifier)

  def handle_call({:claim_next_operator_queue_item, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.claim_next_operator_queue_item_call(state, issue_identifier)

  def handle_call({:mark_queue_item_consumed, item_id}, _from, state)
      when is_integer(item_id),
      do: OM.mark_queue_item_consumed_call(state, item_id)

  def handle_call({:restore_queue_item_pending, item_id}, _from, state)
      when is_integer(item_id),
      do: OM.restore_queue_item_pending_call(state, item_id)

  def handle_call({:mark_queue_item_failed, item_id, reason}, _from, state)
      when is_integer(item_id),
      do: OM.mark_queue_item_failed_call(state, item_id, reason)

  def handle_call({:consume_delivered_queue_items, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.consume_delivered_queue_items_call(state, issue_identifier)

  def handle_call({:restore_delivered_queue_items, issue_identifier}, _from, state)
      when is_binary(issue_identifier),
      do: OM.restore_delivered_queue_items_call(state, issue_identifier)

  def handle_call({:fail_delivered_queue_items, issue_identifier, reason}, _from, state)
      when is_binary(issue_identifier),
      do: OM.fail_delivered_queue_items_call(state, issue_identifier, reason)

  @doc false
  @spec enqueue_event_digest_item(State.t(), String.t(), list(), map()) :: State.t()
  def enqueue_event_digest_item(state, identifier, events, summary_source),
    do: OM.enqueue_event_digest_item(state, identifier, events, summary_source)

  @doc false
  @spec resume_label_overridden_issue(State.t(), map()) :: {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_label_overridden_issue(%State{} = state, running_entry),
    do: PauseResume.resume_label_overridden_issue(state, running_entry)

  @doc false
  @spec reactivate_issue(State.t(), map()) :: {{:ok, :reactivated} | {:error, term()}, State.t()}
  def reactivate_issue(%State{} = state, running_entry), do: PauseResume.reactivate_issue(state, running_entry)
  @doc false
  @spec send_pause_control_message(State.t(), String.t()) :: term()
  def send_pause_control_message(state, issue_identifier), do: PauseResume.send_pause_control_message(state, issue_identifier)
  @spec pane_interrupt_action(boolean(), non_neg_integer()) :: :close_pane | :interrupt | :pause
  def pane_interrupt_action(paused?, queue_depth) when is_boolean(paused?) and is_integer(queue_depth),
    do: Interrupts.pane_interrupt_action(paused?, queue_depth)

  @spec pane_interrupt_action_no_pane(boolean(), boolean()) :: :send_interrupt | :close_pane | :pause
  def pane_interrupt_action_no_pane(paused?, working?) when is_boolean(paused?) and is_boolean(working?),
    do: Interrupts.pane_interrupt_action_no_pane(paused?, working?)

  @doc false
  @spec resume_paused_issue(State.t(), map(), boolean()) :: {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_paused_issue(%State{} = state, running_entry, operator? \\ true),
    do: PauseResume.resume_paused_issue(state, running_entry, operator?)

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
    {:noreply, PushRouting.maybe_mark_sleeping(state, identifier)}
  end

  @doc false
  @spec schedule_poll_cycle_start() :: :ok
  def schedule_poll_cycle_start, do: Lifecycle.schedule_poll_cycle_start()
  @spec running_worker_host(State.t(), binary() | term()) :: binary() | nil
  def running_worker_host(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{worker_host: worker_host} -> worker_host
      _ -> nil
    end
  end

  def running_worker_host(_state, _issue_id), do: nil

  @doc false
  @spec retry_candidate_issue?(Issue.t(), MapSet.t()) :: boolean()
  defdelegate retry_candidate_issue?(issue, terminal_states), to: DispatchPolicy

  @doc false
  @spec coalesce_for_test(AgentQueueStore.t(), String.t()) ::
          {AgentQueueStore.t(), AgentQueueItem.t() | nil}
  def coalesce_for_test(queue_store, issue_identifier) when is_binary(issue_identifier) do
    OM.coalesce_for_test(queue_store, issue_identifier)
  end

  @spec subscribe_for_declared_blocker(String.t() | integer(), String.t() | integer()) :: :ok
  def subscribe_for_declared_blocker(blockee_identifier, blocker_identifier),
    do: AutoSubscriptions.subscribe_for_declared_blocker(blockee_identifier, blocker_identifier)
end
