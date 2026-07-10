defmodule Aiur.Orchestrator do
  @moduledoc """
  Polls the issue tracker and dispatches repository copies to agent-backed workers.
  """

  use GenServer
  require Logger

  alias Aiur.{
    AgentEvents,
    AgentPubSub,
    AgentQueueItem,
    AgentQueueStore,
    Alerts,
    CIApprovalStore,
    CodingAgent,
    Config,
    Issue,
    RepoBase,
    SessionHandle,
    Tracker,
    Workspace
  }

  alias Aiur.Claude.RemoteControl

  alias Aiur.Events.{
    Exchange,
    GithubCIPoller,
    Publisher,
    Sanitizer,
    UniversalSubscriptions
  }

  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Opencode.ActiveTurns

  alias Aiur.Orchestrator.{
    AutoSubscriptions,
    CommandScan,
    CommentPolling,
    CommentWake,
    DigestCoalescer,
    Dispatcher,
    DispatchPolicy,
    EventTopics,
    Interrupts,
    IssueSync,
    PauseResume,
    PrAnchored,
    PushRouting,
    Reconciler,
    RetryEngine,
    Slots,
    State,
    TokenAccounting,
    TrackedSet,
    TrackerHealth
  }

  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.RemoteControlMode, as: RC

  alias AiurWeb.ObservabilityPubSub

  # Slightly above the dashboard render interval so the `0s` in-progress
  # label can render before the poll finishes.
  @poll_transition_render_delay_ms 20
  @ci_failure_excerpt_message_max 1_200
  @ci_wait_state "ci-wait"
  @human_review_state "human-review"
  @ci_poll_states [@ci_wait_state, @human_review_state]
  @transient_github_graphql_error_types ~w(
    INTERNAL
    INTERNAL_SERVER_ERROR
    RATE_LIMITED
    SERVER_ERROR
    SERVICE_UNAVAILABLE
    TIMEOUT
  )
  @empty_agent_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    # Trap exits so the supervisor's orderly shutdown lands in `terminate/2`,
    # which reaps every running agent's process tree (see `terminate/2`).
    Process.flag(:trap_exit, true)

    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()
    ci_persistence = CIApprovalStore.load()

    state = %State{
      poll_interval_ms: config.polling.interval_seconds * 1_000,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      # `--max-agents N` at launch: seed the session override (highest
      # precedence; `refresh_runtime_config/1` never clobbers it) so the cap
      # holds without editing `.aiur/config`.
      session_max_concurrent_agents: launch_max_concurrent_agents_override(),
      effective_concurrent_agents: initial_load_envelope_limit(config.agent),
      load_envelope_last_decrease_ms: nil,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      initial_dispatch_cycle: true,
      ci_lifecycle: ci_persistence,
      agent_totals: @empty_agent_totals,
      agent_rate_limits: nil
    }

    state = run_terminal_workspace_cleanup(state)
    state = run_startup_todo_workspace_cleanup(state)
    cleanup_stray_remote_control_servers()
    init_tracked_set_table()
    install_event_tracked_fn()
    subscribe_to_orchestrator_topics()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  # On whole-app shutdown the supervisor brutally kills the AgentRunner
  # tasks, skipping their `after stop_session` cleanup, and the per-issue
  # `kill_repl_session` path never runs. A headless `claude` backend runs
  # under a `bash -lc` wrapper whose claude/node grandchildren reparent to
  # init when the bash pid dies, so they survive the shutdown and can still
  # land a commit/push. The orchestrator stops before `Aiur.TaskSupervisor`
  # (later in the child list), so the bash pids are still alive here and
  # their subtrees are collectible — reap every running entry before the
  # tasks die.
  @impl true
  def terminate(_reason, %State{running: running}) when is_map(running) do
    # Best-effort accelerator: sweep registered agent processes first.
    # drain: false is load-bearing — terminate/2 also runs on a supervised
    # crash-restart, and latching the app-lifetime reaper into draining
    # there would kill every agent the restarted orchestrator spawns.
    _ = Aiur.ProcessReaper.reap([:agent], drain: false)
    Enum.each(running, fn {_issue_id, entry} -> kill_repl_session(entry) end)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Subscribe to the topics the orchestrator routes itself:
  #
  #   * `ticket.*.pr.review_comment` — reactivate a `:deactivated`
  #     entry when a PR review comment lands.
  #   * `ticket.*.issue.commented` — reactivate a `:deactivated` entry
  #     when an issue or PR-conversation comment lands. The firehose
  #     resolves PR-conversation comments back to the ticket id (via
  #     the PR's `aiur/<id>` head ref) before publishing, so the topic
  #     number matches the agent's identifier here.
  #   * `ticket.*.pr.merged` — mark a merged PR's linked ticket terminal
  #     and clean up any deactivated row left from human review.
  #   * `ticket.*.agent.pause.request` — when an agent emits
  #     pause.request it has decided to stop working. Flip its
  #     control status to `:paused` so `list_running_active_identifiers/0`
  #     stops counting it as active and the 5-min check-in worker
  #     stops spamming it.
  #   * `ticket.*.branch.push` — when a blocker pushes its branch,
  #     auto-resume any paused blockee that subscribed to that topic
  #     via `aiur_declare_blocker`. Without this hook the blockee's
  #     SubscriptionStore inbox accumulates the push event but the
  #     blockee process is idle until the next manual chat or label
  #     change.
  #   * `system.*.branch.push` — when the default branch advances,
  #     stop active agents so they cannot continue executing stale
  #     checkout runbooks or scripts after safety fixes land on main.
  defp subscribe_to_orchestrator_topics do
    if Process.whereis(Exchange) do
      Exchange.subscribe("ticket.*.pr.review_comment")
      Exchange.subscribe("ticket.*.issue.commented")
      Exchange.subscribe("ticket.*.pr.merged")
      Exchange.subscribe("ticket.*.ci.failed")
      Exchange.subscribe("ticket.*.agent.pause.request")
      Exchange.subscribe("ticket.*.branch.push")
      Exchange.subscribe("system.*.branch.push")
    end

    :ok
  end

  # Publisher reads this on every publish to decide whether an event
  # references a ticket Aiur is currently tracking. We update the same
  # closure every tick so it always sees the latest running/queued sets.
  defp install_event_tracked_fn do
    if Process.whereis(Publisher) do
      Publisher.set_tracked_fn(&issue_tracked?/1)
    end

    :ok
  end

  defp init_tracked_set_table do
    TrackedSet.reset([])
    :ok
  end

  # Public — called by the Publisher's tracked_fn closure. Reads ETS
  # directly so the publish path never makes a GenServer call back
  # into the orchestrator (which would deadlock when publish happens
  # inside `:run_poll_cycle`).
  @doc false
  @spec issue_tracked?(String.t() | integer() | nil) :: boolean()
  def issue_tracked?(nil), do: false

  def issue_tracked?(issue_number) do
    TrackedSet.member?(issue_number)
  end

  # Refreshes the tracked set with the current running issues. Called
  # after every poll cycle so the contamination filter sees the latest
  # set without crossing the GenServer mailbox boundary.
  #
  # `:deactivated` entries are excluded so late events from a killed
  # codex task don't pass the publisher gate after deactivation. The
  # entry stays in `state.running` for AgentList visibility, but the
  # publisher's view is "we are no longer accepting events for this id".
  @doc false
  @spec refresh_tracked_set(State.t()) :: State.t()
  def refresh_tracked_set(state) do
    needles =
      state.running
      |> Enum.reject(fn {_id, entry} ->
        get_in(entry, [:control, :status]) == :deactivated
      end)
      |> Enum.map(fn {_id, entry} ->
        id = entry[:identifier] || Map.get(entry, :identifier)
        if id, do: to_string(id)
      end)
      |> Enum.reject(&is_nil/1)

    TrackedSet.reset(needles)
    state
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard(state)
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard(state)
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, next_poll_delay_ms(state))
    state = %{state | poll_check_in_progress: false}

    notify_dashboard(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    handle_agent_down(state, ref, reason)
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard(state)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:repl_session_runtime, issue_id, info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:repl_pane_id, info[:pane_id])
          |> maybe_put_runtime_value(:repl_os_pid, info[:os_pid])
          |> maybe_put_runtime_value(:headless_os_pid, info[:headless_os_pid])
          |> maybe_put_runtime_value(:repl_rc_session_url, info[:session_url])

        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_agent_token_delta(token_delta)
          |> apply_agent_rate_limits(update)

        notify_dashboard(state)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

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
    handle_worker_control_state(state, issue_id, status, %{})
  end

  def handle_info({:worker_control_state, issue_id, :paused, pause_payload}, state)
      when is_binary(issue_id) and is_map(pause_payload) do
    handle_worker_control_state(state, issue_id, :paused, pause_payload)
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard(state)
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:retry_comment_rework, issue_number, source, event, attempt}, state)
      when is_integer(attempt) do
    {:noreply, maybe_reactivate_on_comment(state, issue_number, source, event, attempt)}
  end

  # PR review-comment fan-out from `Aiur.Events.Exchange`. The publisher's
  # `bot_self_loop?` filter drops self-comments before they reach here,
  # so any event arriving is from an external actor (a human reviewer,
  # another agent, etc.). Reactivate the matching `:deactivated` row;
  # `:working` / `:paused` entries are left alone (the live agent is
  # already in the loop and will see the comment via its own per-ticket
  # subscription).
  def handle_info({:event, %{topic: topic} = event}, state) when is_binary(topic) do
    case classify_event_topic(topic) do
      {:pr_review_comment, identifier} ->
        {:noreply, maybe_reactivate_on_comment(state, identifier, "PR review comment", event)}

      {:issue_commented, identifier} ->
        {:noreply, maybe_reactivate_on_comment(state, identifier, "issue comment", event)}

      {:pr_merged, identifier} ->
        {:noreply, mark_pr_merged_issue_done(state, identifier)}

      {:ci_failed, identifier} ->
        {:noreply, maybe_resume_for_ci_failure(state, identifier)}

      {:pause_request, identifier} ->
        {:noreply, maybe_pause_on_request(state, identifier)}

      {:branch_push, blocker_identifier} ->
        {:noreply, maybe_resume_blockees_on_push(state, blocker_identifier, topic)}

      {:system_branch_push, branch} ->
        {:noreply, maybe_notify_agents_on_default_branch_push(state, branch, event)}

      :nomatch ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_worker_control_state(%{running: running} = state, issue_id, status, pause_payload) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        previous_status = get_in(running_entry, [:control, :status]) || :working
        pause_reason = worker_pause_reason(running_entry, pause_payload)

        updated_running_entry =
          running_entry
          |> put_in([:control, :status], status)
          |> apply_pause_runtime_clock(previous_status, status, DateTime.utc_now())
          |> maybe_put_worker_pause_reason(status, pause_reason)

        maybe_log_worker_pause(status, updated_running_entry, pause_reason)
        maybe_emit_agent_control_alert(previous_status, status, updated_running_entry)

        state = %{state | running: Map.put(running, issue_id, updated_running_entry)}
        state = maybe_auto_resume_spurious_worker_pause(state, updated_running_entry, status)
        notify_dashboard(state)
        {:noreply, state}
    end
  end

  defp handle_agent_down(%{running: running} = state, ref, reason) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard(state)
        {:noreply, state}
    end
  end

  defp parse_pr_review_comment_topic(topic), do: EventTopics.parse_pr_review_comment_topic(topic)
  defp parse_issue_commented_topic(topic), do: EventTopics.parse_issue_commented_topic(topic)
  defp parse_ci_failed_topic(topic), do: EventTopics.parse_ci_failed_topic(topic)
  defp parse_pause_request_topic(topic), do: EventTopics.parse_pause_request_topic(topic)
  defp parse_branch_push_topic(topic), do: EventTopics.parse_branch_push_topic(topic)
  defp parse_system_branch_push_topic(topic), do: EventTopics.parse_system_branch_push_topic(topic)
  defp classify_event_topic(topic), do: EventTopics.classify_event_topic(topic)

  defp maybe_reactivate_on_comment(%State{} = state, issue_number, source, event, attempt \\ 1) do
    CommentWake.maybe_reactivate_on_comment(state, issue_number, source, event, attempt)
  end

  defp maybe_pause_on_request(%State{} = state, identifier) do
    PushRouting.maybe_pause_on_request(state, identifier)
  end

  defp maybe_notify_agents_on_default_branch_push(%State{} = state, branch, event) when is_binary(branch) do
    PushRouting.maybe_notify_agents_on_default_branch_push(state, branch, event)
  end

  defp maybe_notify_agents_on_default_branch_push(%State{} = state, branch, event) do
    PushRouting.maybe_notify_agents_on_default_branch_push(state, branch, event)
  end

  defp maybe_mark_sleeping(%State{} = state, identifier) do
    PushRouting.maybe_mark_sleeping(state, identifier)
  end

  defp maybe_resume_blockees_on_push(%State{} = state, blocker_identifier, topic) do
    PushRouting.maybe_resume_blockees_on_push(state, blocker_identifier, topic)
  end

  defp maybe_resume_for_ci_failure(%State{} = state, identifier) do
    case State.find_running_by_identifier(state.running, identifier) do
      %{control: %{status: :paused}, paused_reason: :ci_wait} = running_entry ->
        maybe_resume_ci_wait_runner(state, running_entry, identifier)

      _ ->
        state
    end
  end

  defp maybe_resume_ci_wait_runner(state, running_entry, identifier) do
    if Issue.paused?(Map.get(running_entry, :issue)) do
      state
    else
      resume_ci_wait_runner(state, running_entry, identifier)
    end
  end

  defp resume_ci_wait_runner(state, running_entry, identifier) do
    case resume_paused_issue(state, running_entry, false) do
      {{:ok, :resumed}, next_state} ->
        next_state

      {{:error, reason}, next_state} ->
        Logger.warning("CI failure auto-resume deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")
        next_state
    end
  end

  @doc false
  @spec transition_control_status(State.t(), map(), atom(), String.t()) :: State.t()
  def transition_control_status(state, running_entry, new_status, reason) do
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
        |> Map.put(:control, Map.put(existing, :status, new_status))
        |> apply_pause_runtime_clock(old_status, new_status, now)

      next_state = %{state | running: Map.put(state.running, issue_id, next_entry)}
      maybe_emit_agent_control_alert(old_status, new_status, next_entry)
      notify_dashboard(next_state)
      next_state
    end
  end

  defp mark_pr_merged_issue_done(%State{} = state, identifier) do
    CommentWake.mark_pr_merged_issue_done(state, identifier)
  end

  defp poll_github_firehose(%State{} = state, opts \\ []) do
    CommentPolling.poll_github_firehose(state, opts)
  end

  defp poll_github_comments(%State{} = state, opts \\ []) do
    CommentPolling.poll_github_comments(state, opts)
  end

  defp poll_github_ci(%State{} = state, opts \\ []) do
    case Config.tracker_kind() do
      "github" -> do_poll_github_ci(state, opts)
      _ -> state
    end
  end

  defp do_poll_github_ci(%State{} = state, opts) do
    issue_fetcher = Keyword.get(opts, :ci_issue_fetcher, &Tracker.fetch_issues_by_states/1)
    poller = Keyword.get(opts, :ci_poller, &GithubCIPoller.poll/2)

    case issue_fetcher.(@ci_poll_states) do
      {:ok, issues} when is_list(issues) ->
        state
        |> prune_ci_lifecycle_state(issues)
        |> poll_github_ci_targets(issues, poller, opts)

      {:error, reason} ->
        Logger.warning("GithubCIPoller target refresh skipped; reason=#{inspect(reason)}")
        note_github_connectivity_failure(state, :ci, reason)

      other ->
        Logger.warning("GithubCIPoller target refresh returned unexpected value=#{inspect(other)}")
        state
    end
  end

  defp poll_github_ci_targets(%State{} = state, issues, poller, opts) do
    issues_by_target = ci_issues_by_target(issues)
    targets = Map.keys(issues_by_target)

    case poller.(targets, opts) do
      {:ok, %{results: results, errors: errors}} when is_list(results) and is_list(errors) ->
        state =
          state
          |> note_ci_poll_connectivity(targets, errors)
          |> log_ci_poll_errors(errors)

        apply_ci_poll_results(state, results, issues_by_target)

      {:error, reason} ->
        Logger.warning("GithubCIPoller failed; reason=#{inspect(reason)}")
        note_github_connectivity_failure(state, :ci, reason)

      other ->
        Logger.warning("GithubCIPoller returned unexpected value=#{inspect(other)}")
        state
    end
  end

  defp ci_issues_by_target(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{} = issue, acc ->
        case ci_target_for_issue(issue) do
          nil -> acc
          target -> Map.put_new(acc, target, issue)
        end

      _other, acc ->
        acc
    end)
  end

  defp note_ci_poll_connectivity(state, targets, errors) do
    if errors == [] or not all_ci_targets_failed?(targets, errors) do
      note_github_connectivity_success(state, :ci)
    else
      note_github_connectivity_failure(state, :ci, List.first(errors))
    end
  end

  defp log_ci_poll_errors(state, []), do: state

  defp log_ci_poll_errors(state, errors) do
    Logger.warning("GithubCIPoller partial failures; reason=#{inspect(errors)}")
    state
  end

  defp apply_ci_poll_results(state, results, issues_by_target) do
    Enum.reduce(results, state, fn result, state_acc ->
      apply_ci_poll_result_for_target(state_acc, result, issues_by_target)
    end)
  end

  defp apply_ci_poll_result_for_target(state, result, issues_by_target) do
    case Map.get(issues_by_target, Map.get(result, :target)) do
      %Issue{} = issue -> apply_ci_poll_result(state, issue, result)
      _ -> state
    end
  end

  defp ci_target_for_issue(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
  defp ci_target_for_issue(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp ci_target_for_issue(_issue), do: nil

  defp all_ci_targets_failed?([], _errors), do: false

  defp all_ci_targets_failed?(targets, errors) do
    failed_targets = errors |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    MapSet.subset?(MapSet.new(targets), failed_targets)
  end

  defp apply_ci_poll_result(state, issue, %{decision: :pending} = result) do
    cond do
      ci_wait_state?(issue.state) ->
        state

      human_review_state?(issue.state) and ci_head_approved?(state, issue, result) ->
        refresh_running_issue_state(state, issue)

      true ->
        transition_ci_ticket(state, issue, @ci_wait_state)
    end
  end

  defp apply_ci_poll_result(state, issue, %{decision: :passed} = result) do
    if human_review_state?(issue.state) do
      state
      |> clear_ci_test_failure_retry(issue)
      |> remember_ci_approved_head(issue, result)
      |> refresh_running_issue_state(issue)
    else
      transition_ci_pass(state, issue, result)
    end
  end

  defp apply_ci_poll_result(state, issue, %{decision: :failed} = result) do
    if retryable_test_failure?(state, issue, result) do
      state
      |> remember_ci_test_failure_retry(issue, result)
      |> defer_ci_test_failure(issue)
    else
      state
      |> clear_ci_test_failure_retry(issue)
      |> transition_ci_failure(issue, result)
    end
  end

  defp apply_ci_poll_result(state, _issue, _result), do: state

  defp transition_ci_ticket(state, %Issue{} = issue, next_state) do
    issue_key = issue.id || issue.identifier

    case Tracker.update_issue_state(to_string(issue_key), next_state) do
      :ok ->
        updated_issue = %{issue | state: next_state}
        state = if ci_wait_state?(next_state), do: clear_ci_approved_head(state, issue), else: state

        cond do
          DispatchPolicy.active_issue_state?(next_state, DispatchPolicy.active_state_set()) ->
            maybe_reactivate_or_refresh(state, updated_issue)

          ci_wait_state?(next_state) ->
            pause_issue_for_ci_wait(state, updated_issue)

          true ->
            refresh_running_issue_state(state, updated_issue)
        end

      {:error, reason} ->
        Logger.warning("CI lifecycle transition skipped: #{issue_context(issue)} state=#{next_state} reason=#{inspect(reason)}")
        state
    end
  end

  defp transition_ci_pass(state, issue, result) do
    case Tracker.update_issue_state(to_string(issue.id || issue.identifier), @human_review_state) do
      :ok ->
        state
        |> clear_ci_test_failure_retry(issue)
        |> remember_ci_approved_head(issue, result)
        |> refresh_running_issue_state(%{issue | state: @human_review_state})
        |> publish_ci_terminal_event(issue, result, :passed)

      {:error, reason} ->
        Logger.warning("CI pass transition skipped: #{issue_context(issue)} reason=#{inspect(reason)}")
        state
    end
  end

  defp transition_ci_failure(state, issue, result) do
    case Tracker.update_issue_state(to_string(issue.id || issue.identifier), "rework") do
      :ok ->
        state
        |> clear_ci_test_failure_retry(issue)
        |> clear_ci_approved_head(issue)
        |> ensure_ci_failure_subscription(issue)
        |> publish_ci_terminal_event(issue, result, :failed)
        |> maybe_reactivate_after_ci_failure(%{issue | state: "rework"})

      {:error, reason} ->
        Logger.warning("CI failure transition skipped: #{issue_context(issue)} reason=#{inspect(reason)}")
        state
    end
  end

  defp maybe_reactivate_after_ci_failure(state, issue) do
    if Issue.paused?(issue) do
      refresh_running_issue_state(state, issue)
    else
      case Map.get(state.running, issue.id) do
        %{control: %{status: :paused}, paused_reason: :label_override} ->
          refresh_running_issue_state(state, issue)

        _ ->
          maybe_reactivate_or_refresh(state, issue)
      end
    end
  end

  # A failed `test` check may be the known seed-dependent flake. Defer only the
  # first terminal observation of that exact head for one regular poll cycle;
  # the second failure is delivered to the agent like every other CI failure.
  defp retryable_test_failure?(%State{} = state, %Issue{} = issue, %{head_sha: head_sha, failures: failures})
       when is_binary(head_sha) and is_list(failures) do
    test_only_failure?(failures) and Map.get(state.ci_lifecycle.test_failure_heads, ci_target_for_issue(issue)) != head_sha
  end

  defp retryable_test_failure?(_state, _issue, _result), do: false

  defp test_only_failure?(failures) do
    failures != [] and
      Enum.all?(failures, fn
        %{name: "test"} -> true
        _ -> false
      end)
  end

  defp defer_ci_test_failure(state, issue) do
    if human_review_state?(issue.state) do
      transition_ci_ticket(state, issue, @ci_wait_state)
    else
      state
    end
  end

  # A direct agent label flip is the initial CI handoff. Once a head has passed,
  # retain that exact SHA so a transient re-run does not pull it out of review;
  # a pending observation for a different SHA is a re-push and must re-enter the
  # CI gate.
  defp ci_head_approved?(%State{} = state, %Issue{} = issue, result) do
    case {Map.get(state.ci_lifecycle.approved_heads, ci_target_for_issue(issue)), Map.get(result, :head_sha)} do
      {approved_head, observed_head} when is_binary(approved_head) and approved_head == observed_head -> true
      {approved_head, nil} when is_binary(approved_head) -> true
      _ -> false
    end
  end

  defp remember_ci_approved_head(%State{} = state, %Issue{} = issue, %{head_sha: head_sha})
       when is_binary(head_sha) and head_sha != "" do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        approved_heads = Map.put(state.ci_lifecycle.approved_heads, target, head_sha)
        persist_ci_lifecycle_state(%{state | ci_lifecycle: %{state.ci_lifecycle | approved_heads: approved_heads}})

      _ ->
        state
    end
  end

  defp remember_ci_approved_head(state, _issue, _result), do: state

  defp clear_ci_approved_head(%State{} = state, %Issue{} = issue) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        approved_heads = Map.delete(state.ci_lifecycle.approved_heads, target)
        persist_ci_lifecycle_state(%{state | ci_lifecycle: %{state.ci_lifecycle | approved_heads: approved_heads}})

      _ ->
        state
    end
  end

  defp remember_ci_test_failure_retry(%State{} = state, %Issue{} = issue, %{head_sha: head_sha}) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) and is_binary(head_sha) ->
        test_failure_heads = Map.put(state.ci_lifecycle.test_failure_heads, target, head_sha)
        ci_lifecycle = %{state.ci_lifecycle | test_failure_heads: test_failure_heads}
        persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})

      _ ->
        state
    end
  end

  defp clear_ci_test_failure_retry(%State{} = state, %Issue{} = issue) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        test_failure_heads = Map.delete(state.ci_lifecycle.test_failure_heads, target)
        ci_lifecycle = %{state.ci_lifecycle | test_failure_heads: test_failure_heads}
        persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})

      _ ->
        state
    end
  end

  defp prune_ci_lifecycle_state(%State{} = state, issues) do
    targets =
      issues
      |> Enum.map(&ci_target_for_issue/1)
      |> Enum.filter(&is_binary/1)

    approved_heads = Map.take(state.ci_lifecycle.approved_heads, targets)
    test_failure_heads = Map.take(state.ci_lifecycle.test_failure_heads, targets)

    if approved_heads == state.ci_lifecycle.approved_heads and
         test_failure_heads == state.ci_lifecycle.test_failure_heads do
      state
    else
      ci_lifecycle = %{approved_heads: approved_heads, test_failure_heads: test_failure_heads}
      persist_ci_lifecycle_state(%{state | ci_lifecycle: ci_lifecycle})
    end
  end

  defp persist_ci_lifecycle_state(%State{} = state) do
    :ok = CIApprovalStore.save(state.ci_lifecycle.approved_heads, state.ci_lifecycle.test_failure_heads)
    state
  end

  defp publish_ci_terminal_event(state, issue, result, outcome) do
    target = ci_target_for_issue(issue)
    topic = "ticket.#{target}.ci.#{outcome}"

    payload =
      %{
        source: :github,
        head_sha: Map.get(result, :head_sha),
        pr_number: Map.get(result, :pr_number),
        checks: Map.get(result, :failures, []),
        failure_excerpt: ci_failure_excerpt(Map.get(result, :failures, []))
      }
      |> Sanitizer.scrub()
      |> then(fn payload ->
        Map.put(
          payload,
          :message,
          ci_terminal_message(
            outcome,
            Map.get(payload, :checks, []),
            Map.get(payload, :failure_excerpt)
          )
        )
      end)

    case Publisher.publish(topic, payload,
           issue_number: target,
           bypass_contamination: true,
           dedup_key: ci_event_dedup_key(target, outcome, Map.get(result, :head_sha))
         ) do
      {:ok, _id, _subscribers} ->
        state

      :deduped ->
        state

      :filtered ->
        Logger.warning("CI terminal event unexpectedly filtered: issue=#{target} topic=#{topic}")
        state
    end
  end

  defp ensure_ci_failure_subscription(state, issue) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        :ok = UniversalSubscriptions.attach(target)
        state

      _ ->
        state
    end
  end

  defp ci_event_dedup_key(target, outcome, head_sha)
       when is_binary(target) and is_atom(outcome) and is_binary(head_sha) do
    {"ci", Atom.to_string(outcome), target <> ":" <> head_sha}
  end

  defp ci_event_dedup_key(_target, _outcome, _head_sha), do: nil

  defp ci_failure_excerpt(failures) when is_list(failures) do
    Enum.find_value(failures, fn
      %{excerpt: excerpt} when is_binary(excerpt) and excerpt != "" -> excerpt
      _ -> nil
    end)
  end

  defp ci_failure_excerpt(_failures), do: nil

  defp ci_terminal_message(:passed, _failures, _failure_excerpt), do: "CI passed for the current PR head"

  defp ci_terminal_message(:failed, failures, failure_excerpt) do
    names =
      failures
      |> Enum.map(&Map.get(&1, :name))
      |> Enum.filter(&is_binary/1)
      |> Enum.join(", ")

    message = if names == "", do: "CI failed for the current PR head", else: "CI failed: " <> names

    if is_binary(failure_excerpt) and failure_excerpt != "" do
      message <> ". Failure excerpt: " <> String.slice(failure_excerpt, 0, @ci_failure_excerpt_message_max)
    else
      message
    end
  end

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

  defp next_poll_delay_ms(state), do: TrackerHealth.next_poll_delay_ms(state)

  @doc false
  @spec github_next_poll_delay_ms(State.t()) :: non_neg_integer() | nil
  def github_next_poll_delay_ms(state), do: TrackerHealth.github_next_poll_delay_ms(state)

  defp scan_pr_commands(%State{} = state, opts \\ []) do
    CommandScan.scan_pr_commands(state, opts)
  end

  defp maybe_stop_closed_pr_anchored_agents(%State{} = state, opts \\ []) do
    PrAnchored.maybe_stop_closed_pr_anchored_agents(state, opts)
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_lifecycle(state)

    case ensure_tracker_preflight(state) do
      {:ok, state} ->
        state
        |> do_maybe_dispatch()

      {:error, reason, state} ->
        log_tracker_preflight_error(reason)
        state
    end
  end

  defp do_maybe_dispatch(%State{} = state) do
    state = refresh_tracked_set(state)
    state = poll_github_firehose(state)
    state = poll_github_comments(state)
    state = poll_github_ci(state)
    state = refresh_running_issue_states(state)
    state = scan_pr_commands(state)
    state = maybe_stop_closed_pr_anchored_agents(state)

    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues = PauseResume.recover_startup_pause_overrides(state, issues)

        state =
          state
          |> sync_polled_issue_state(issues)
          |> sync_todo_capacity_alert(issues)

        # The poll just refreshed `last_polled_issues`, so push a fresh
        # summary out to any open agent-list pane immediately — without
        # this, the pane only sees new candidate tickets after the next
        # dispatch or completion event.
        notify_dashboard(state)

        state = dispatch_or_hold(state, issues)

        %{state | initial_dispatch_cycle: false}

      {:error, reason} ->
        log_tracker_fetch_error(reason)
        state
    end
  end

  @doc false
  @spec ensure_tracker_preflight(State.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def ensure_tracker_preflight(state), do: TrackerHealth.ensure_tracker_preflight(state)

  @doc false
  @spec log_tracker_preflight_error(term()) :: :ok
  def log_tracker_preflight_error(reason), do: TrackerHealth.log_tracker_preflight_error(reason)

  @doc false
  @spec log_tracker_fetch_error(term()) :: :ok
  def log_tracker_fetch_error(reason), do: TrackerHealth.log_tracker_fetch_error(reason)
  # base is ready so per-issue workspaces materialize from it instead of cold-
  # cloning. Async: it kicks RepoBase (which builds in its own process and emits
  # phase events for the loading bar) and reads status without blocking the
  # orchestrator. A failed base build falls back to cold dispatch rather than
  # hanging the run. The base build is kicked here, before the CPU load gate, so
  # a transiently busy box still warms its base (the build is one-time + cached).
  defp dispatch_or_hold(state, issues) do
    enabled? = Config.prewarm_enabled?()
    phase = if enabled?, do: trigger_and_status(), else: :ready

    case prewarm_gate(enabled?, phase) do
      :dispatch ->
        maybe_log_base_error(phase)
        maybe_choose_under_load(state, issues)

      :hold ->
        state
    end
  end

  # CPU load gate (#465): once the base is ready, hold the poll choose-loop while
  # the host 1-min load exceeds `max_load_average` per scheduler, so the
  # already-running agents' full mix-test suites don't melt the box. Scoped to
  # NEW-work admission only — retries and reactivations re-run already-claimed
  # work (bounded by the count cap) and intentionally bypass this gate, since
  # rescheduling them under load would burn their `max_retry_attempts` budget. A
  # held tick re-arms at the configured poll interval and resumes once load
  # drops; already-running agents are never touched.
  defp maybe_choose_under_load(state, issues) do
    hard_threshold = Config.max_load_average()
    target = Config.target_load_average()
    schedulers = System.schedulers_online()
    load = read_load(hard_threshold, target)

    state =
      update_load_envelope(
        state,
        load,
        target,
        schedulers,
        System.monotonic_time(:millisecond)
      )

    case load_gate(load, hard_threshold, schedulers) do
      :hold ->
        log_load_hold(load, hard_threshold, schedulers)
        state

      :dispatch ->
        maybe_choose(state, issues)
    end
  end

  @doc false
  # Reads the host 1-min load only when the gate is enabled (threshold > 0), so
  # explicit-disable configs never touch /proc. Exposed for unit-testing the
  # short-circuit; the pure hold/dispatch decision is load_gate/3.
  @spec read_load(number() | nil) :: float() | :unavailable
  defdelegate read_load(threshold), to: DispatchPolicy

  @doc false
  @spec read_load(number() | nil, number() | nil) :: float() | :unavailable
  defdelegate read_load(hard_threshold, target), to: DispatchPolicy

  defp log_load_hold(load, threshold, schedulers) do
    Logger.info(
      "aiur_perf load_hold load=#{load} threshold=#{threshold} " <>
        "schedulers=#{schedulers} limit=#{threshold * schedulers}"
    )
  end

  defp trigger_and_status do
    RepoBase.refresh_async()
    RepoBase.status() |> elem(0)
  end

  defp maybe_choose(state, issues) do
    if available_slots(state) > 0, do: choose_issues(state, issues), else: state
  end

  defp maybe_log_base_error({:error, reason}),
    do: Logger.warning("prewarm base unavailable (#{inspect(reason)}); dispatching via cold clone")

  defp maybe_log_base_error(_phase), do: :ok

  @doc false
  # Pure dispatch decision for the eager pre-warm gate, kept separate so it can be
  # unit-tested without the orchestrator GenServer.
  @spec prewarm_gate(boolean(), atom() | {:error, term()}) :: :dispatch | :hold
  defdelegate prewarm_gate(enabled?, phase), to: DispatchPolicy

  @doc false
  # Pure CPU load gate (#465), kept separate so it can be unit-tested without the
  # orchestrator GenServer. Holds new dispatch only when the 1-min load average
  # strictly exceeds `threshold` per scheduler; fails open (dispatch) when the
  # gate is disabled (nil/<=0 threshold) or the load is unavailable (non-Linux).
  @spec load_gate(number() | :unavailable, number() | nil, pos_integer()) :: :dispatch | :hold
  defdelegate load_gate(load, threshold, schedulers), to: DispatchPolicy

  @doc false
  @spec load_envelope(integer() | nil, integer() | nil, number() | :unavailable, map()) ::
          {pos_integer(), integer() | nil}
  defdelegate load_envelope(effective, last_decrease_ms, load, options), to: DispatchPolicy

  defp update_load_envelope(state, load, target, schedulers, now_ms) do
    {effective, last_decrease_ms} =
      load_envelope(
        state.effective_concurrent_agents,
        state.load_envelope_last_decrease_ms,
        load,
        %{
          target: target,
          schedulers: schedulers,
          static_limit: max_concurrent_agent_limit(state),
          ramp_step: Config.load_ramp_step(),
          cooldown_ms: Config.load_cooldown_seconds() * 1_000,
          now_ms: now_ms
        }
      )

    %{state | effective_concurrent_agents: effective, load_envelope_last_decrease_ms: last_decrease_ms}
  end

  defp initial_load_envelope_limit(%{target_load_average: nil}), do: nil
  defp initial_load_envelope_limit(_agent), do: 1

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec run_terminal_workspace_cleanup_for_test(State.t()) :: State.t()
  def run_terminal_workspace_cleanup_for_test(%State{} = state) do
    run_terminal_workspace_cleanup(state)
  end

  @doc false
  @spec run_startup_todo_workspace_cleanup_for_test(State.t()) :: State.t()
  def run_startup_todo_workspace_cleanup_for_test(%State{} = state) do
    run_startup_todo_workspace_cleanup(state)
  end

  @doc false
  @spec slot_status_for_test(State.t()) :: %{active: non_neg_integer(), paused: non_neg_integer()}
  def slot_status_for_test(%State{} = state) do
    %{
      active: active_running_count(state.running),
      paused: paused_running_count(state.running)
    }
  end

  @doc false
  @spec parse_pr_review_comment_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pr_review_comment_topic_for_test(topic) when is_binary(topic) do
    parse_pr_review_comment_topic(topic)
  end

  @doc false
  @spec parse_issue_commented_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_issue_commented_topic_for_test(topic) when is_binary(topic) do
    parse_issue_commented_topic(topic)
  end

  @doc false
  @spec parse_ci_failed_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_ci_failed_topic_for_test(topic) when is_binary(topic) do
    parse_ci_failed_topic(topic)
  end

  @doc false
  @spec poll_github_firehose_for_test(State.t(), keyword()) :: State.t()
  def poll_github_firehose_for_test(%State{} = state, opts) when is_list(opts) do
    poll_github_firehose(state, opts)
  end

  @doc false
  @spec poll_github_comments_for_test(State.t(), keyword()) :: State.t()
  def poll_github_comments_for_test(%State{} = state, opts) when is_list(opts) do
    poll_github_comments(state, opts)
  end

  @doc false
  @spec poll_github_ci_for_test(State.t(), keyword()) :: State.t()
  def poll_github_ci_for_test(%State{} = state, opts) when is_list(opts) do
    poll_github_ci(state, opts)
  end

  @doc false
  @spec scan_pr_commands_for_test(State.t(), keyword()) :: State.t()
  def scan_pr_commands_for_test(%State{} = state, opts) when is_list(opts) do
    scan_pr_commands(state, opts)
  end

  @doc false
  @spec maybe_stop_closed_pr_anchored_agents_for_test(State.t(), keyword()) :: State.t()
  def maybe_stop_closed_pr_anchored_agents_for_test(%State{} = state, opts) when is_list(opts) do
    maybe_stop_closed_pr_anchored_agents(state, opts)
  end

  @doc false
  @spec github_next_poll_delay_for_test(State.t()) :: non_neg_integer() | nil
  def github_next_poll_delay_for_test(%State{} = state), do: github_next_poll_delay_ms(state)

  @doc false
  @spec parse_pause_request_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pause_request_topic_for_test(topic) when is_binary(topic) do
    parse_pause_request_topic(topic)
  end

  @doc false
  @spec parse_branch_push_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_branch_push_topic_for_test(topic) when is_binary(topic) do
    parse_branch_push_topic(topic)
  end

  @doc false
  @spec parse_system_branch_push_topic_for_test(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_system_branch_push_topic_for_test(topic) when is_binary(topic) do
    parse_system_branch_push_topic(topic)
  end

  @doc false
  @spec apply_pause_request_for_test(State.t(), String.t()) :: State.t()
  def apply_pause_request_for_test(%State{} = state, identifier) when is_binary(identifier) do
    maybe_pause_on_request(state, identifier)
  end

  @doc false
  @spec apply_mark_sleeping_for_test(State.t(), String.t()) :: State.t()
  def apply_mark_sleeping_for_test(%State{} = state, identifier) when is_binary(identifier) do
    maybe_mark_sleeping(state, identifier)
  end

  @doc false
  @spec apply_branch_push_for_test(State.t(), String.t()) :: State.t()
  def apply_branch_push_for_test(%State{} = state, blocker_identifier)
      when is_binary(blocker_identifier) do
    topic = "ticket." <> blocker_identifier <> ".branch.push"
    maybe_resume_blockees_on_push(state, blocker_identifier, topic)
  end

  @doc false
  @spec apply_system_branch_push_for_test(State.t(), String.t(), map()) :: State.t()
  def apply_system_branch_push_for_test(%State{} = state, branch, event \\ %{})
      when is_binary(branch) and is_map(event) do
    maybe_notify_agents_on_default_branch_push(state, branch, event)
  end

  @doc false
  @spec apply_stall_check_for_test(State.t(), pos_integer()) :: State.t()
  def apply_stall_check_for_test(%State{} = state, timeout_ms) when is_integer(timeout_ms) do
    now = DateTime.utc_now()

    Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
      restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
    end)
  end

  @doc false
  @spec apply_overrun_check_for_test(State.t(), non_neg_integer()) :: State.t()
  def apply_overrun_check_for_test(%State{} = state, max_seconds)
      when is_integer(max_seconds) and max_seconds >= 0 do
    now = DateTime.utc_now()

    Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
      maybe_pause_overrunning_entry(state_acc, issue_id, running_entry, now, max_seconds)
    end)
  end

  @doc false
  @spec resume_paused_issue_for_test(State.t(), map(), boolean()) :: {term(), State.t()}
  def resume_paused_issue_for_test(%State{} = state, running_entry, operator? \\ true)
      when is_map(running_entry) and is_boolean(operator?) do
    resume_paused_issue(state, running_entry, operator?)
  end

  @doc false
  @spec apply_thrash_check_for_test(State.t(), String.t(), integer()) ::
          {:ok, State.t()} | {:trip, State.t()}
  def apply_thrash_check_for_test(%State{} = state, issue_id, now_ms)
      when is_binary(issue_id) and is_integer(now_ms) do
    check_thrash_budget(state, issue_id, now_ms)
  end

  @doc false
  @spec sync_polled_issue_state_for_test(State.t(), [Issue.t()]) :: State.t()
  def sync_polled_issue_state_for_test(%State{} = state, issues) when is_list(issues) do
    sync_polled_issue_state(state, issues)
  end

  @doc false
  @spec sync_todo_capacity_alert_for_test(State.t(), [Issue.t()]) :: State.t()
  def sync_todo_capacity_alert_for_test(%State{} = state, issues) when is_list(issues) do
    sync_todo_capacity_alert(state, issues)
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec dispatch_candidate_for_test(Issue.t(), term()) :: boolean()
  def dispatch_candidate_for_test(%Issue{} = issue, %State{} = state) do
    dispatch_candidate?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec recover_startup_pause_overrides_for_test(State.t(), [term()]) :: [term()]
  def recover_startup_pause_overrides_for_test(%State{} = state, issues) when is_list(issues) do
    PauseResume.recover_startup_pause_overrides(state, issues)
  end

  @doc false
  @spec retry_dispatch_ready_for_test(Issue.t(), State.t(), String.t() | nil) :: boolean()
  def retry_dispatch_ready_for_test(%Issue{} = issue, %State{} = state, worker_host \\ nil) do
    retry_candidate_issue?(issue, terminal_state_set()) and
      dispatch_slots_available?(issue, state) and
      worker_slots_available?(state, worker_host)
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec set_remote_control_for_test(State.t(), String.t(), boolean()) :: {term(), State.t()}
  def set_remote_control_for_test(%State{} = state, identifier, on?)
      when is_binary(identifier) and is_boolean(on?) do
    set_remote_control_reply(state, identifier, on?)
  end

  @doc false
  @spec reactivate_issue_for_test(State.t(), map()) :: {term(), State.t()}
  def reactivate_issue_for_test(%State{} = state, running_entry) when is_map(running_entry) do
    reactivate_issue(state, running_entry)
  end

  @doc false
  @spec remote_control_summary_for_test(map()) :: map() | nil
  def remote_control_summary_for_test(entry), do: remote_control_summary(entry)

  @doc false
  @spec terminate_running_issue_for_test(State.t(), String.t(), boolean()) :: State.t()
  def terminate_running_issue_for_test(%State{} = state, issue_id, cleanup_workspace)
      when is_binary(issue_id) and is_boolean(cleanup_workspace) do
    terminate_running_issue(state, issue_id, cleanup_workspace)
  end

  # Matches the `agent:human-review` label (after `normalize_issue_state`,
  # this is `"human-review"`). Reserved for the deactivate path — keeps the
  # running entry visible at 🏁 / 100% while releasing the slot and chat
  # pane, instead of dropping it the way the catch-all `true →` branch
  # would.
  @doc false
  @spec human_review_state?(binary() | term()) :: boolean()
  def human_review_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "human-review"
  end

  def human_review_state?(_), do: false

  @doc false
  @spec ci_wait_state?(binary() | term()) :: boolean()
  def ci_wait_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @ci_wait_state
  end

  def ci_wait_state?(_), do: false

  @doc false
  @spec error_issue_state?(binary() | term()) :: boolean()
  def error_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "error"
  end

  def error_issue_state?(_), do: false

  @doc false
  @spec preserve_running_issue_on_external_error(State.t(), Issue.t()) :: State.t()
  def preserve_running_issue_on_external_error(%State{} = state, %Issue{} = issue) do
    previous_state =
      case Map.get(state.running, issue.id) do
        %{issue: %Issue{state: state_name}} -> normalize_issue_state(state_name)
        %{issue: %{state: state_name}} -> normalize_issue_state(state_name)
        _ -> ""
      end

    if previous_state == "error" do
      Logger.debug("Issue remains in error state while agent is still active: #{issue_context(issue)}")
    else
      Logger.warning("Issue reported error state while agent is still active; preserving runner pending local completion: #{issue_context(issue)} state=#{issue.state}")
    end

    refresh_running_issue_state(state, issue)
  end

  @doc false
  @spec maybe_deactivate_human_review_issue(State.t(), Issue.t()) :: State.t()
  def maybe_deactivate_human_review_issue(%State{} = state, %Issue{} = issue) do
    case verify_human_review_ready(issue) do
      :ok ->
        deactivate_running_issue(state, issue.id)

      {:error, reason} ->
        if transient_human_review_verification_error?(reason) do
          defer_human_review_transition(state, issue, reason)
        else
          reject_human_review_transition(state, issue, reason)
        end
    end
  end

  defp verify_human_review_ready(%Issue{id: issue_id}) when is_binary(issue_id) do
    case Application.get_env(:aiur, :human_review_ready_verifier) do
      verifier when is_function(verifier, 1) ->
        verifier.(issue_id)

      _ ->
        verify_human_review_ready_with_tracker(issue_id)
    end
  end

  defp verify_human_review_ready(_issue), do: :ok

  defp transient_human_review_verification_error?({:github, kind, _detail})
       when kind in [:dns, :timeout, :tls, :transport, :rate_limited],
       do: true

  defp transient_human_review_verification_error?({:github_api_status, status})
       when status in [408, 429] or status in 500..599,
       do: true

  defp transient_human_review_verification_error?({:github_graphql_errors, errors})
       when is_list(errors),
       do: Enum.any?(errors, &transient_github_graphql_error?/1)

  defp transient_human_review_verification_error?(_reason), do: false

  defp transient_github_graphql_error?(error) when is_map(error) do
    error
    |> github_graphql_error_values()
    |> Enum.any?(&transient_github_graphql_error_value?/1)
  end

  defp transient_github_graphql_error?(_error), do: false

  defp github_graphql_error_values(error) do
    [
      Map.get(error, "type"),
      Map.get(error, :type),
      Map.get(error, "code"),
      Map.get(error, :code),
      get_in(error, ["extensions", "code"]),
      get_in(error, [:extensions, :code])
    ]
  end

  defp transient_github_graphql_error_value?(value) when is_atom(value),
    do: value |> Atom.to_string() |> transient_github_graphql_error_value?()

  defp transient_github_graphql_error_value?(value) when is_binary(value),
    do: String.upcase(value) in @transient_github_graphql_error_types

  defp transient_github_graphql_error_value?(_value), do: false

  defp defer_human_review_transition(%State{} = state, %Issue{} = issue, reason) do
    Logger.warning("human-review transition verification deferred: #{issue_context(issue)} reason=#{inspect(reason)}")

    state
  end

  defp verify_human_review_ready_with_tracker(issue_id) do
    if Tracker.adapter() == GitHubTracker do
      client = github_client_module()

      if function_exported?(client, :verify_human_review_ready, 1) do
        client.verify_human_review_ready(issue_id)
      else
        :ok
      end
    else
      :ok
    end
  end

  defp reject_human_review_transition(%State{} = state, %Issue{} = issue, reason) do
    issue_key = issue.id || issue.identifier

    Logger.warning("human-review transition rejected; reverting to rework: #{issue_context(issue)} reason=#{inspect(reason)}")

    case Tracker.update_issue_state(to_string(issue_key), "rework") do
      :ok ->
        maybe_reactivate_or_refresh(state, %{issue | state: "rework"})

      {:error, update_reason} ->
        Logger.warning("human-review rework revert failed: #{issue_context(issue)} reason=#{inspect(update_reason)}")

        state
    end
  end

  defp github_client_module do
    Application.get_env(:aiur, :github_client_module, GitHubClient)
  end

  # Broadcast `aiur_turn_done` for every currently-active aiur turn on
  # `identifier`. The opencode bridge's chat-completion SSE handlers
  # subscribe to `agent:<identifier>` and rely on this broadcast to
  # close cleanly. Without it, killing the AgentRunner mid-turn (via
  # `terminate_task/1`) leaves the SSE streams subscribed until their
  # 10-minute watchdog fires, then they dump duplicate system messages
  # into the chat pane (one per pre-warmed opencode slot).
  @doc false
  @spec close_active_chat_streams(String.t(), term()) :: :ok
  def close_active_chat_streams(identifier, reason) when is_binary(identifier) do
    for aiur_turn_id <- ActiveTurns.active_turn_ids(identifier) do
      AgentPubSub.broadcast_aiur_turn_done(identifier, aiur_turn_id, reason)
      ActiveTurns.mark_closed(identifier, aiur_turn_id, reason)
    end

    :ok
  end

  def close_active_chat_streams(_identifier, _reason), do: :ok

  defp terminate_reason(true), do: :terminal
  defp terminate_reason(false), do: :replaced

  # Label flipped back to an active state. If the running entry is
  # currently `:deactivated`, route through `reactivate_issue/2` so a
  # fresh agent task is spawned. If it was paused by `agent:paused`, resume
  # the parked session once that override disappears. Otherwise just refresh
  # the stored issue (existing behaviour for `:working` / manual `:paused`
  # entries).

  @doc false
  @spec pause_issue_for_label_override(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_label_override(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      nil ->
        release_issue_claim(state, issue.id)

      %{control: %{status: :deactivated}} = running_entry ->
        refresh_running_entry_issue(state, issue, running_entry)

      %{control: %{status: :paused}} = running_entry ->
        refresh_running_entry_issue(state, issue, running_entry)

      running_entry when is_map(running_entry) ->
        identifier = Map.get(running_entry, :identifier, issue.identifier || issue.id)

        Logger.info("Issue pause override detected: #{issue_context(issue)}; pausing active agent")

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

  defp refresh_running_entry_issue(%State{} = state, %Issue{} = issue, running_entry)
       when is_map(running_entry) do
    %{state | running: Map.put(state.running, issue.id, Map.put(running_entry, :issue, issue))}
  end

  @doc false
  @spec pause_issue_for_ci_wait(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_ci_wait(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      nil ->
        release_issue_claim(state, issue.id)

      %{control: %{status: :deactivated}} = running_entry ->
        refresh_running_entry_issue(state, issue, running_entry)

      %{control: %{status: :paused}} = running_entry ->
        refresh_running_entry_issue(state, issue, running_entry)

      running_entry when is_map(running_entry) ->
        identifier = Map.get(running_entry, :identifier, issue.identifier || issue.id)

        Logger.info("CI wait detected: #{issue_context(issue)}; pausing active agent")

        _ = send_pause_control_message(state, identifier)

        running_entry =
          running_entry
          |> Map.put(:issue, issue)
          |> Map.put(:paused_reason, :ci_wait)

        transition_control_status(state, running_entry, :paused, "ci_wait")

      _ ->
        state
    end
  end

  @doc false
  @spec terminate_running_issue(State.t(), String.t(), boolean()) :: State.t()
  def terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        # `terminate_task/1` brutally kills the runner task, skipping the
        # `after stop_session` cleanup — kill the tracked REPL pane + pid
        # here so neither orphans on abort/terminal-state teardown.
        kill_repl_session(running_entry)

        if cleanup_workspace do
          cleanup_terminal_issue_artifacts(identifier, worker_host)
        end

        # Close any open chat-completion SSE streams BEFORE killing the
        # task. `terminate_task/1` brutally kills the AgentRunner,
        # bypassing the normal `close_aiur_turn_streams` path; without
        # the explicit close the bridge streams stay subscribed at the
        # old `aiur_turn_id` and miss every event the next-dispatched
        # agent emits. The operator sees an empty chat pane until the
        # 10-minute watchdog fires.
        close_active_chat_streams(identifier, terminate_reason(cleanup_workspace))

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  # Mirrors `terminate_running_issue/3`'s task-teardown half (kill the
  # codex pid, demonitor the ref) but KEEPS the entry in `state.running`
  # with `control.status: :deactivated` and `pid: nil`. The row stays
  # visible in the AgentList at 🏁 / 100% green while the slot is freed.
  # Idempotent — re-running on an already-deactivated entry is a no-op.
  #
  # Mutates the entry directly via `put_in/2` rather than calling
  # `put_running_control_status/3`, whose guard whitelist only accepts
  # `[:paused, :working]` (it gates pause/resume control messages, which
  # `:deactivated` is not).
  defp deactivate_running_issue(%State{} = state, issue_id) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      %{control: %{status: :deactivated}} ->
        # Already deactivated — observed the same label again.
        state

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        Logger.info("Issue deactivated (human-review): issue_id=#{issue_id} identifier=#{identifier}; keeping running entry, freeing slot")

        # Close any open chat-completion SSE streams for this identifier
        # BEFORE killing the task. `terminate_task/1` brutally kills the
        # AgentRunner, bypassing the normal `close_aiur_turn_streams`
        # path — without an explicit close, the bridge streams stay
        # subscribed for 10 minutes, hit their watchdog, and dump
        # duplicate "No turn activity in 10 minutes" system messages
        # into the chat pane (one per pre-warm slot).
        close_active_chat_streams(identifier, :deactivated)

        # Same brutal-kill gap as terminate_running_issue: reach the
        # tracked REPL pane + pid before the runner task dies.
        kill_repl_session(running_entry)

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        existing_control = Map.get(running_entry, :control, %{})

        new_entry =
          running_entry
          |> Map.put(:pid, nil)
          |> Map.put(:ref, nil)
          |> Map.put(:control, Map.put(existing_control, :status, :deactivated))

        new_state = %{
          state
          | running: Map.put(state.running, issue_id, new_entry),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

        # Drop the id from the publisher's tracked set so in-flight events
        # from the just-killed codex task don't pass the gate and overwrite
        # the synthetic 100 bar sample U4 seeds.
        refresh_tracked_set(new_state)
    end
  end

  @doc false
  @spec reconcile_pending_auto_resumes(State.t()) :: State.t()
  def reconcile_pending_auto_resumes(%State{} = state) do
    PushRouting.reconcile_pending_auto_resumes(state)
  end

  # Safety check-in, not a kill: pause any agent that has been actively
  # running longer than `agent.max_agent_duration_minutes` (paused/blocked
  # time excluded via `running_seconds/2`). The duration cap is almost
  # always "I want to check in," not "this work is done" — pausing keeps
  # the agent in the list, holding its slot and its session/turn context,
  # so the operator can review and resume with one keystroke instead of
  # restarting from scratch.
  @doc false
  @spec reconcile_overrunning_agents(State.t()) :: State.t()
  def reconcile_overrunning_agents(%State{} = state) do
    max_seconds = Config.max_agent_duration_minutes() * 60

    cond do
      max_seconds <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_pause_overrunning_entry(state_acc, issue_id, running_entry, now, max_seconds)
        end)
    end
  end

  # True when an entry has exceeded the duration cap: actively running
  # (not paused/deactivated) past `max_seconds`. Paused entries are
  # excluded so a duration-paused agent is never re-paused on the next
  # tick (its `running_seconds` is frozen while paused, but the guard
  # makes the intent explicit).
  @doc false
  @spec overrunning_entry?(map(), DateTime.t(), non_neg_integer()) :: boolean()
  def overrunning_entry?(running_entry, now, max_seconds) when is_map(running_entry) do
    not paused_running_entry?(running_entry) and
      not deactivated_running_entry?(running_entry) and
      running_seconds(Map.get(running_entry, :started_at), now) > max_seconds
  end

  # Mirror the operator-pause path: queue the cooperative `{:pause_agent}`
  # control message so the worker parks at its next turn boundary, then
  # flip control status to `:paused`. Stamping `paused_reason` makes the
  # pause attributable to the duration cap (distinct from a manual or
  # blocker pause), and reusing the `:paused` state means slot accounting
  # (`paused_running_count`/`available_slots`) and the resume paths treat
  # it identically to a manual pause for free.
  defp maybe_pause_overrunning_entry(state, issue_id, running_entry, now, max_seconds) do
    if overrunning_entry?(running_entry, now, max_seconds) do
      identifier = Map.get(running_entry, :identifier, issue_id)
      seconds = running_seconds(Map.get(running_entry, :started_at), now)

      Logger.warning("orchestrator.pause issue_id=#{issue_id} issue_identifier=#{identifier} cause=max_agent_duration running_seconds=#{seconds} cap_seconds=#{max_seconds}")

      _ = send_pause_control_message(state, identifier)

      paused_entry = Map.put(running_entry, :paused_reason, :max_agent_duration)
      transition_control_status(state, paused_entry, :paused, "max_agent_duration")
    else
      state
    end
  end

  defp maybe_auto_resume_spurious_worker_pause(state, %{paused_reason: reason} = running_entry, :paused)
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
      if(Map.has_key?(pause_payload, :request_id), do: :pause_containment, else: :worker_pause_unknown)
  end

  defp maybe_put_worker_pause_reason(entry, :paused, pause_reason), do: Map.put(entry, :paused_reason, pause_reason)
  defp maybe_put_worker_pause_reason(entry, _status, _pause_reason), do: entry

  defp maybe_log_worker_pause(:paused, running_entry, pause_reason) do
    Logger.warning(
      "orchestrator.pause issue_id=#{get_in(running_entry, [:issue, Access.key(:id)])} issue_identifier=#{Map.get(running_entry, :identifier)} cause=#{pause_reason} source=worker_control_state"
    )
  end

  defp maybe_log_worker_pause(_status, _running_entry, _pause_reason), do: :ok

  @doc false
  @spec reconcile_stalled_running_issues(State.t()) :: State.t()
  def reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.agent_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    cond do
      # Runaway safety net: a duration-capped pause asked the worker to
      # park cooperatively at its next turn boundary, but a truly wedged
      # agent (single never-ending codex turn) never reaches one, so it
      # keeps streaming past the pause. Such an entry would otherwise sit
      # `:paused` forever — the duration cap can never re-fire (paused
      # entries are excluded) and the operator's resume never comes. Once
      # it has been wedged past the grace window, force-terminate it. This
      # is the only place a duration cap escalates to a kill; a cooperative
      # park stops the codex stream and is left alone.
      wedged_overcap_entry?(running_entry, now, timeout_ms) ->
        terminate_wedged_overcap_entry(state, issue_id, running_entry, now)

      # Paused agents are INTENTIONALLY idle — the agent emitted
      # pause.request because it declared a blocker and has nothing to
      # do until the blocker emits. The stall watchdog must not
      # interpret deliberate idleness as a stuck codex stream. The
      # auto-resume hook in handle_info({:event, ...}) will reawaken
      # the entry when its blocker pushes; if no push ever arrives, an
      # operator-driven resume (label flip or chat) is the path
      # forward, not a restart that throws away the agent's workpad.
      paused_running_entry?(running_entry) ->
        state

      # Deactivated entries don't have a live codex stream to stall on
      # in the first place — the worker task was killed when the entry
      # was deactivated. Skip them; the reactivate path is the only
      # transition back to :working.
      deactivated_running_entry?(running_entry) ->
        state

      true ->
        maybe_restart_stalled_entry(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  # True when a duration-capped paused entry is WEDGED rather than parked:
  # it kept streaming codex after the cooperative `{:pause_agent}` was sent
  # (so `last_codex_timestamp` is newer than `paused_at`) and has stayed
  # that way longer than the grace window (`timeout_ms`, the stall budget).
  # A cooperatively-parked agent stops streaming at its turn boundary, so
  # its `last_codex_timestamp` does not advance past `paused_at` — those
  # are left to the operator/blocker resume, never killed here.
  @doc false
  @spec wedged_overcap_entry?(map(), DateTime.t(), non_neg_integer()) :: boolean()
  def wedged_overcap_entry?(running_entry, now, timeout_ms) when is_map(running_entry) do
    with true <- paused_running_entry?(running_entry),
         :max_agent_duration <- Map.get(running_entry, :paused_reason),
         %DateTime{} = paused_at <- Map.get(running_entry, :paused_at),
         %DateTime{} = last_codex <- Map.get(running_entry, :last_codex_timestamp) do
      # Streamed after we asked it to park -> never honored the park.
      still_streaming? = DateTime.compare(last_codex, paused_at) == :gt
      grace_elapsed? = DateTime.diff(now, paused_at, :millisecond) > timeout_ms

      still_streaming? and grace_elapsed?
    else
      _ -> false
    end
  end

  def wedged_overcap_entry?(_running_entry, _now, _timeout_ms), do: false

  defp terminate_wedged_overcap_entry(state, issue_id, running_entry, now) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    wedged_for_ms = DateTime.diff(now, Map.get(running_entry, :paused_at), :millisecond)

    Logger.warning("Wedged over-cap agent escalated to terminate: issue_id=#{issue_id} issue_identifier=#{identifier} wedged_ms=#{wedged_for_ms}; never parked after max_agent_duration pause")

    terminate_running_issue(state, issue_id, false)
  end

  defp maybe_restart_stalled_entry(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  @doc false
  @spec terminate_task(term()) :: :ok
  def terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(Aiur.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :kill)
    end
  end

  def terminate_task(_pid), do: :ok

  defp sync_polled_issue_state(state, issues), do: IssueSync.sync_polled_issue_state(state, issues)

  defp sort_issues_for_dispatch(issues), do: DispatchPolicy.sort_issues_for_dispatch(issues)
  defp should_dispatch_issue?(issue, state, active_states, terminal_states), do: DispatchPolicy.should_dispatch_issue?(issue, state, active_states, terminal_states)
  defp dispatch_candidate?(issue, state, active_states, terminal_states), do: DispatchPolicy.dispatch_candidate?(issue, state, active_states, terminal_states)
  defp candidate_issue?(issue, active_states, terminal_states), do: DispatchPolicy.candidate_issue?(issue, active_states, terminal_states)
  defp todo_issue_blocked_by_non_terminal?(issue, terminal_states), do: DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  defp normalize_issue_state(state_name), do: DispatchPolicy.normalize_issue_state(state_name)
  defp state_slug(state_name), do: DispatchPolicy.state_slug(state_name)
  defp terminal_state_set, do: DispatchPolicy.terminal_state_set()
  defp active_state_set, do: DispatchPolicy.active_state_set()

  # Reconciler wrappers
  defp reconcile_running_lifecycle(state), do: Reconciler.reconcile_running_lifecycle(state)
  defp refresh_running_issue_states(state), do: Reconciler.refresh_running_issue_states(state)
  defp reconcile_running_issue_states(issues, state, active_states, terminal_states), do: Reconciler.reconcile_running_issue_states(issues, state, active_states, terminal_states)
  defp maybe_reactivate_or_refresh(state, issue), do: Reconciler.maybe_reactivate_or_refresh(state, issue)
  defp refresh_running_issue_state(state, issue), do: Reconciler.refresh_running_issue_state(state, issue)

  # Dispatcher wrappers
  defp choose_issues(state, issues), do: Dispatcher.choose_issues(state, issues)
  defp check_thrash_budget(state, issue_id, now_ms), do: Dispatcher.check_thrash_budget(state, issue_id, now_ms)
  defp revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states), do: Dispatcher.revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states)

  # RetryEngine wrappers
  defp complete_issue(state, issue_id), do: RetryEngine.complete_issue(state, issue_id)
  defp schedule_issue_retry(state, issue_id, attempt, metadata), do: RetryEngine.schedule_issue_retry(state, issue_id, attempt, metadata)
  defp next_retry_attempt_from_running(running_entry), do: RetryEngine.next_retry_attempt_from_running(running_entry)
  defp pop_retry_attempt_state(state, issue_id, retry_token), do: RetryEngine.pop_retry_attempt_state(state, issue_id, retry_token)
  defp handle_retry_issue(state, issue_id, attempt, metadata), do: RetryEngine.handle_retry_issue(state, issue_id, attempt, metadata)
  defp release_issue_claim(state, issue_id), do: RetryEngine.release_issue_claim(state, issue_id)
  defp format_retry_preflight_error(reason), do: RetryEngine.format_retry_preflight_error(reason)

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  @doc false
  @spec cleanup_terminal_issue_artifacts(binary() | term(), binary() | nil) :: :ok
  def cleanup_terminal_issue_artifacts(identifier, worker_host \\ nil)

  def cleanup_terminal_issue_artifacts(identifier, worker_host) when is_binary(identifier) do
    cleanup_issue_workspace(identifier, worker_host)
    clear_session_handle(identifier)
  end

  @doc false
  @spec clear_session_handle(binary() | term()) :: :ok
  def clear_session_handle(identifier) when is_binary(identifier), do: SessionHandle.clear(identifier)
  def clear_session_handle(_identifier), do: :ok

  defp run_startup_todo_workspace_cleanup(%State{} = state) do
    case ensure_terminal_workspace_cleanup_preflight(state) do
      {:ok, state} ->
        cleanup_todo_workspaces_after_preflight(state)

      {:skip, reason, state} ->
        Logger.debug("Skipping startup todo workspace cleanup: #{format_retry_preflight_error(reason)}")

        state

      {:error, reason, state} ->
        Logger.warning("Skipping startup todo workspace cleanup: #{format_retry_preflight_error(reason)}")

        state
    end
  end

  defp cleanup_todo_workspaces_after_preflight(%State{} = state) do
    case Tracker.fetch_issues_by_states(configured_todo_states(), quiet_auth_errors?: true) do
      {:ok, issues} ->
        issues
        |> Enum.filter(&todo_issue_for_startup_cleanup?/1)
        |> Enum.each(&cleanup_issue_workspace_for_issue/1)

        state

      {:error, reason} ->
        Logger.debug("Skipping startup todo workspace cleanup; failed to fetch todo issues: #{inspect(reason)}")

        state
    end
  end

  defp configured_todo_states do
    Config.settings!().tracker.active_states
    |> Enum.filter(&(state_slug(&1) == "todo"))
    |> case do
      [] -> ["todo"]
      states -> states
    end
  end

  defp todo_issue_for_startup_cleanup?(%Issue{state: state}) do
    state_slug(state) == "todo"
  end

  defp todo_issue_for_startup_cleanup?(_issue), do: false

  defp run_terminal_workspace_cleanup(%State{} = state) do
    case ensure_terminal_workspace_cleanup_preflight(state) do
      {:ok, state} ->
        cleanup_terminal_workspaces_after_preflight(state)

      {:skip, reason, state} ->
        Logger.debug("Skipping startup terminal workspace cleanup: #{format_retry_preflight_error(reason)}")

        state

      {:error, reason, state} ->
        Logger.warning("Skipping startup terminal workspace cleanup: #{format_retry_preflight_error(reason)}")

        state
    end
  end

  defp ensure_terminal_workspace_cleanup_preflight(%State{} = state) do
    case ensure_tracker_preflight(state) do
      {:error, reason, state}
      when reason in [:missing_linear_api_token, :missing_linear_project_slug] ->
        {:skip, reason, state}

      result ->
        result
    end
  end

  defp cleanup_terminal_workspaces_after_preflight(%State{} = state) do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states,
           quiet_auth_errors?: true
         ) do
      {:ok, issues} ->
        Enum.each(issues, &cleanup_terminal_issue_workspace/1)
        state

      {:error, reason} ->
        log_terminal_workspace_cleanup_fetch_skip(reason)

        state
    end
  end

  defp log_terminal_workspace_cleanup_fetch_skip(reason)
       when reason in [:missing_linear_api_token, :missing_linear_project_slug] do
    Logger.debug("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
  end

  defp log_terminal_workspace_cleanup_fetch_skip({:linear_api_status, 401} = reason) do
    Logger.debug("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
  end

  defp log_terminal_workspace_cleanup_fetch_skip({:linear_api_request, :missing_linear_api_token} = reason) do
    Logger.debug("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
  end

  defp log_terminal_workspace_cleanup_fetch_skip(reason) do
    Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
  end

  defp cleanup_terminal_issue_workspace(%Issue{identifier: identifier})
       when is_binary(identifier),
       do: cleanup_terminal_issue_artifacts(identifier)

  defp cleanup_terminal_issue_workspace(_issue), do: :ok

  defp cleanup_issue_workspace_for_issue(%Issue{identifier: identifier})
       when is_binary(identifier),
       do: cleanup_issue_workspace(identifier)

  defp cleanup_issue_workspace_for_issue(_issue), do: :ok

  defp notify_dashboard(state) do
    state
    |> running_summaries()
    |> AgentPubSub.broadcast_running_change()

    AgentPubSub.broadcast_poll_state(%{
      checking?: state.poll_check_in_progress == true,
      next_poll_due_at_ms: state.next_poll_due_at_ms,
      max_concurrent_agents: max_concurrent_agent_limit(state)
    })

    ObservabilityPubSub.broadcast_update()
  end

  defp running_summaries(state) do
    now = DateTime.utc_now()

    running_by_identifier =
      Map.new(state.running, fn {_id, entry} -> {Map.get(entry, :identifier), entry} end)

    polled_summaries =
      state.last_polled_issues
      |> Map.values()
      |> Enum.map(fn issue ->
        identifier = Map.get(issue, :identifier) || ""
        tag = issue_tag(issue)
        title = Map.get(issue, :title)

        case Map.get(running_by_identifier, identifier) do
          nil ->
            # Has an `agent:*` label but no Aiur slot is running it.
            AgentEvents.agent_summary(identifier, :queued, 0, %{
              tag: tag,
              title: title,
              work_state: idle_issue_work_state(issue),
              pause_reason: idle_issue_pause_reason(issue)
            })

          entry ->
            AgentEvents.agent_summary(identifier, :running, 0, %{
              tag: tag,
              title: title,
              runtime_seconds: effective_runtime_seconds(entry, now),
              turn_count: Map.get(entry, :turn_count, 0),
              work_state: get_in(entry, [:control, :status]) || :working,
              pause_reason: Map.get(entry, :paused_reason),
              backend: entry_backend(entry),
              model: entry_model(entry),
              remote_control: remote_control_summary(entry)
            })
        end
      end)

    polled_identifiers = MapSet.new(polled_summaries, fn s -> s.identifier end)

    # Cover the narrow race where an agent is mid-dispatch and the
    # tracker poll hasn't refreshed yet — those issues live in
    # `state.running` but not in `last_polled_issues`.
    extra_running =
      state.running
      |> Enum.flat_map(fn {_id, entry} ->
        identifier = Map.get(entry, :identifier) || ""

        if identifier == "" or MapSet.member?(polled_identifiers, identifier) do
          []
        else
          [
            AgentEvents.agent_summary(identifier, :running, 0, %{
              tag: issue_tag(Map.get(entry, :issue)),
              title: get_in(entry, [:issue, Access.key(:title)]),
              runtime_seconds: effective_runtime_seconds(entry, now),
              turn_count: Map.get(entry, :turn_count, 0),
              work_state: get_in(entry, [:control, :status]) || :working,
              pause_reason: Map.get(entry, :paused_reason),
              backend: entry_backend(entry),
              model: entry_model(entry),
              remote_control: remote_control_summary(entry)
            })
          ]
        end
      end)

    (polled_summaries ++ extra_running)
    |> Enum.reject(fn %{identifier: id} -> id == "" end)
  end

  # Resolved backend string for a running entry, so the agent list can name
  # the agent's own engine in its placeholder rather than guessing. nil when
  # the entry carries no issue; agent_summary drops the nil.
  defp entry_backend(entry) do
    case Map.get(entry, :issue) do
      %Issue{} = issue -> CodingAgent.backend_for(issue)
      _ -> nil
    end
  end

  # Pinned model variant for a running entry (e.g. "opus-4-8", "gpt-5.5"),
  # so the agent list can render the model column's version suffix. nil when
  # the entry carries no issue or the model is unpinned (backend default);
  # agent_summary drops the nil and the renderer falls back to the base name.
  defp entry_model(entry) do
    case Map.get(entry, :issue) do
      %Issue{} = issue -> CodingAgent.model_for(issue)
      _ -> nil
    end
  end

  # Highest `complexity:N` label on the issue (nil when unlabelled). Reused by
  # the status rows so `aiur watch` can render the cx column without a tracker
  # round-trip — the issue is already in memory.
  defp issue_complexity(%Issue{} = issue), do: CodingAgent.complexity_level(issue)

  defp agent_statuses(%State{} = state) do
    now = DateTime.utc_now()

    running_by_identifier =
      Map.new(state.running, fn {_id, entry} -> {Map.get(entry, :identifier), entry} end)

    (running_statuses(state, now) ++ idle_statuses(state, running_by_identifier))
    |> Enum.sort_by(fn status -> to_string(status.identifier || status.issue_id || "") end)
  end

  defp running_statuses(%State{} = state, %DateTime{} = now) do
    Enum.map(state.running, fn {issue_id, entry} ->
      running_status(state, issue_id, entry, now)
    end)
  end

  defp running_status(%State{} = state, issue_id, entry, now) do
    identifier = Map.get(entry, :identifier) || issue_id
    issue = Map.get(entry, :issue)
    work_state = get_in(entry, [:control, :status]) || :working

    %{
      issue_id: issue_id,
      identifier: identifier,
      state: if(work_state == :paused, do: :paused, else: :running),
      work_state: work_state,
      tracker_state: Map.get(issue, :state),
      tracker_paused: Issue.paused?(issue),
      tag: issue_tag(issue),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      runtime_seconds: running_seconds(Map.get(entry, :started_at), now),
      queue_depth: queue_depth_for_issue(state, identifier),
      complexity: issue_complexity(issue),
      last_codex_timestamp: Map.get(entry, :last_codex_timestamp),
      last_codex_message: Map.get(entry, :last_codex_message),
      last_codex_event: Map.get(entry, :last_codex_event)
    }
  end

  defp idle_statuses(%State{} = state, running_by_identifier) do
    state.last_polled_issues
    |> Map.values()
    |> Enum.reject(&running_issue?(&1, running_by_identifier))
    |> Enum.map(&idle_status(state, &1))
  end

  defp running_issue?(issue, running_by_identifier) do
    identifier = Map.get(issue, :identifier)
    is_binary(identifier) and Map.has_key?(running_by_identifier, identifier)
  end

  defp idle_status(%State{} = state, issue) do
    identifier = Map.get(issue, :identifier) || Map.get(issue, :id)

    %{
      issue_id: Map.get(issue, :id),
      identifier: identifier,
      state: :idle,
      tracker_state: Map.get(issue, :state),
      tracker_paused: Issue.paused?(issue),
      tag: issue_tag(issue),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      runtime_seconds: 0,
      queue_depth: idle_queue_depth(state, identifier),
      complexity: issue_complexity(issue),
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil
    }
  end

  defp idle_queue_depth(%State{} = state, identifier) when is_binary(identifier) do
    queue_depth_for_issue(state, identifier)
  end

  defp idle_queue_depth(_state, _identifier), do: 0

  defp idle_issue_work_state(%Issue{} = issue) do
    if Issue.paused?(issue), do: :paused, else: :idle
  end

  defp idle_issue_work_state(_issue), do: :idle

  defp idle_issue_pause_reason(%Issue{} = issue) do
    if Issue.paused?(issue), do: :label_override, else: nil
  end

  defp idle_issue_pause_reason(_issue), do: nil

  defp maybe_put_runtime_value(running_entry, key, value), do: State.maybe_put_runtime_value(running_entry, key, value)

  defp select_worker_host(state, preferred_worker_host), do: Slots.select_worker_host(state, preferred_worker_host)
  defp worker_slots_available?(state, preferred_worker_host), do: Slots.worker_slots_available?(state, preferred_worker_host)

  defp find_issue_id_for_ref(running, ref), do: State.find_issue_id_for_ref(running, ref)
  defp running_entry_session_id(running_entry), do: State.running_entry_session_id(running_entry)
  defp issue_context(issue), do: State.issue_context(issue)
  defp active_running_count(running), do: State.active_running_count(running)
  defp paused_running_count(running), do: State.paused_running_count(running)
  defp active_running_entry?(entry), do: State.active_running_entry?(entry)
  defp paused_running_entry?(entry), do: State.paused_running_entry?(entry)
  defp deactivated_running_entry?(entry), do: State.deactivated_running_entry?(entry)

  defp launch_max_concurrent_agents_override, do: Slots.launch_max_concurrent_agents_override()

  # Shared body for the adjust/set cap handlers. Lowering below the active
  # count is allowed: existing work keeps running, while available_slots/1
  # blocks new dispatch until active+paused drops below the new cap.
  defp apply_session_max_concurrent_agents(%State{} = state, next) when is_integer(next) do
    state = %{state | session_max_concurrent_agents: next}
    notify_dashboard(state)
    {:reply, {:ok, max_concurrent_agent_status(state)}, state}
  end

  defp max_concurrent_agent_limit(state), do: Slots.max_concurrent_agent_limit(state)
  defp max_concurrent_agent_status(state), do: Slots.max_concurrent_agent_status(state)
  defp available_slots(state), do: Slots.available_slots(state)

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec send_operator_message(String.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(issue_identifier, payload) do
    send_operator_message(__MODULE__, issue_identifier, payload)
  end

  @spec send_operator_message(GenServer.server(), String.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(server, issue_identifier, payload) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:send_operator_message, issue_identifier, payload}, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @spec pause_agent(String.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(issue_identifier), do: pause_agent(__MODULE__, issue_identifier)

  @spec pause_agent(GenServer.server(), String.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(server, issue_identifier) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:pause_agent, issue_identifier}, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Mark a running agent as `:sleeping` (💤) because its chat-completion
  stream idle-closed after the watchdog inactivity window. Fire-and-forget
  cast from the opencode bridge — non-blocking for the closing stream, and
  safe to call when no orchestrator is registered (the cast is dropped).
  Only a `:working` entry sleeps; a `:paused`/`:deactivated` entry keeps
  its more-specific state.
  """
  @spec mark_sleeping(String.t()) :: :ok
  def mark_sleeping(issue_identifier), do: mark_sleeping(__MODULE__, issue_identifier)

  @spec mark_sleeping(GenServer.server(), String.t()) :: :ok
  def mark_sleeping(server, issue_identifier) when is_binary(issue_identifier) do
    GenServer.cast(server, {:mark_sleeping, issue_identifier})
  end

  @spec interrupt_agent(String.t()) :: :ok | {:error, term()}
  def interrupt_agent(issue_identifier), do: interrupt_agent(__MODULE__, issue_identifier)

  @spec interrupt_agent(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def interrupt_agent(server, issue_identifier) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:interrupt_agent, issue_identifier}, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @spec pane_interrupt(String.t()) ::
          {:ok, :interrupted | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt(issue_identifier), do: pane_interrupt(__MODULE__, issue_identifier)

  @spec pane_interrupt(GenServer.server(), String.t()) ::
          {:ok, :interrupted | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt(server, issue_identifier) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:pane_interrupt, issue_identifier}, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Ctrl+C entry point keyed on a tmux pane id instead of the issue. A
  claude-repl/RC pane is not an opencode slot, so the opencode SlotRegistry
  can't resolve it — this maps the pane back to its running entry via
  `repl_pane_id` and routes through the same 3-state decision as
  `pane_interrupt/1`.
  """
  @spec pane_interrupt_by_pane_id(String.t()) ::
          {:ok, :interrupted | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt_by_pane_id(pane_id), do: pane_interrupt_by_pane_id(__MODULE__, pane_id)

  @spec pane_interrupt_by_pane_id(GenServer.server(), String.t()) ::
          {:ok, :interrupted | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt_by_pane_id(server, pane_id) when is_binary(pane_id) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:pane_interrupt_by_pane_id, pane_id}, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @spec resume_agent(String.t()) :: {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(issue_identifier), do: resume_agent(__MODULE__, issue_identifier)

  @spec resume_agent(GenServer.server(), String.t()) ::
          {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(server, issue_identifier) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:resume_agent, issue_identifier}, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @spec max_concurrent_agents() :: map() | :unavailable
  def max_concurrent_agents, do: max_concurrent_agents(__MODULE__)

  @spec max_concurrent_agents(GenServer.server()) :: map() | :unavailable
  def max_concurrent_agents(server) do
    if GenServer.whereis(server) do
      GenServer.call(server, :max_concurrent_agents, 5_000)
    else
      :unavailable
    end
  catch
    :exit, _ -> :unavailable
  end

  @spec adjust_max_concurrent_agents(integer()) :: {:ok, map()} | {:error, term()}
  def adjust_max_concurrent_agents(delta), do: adjust_max_concurrent_agents(__MODULE__, delta)

  @spec adjust_max_concurrent_agents(GenServer.server(), integer()) ::
          {:ok, map()} | {:error, term()}
  def adjust_max_concurrent_agents(server, delta) when is_integer(delta) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:adjust_max_concurrent_agents, delta}, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Set the concurrent-agent cap to an absolute value at runtime (the
  `aiur set max-agents N` control), without editing `.aiur/config`.
  May be set below the number of currently-active agents. Existing work
  keeps running, and new dispatch is held until active agents drain below
  the new cap.

  Session-scoped like `adjust_max_concurrent_agents/1`: it lives in
  orchestrator state, so a `--max-agents` launch override (or the config
  default) re-seeds the cap if the orchestrator process restarts.
  """
  @spec set_max_concurrent_agents(pos_integer()) :: {:ok, map()} | {:error, term()}
  def set_max_concurrent_agents(n), do: set_max_concurrent_agents(__MODULE__, n)

  @spec set_max_concurrent_agents(GenServer.server(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def set_max_concurrent_agents(server, n) when is_integer(n) and n > 0 do
    if GenServer.whereis(server) do
      GenServer.call(server, {:set_max_concurrent_agents, n}, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @spec control_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def control_capabilities(issue_identifier),
    do: control_capabilities(__MODULE__, issue_identifier)

  @spec control_capabilities(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def control_capabilities(server, issue_identifier) when is_binary(issue_identifier) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:control_capabilities, issue_identifier}, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @spec set_remote_control(String.t(), boolean()) :: {:ok, :on | :off} | {:error, term()}
  def set_remote_control(issue_identifier, on?),
    do: set_remote_control(__MODULE__, issue_identifier, on?)

  @spec set_remote_control(GenServer.server(), String.t(), boolean()) ::
          {:ok, :on | :off} | {:error, term()}
  def set_remote_control(server, issue_identifier, on?)
      when is_binary(issue_identifier) and is_boolean(on?) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:set_remote_control, issue_identifier, on?}, 10_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Pre-seed the workspace trust flag for a remote-control dispatch.

  RC refuses to start in an untrusted directory, so an RC-labeled issue
  dispatched directly (not via the `r` key) must seed `hasTrustDialogAccepted`
  before its REPL spawns — otherwise the REPL sticks on the trust dialog and
  degrades to the headless backend. The runner computes RC-ness from a
  concurrent task, so it routes through this serialized call (the trust
  read-modify-write on `~/.claude.json` must not race a parallel dispatch).
  """
  @spec ensure_remote_control_trust(Path.t()) :: :ok | {:error, term()}
  def ensure_remote_control_trust(workspace),
    do: ensure_remote_control_trust(__MODULE__, workspace)

  @spec ensure_remote_control_trust(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def ensure_remote_control_trust(server, workspace) when is_binary(workspace) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:ensure_remote_control_trust, workspace}, 10_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @spec claim_next_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_queue_item(server, issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(server, {:claim_next_queue_item, issue_identifier}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec claim_next_checkpoint_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_checkpoint_queue_item(server, issue_identifier)
      when is_binary(issue_identifier) do
    GenServer.call(server, {:claim_next_checkpoint_queue_item, issue_identifier}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Mid-turn drain: claim ONLY events_digest queue items whose events include at
  least one blocker-critical topic from a direct blocker of `issue_identifier`.
  Used by `Aiur.AgentRunner.safe_checkpoint_handler/2` to drain blocker-
  critical events into the running turn as `<aiur:events urgent="true">`
  before falling back to the regular operator-message queue.
  """
  @spec claim_blocker_critical_events_digest(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_blocker_critical_events_digest(server, issue_identifier)
      when is_binary(issue_identifier) do
    GenServer.call(server, {:claim_blocker_critical_events_digest, issue_identifier}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec claim_next_operator_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_operator_queue_item(server, issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(server, {:claim_next_operator_queue_item, issue_identifier}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  @spec claim_next_queue_item_for_test(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_queue_item_for_test(server, issue_identifier) when is_binary(issue_identifier) do
    claim_next_queue_item(server, issue_identifier)
  end

  @spec mark_queue_item_consumed(GenServer.server(), integer()) :: :ok | {:error, term()}
  def mark_queue_item_consumed(server, item_id) when is_integer(item_id) do
    GenServer.call(server, {:mark_queue_item_consumed, item_id}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec restore_queue_item_pending(GenServer.server(), integer()) :: :ok | {:error, term()}
  def restore_queue_item_pending(server, item_id) when is_integer(item_id) do
    GenServer.call(server, {:restore_queue_item_pending, item_id}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  @spec mark_queue_item_consumed_for_test(GenServer.server(), integer()) :: :ok | {:error, term()}
  def mark_queue_item_consumed_for_test(server, item_id) when is_integer(item_id) do
    mark_queue_item_consumed(server, item_id)
  end

  @spec mark_queue_item_failed(GenServer.server(), integer(), term()) :: :ok | {:error, term()}
  def mark_queue_item_failed(server, item_id, reason) when is_integer(item_id) do
    GenServer.call(server, {:mark_queue_item_failed, item_id, reason}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec consume_delivered_queue_items(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def consume_delivered_queue_items(server, issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(server, {:consume_delivered_queue_items, issue_identifier}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec restore_delivered_queue_items(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def restore_delivered_queue_items(server, issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(server, {:restore_delivered_queue_items, issue_identifier}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec fail_delivered_queue_items(GenServer.server(), String.t(), term()) ::
          :ok | {:error, term()}
  def fail_delivered_queue_items(server, issue_identifier, reason)
      when is_binary(issue_identifier) do
    GenServer.call(server, {:fail_delivered_queue_items, issue_identifier, reason}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  @spec mark_queue_item_failed_for_test(GenServer.server(), integer(), term()) ::
          :ok | {:error, term()}
  def mark_queue_item_failed_for_test(server, item_id, reason) when is_integer(item_id) do
    mark_queue_item_failed(server, item_id, reason)
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @doc """
  Returns the identifiers Aiur currently knows are running. Used by
  `Aiur.Opencode.WarmServer` at boot-time GC to decide which leftover
  opencode sessions belong to live agents vs ungraceful prior exits.
  """
  @spec list_active_identifiers(GenServer.server(), timeout()) :: [String.t()]
  def list_active_identifiers(server \\ __MODULE__, timeout \\ 1_000) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :list_active_identifiers, timeout)
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  @doc """
  Returns identifiers whose running entry is currently "active" —
  not paused, not deactivated. Used by `Aiur.ProgressCheckin.Worker`
  so the 5-min check-in publishes only to agents that should be
  making progress; pausing/deactivation already signal "don't work".
  """
  @spec list_running_active_identifiers(GenServer.server(), timeout()) :: [String.t()]
  def list_running_active_identifiers(server \\ __MODULE__, timeout \\ 1_000) do
    if alive?(server) do
      try do
        GenServer.call(server, :list_running_active_identifiers, timeout)
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp alive?({:via, _, _}), do: true
  defp alive?({:global, _}), do: true
  defp alive?(_), do: false

  @doc """
  Lightweight read of the polling clock so UI surfaces (the agent-list
  pane) can render a "Next refresh: Ns" countdown without doing a full
  `snapshot/0` every tick. Returns `%{checking?: boolean, next_poll_in_ms: integer | nil}`,
  or `:unavailable` if the orchestrator isn't running.
  """
  @spec poll_status() :: %{checking?: boolean(), next_poll_in_ms: integer() | nil} | :unavailable
  def poll_status, do: poll_status(__MODULE__, 1_000)

  @spec poll_status(GenServer.server(), timeout()) ::
          %{checking?: boolean(), next_poll_in_ms: integer() | nil} | :unavailable
  def poll_status(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :poll_status, timeout)
      catch
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @spec status() :: [map()] | :timeout | :unavailable
  def status, do: status(__MODULE__, 5_000)

  @spec status(GenServer.server(), timeout()) :: [map()] | :timeout | :unavailable
  def status(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :status, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call({:enqueue_event_digest, identifier, event}, _from, state) do
    {:reply, :ok, enqueue_event_digest_item(state, identifier, [event], event)}
  end

  # Bootstrap-digest batched enqueue: one queue item carries every
  # missed event, so a long-offline agent's bootstrap doesn't fan out
  # into N serial GenServer.calls through the orchestrator mailbox.
  # The drain-time coalesce path still folds this digest with any
  # other events_digest items that arrive between enqueue and drain.
  def handle_call({:enqueue_event_digest_batch, identifier, events}, _from, state)
      when is_binary(identifier) and is_list(events) do
    {:reply, :ok, enqueue_event_digest_item(state, identifier, events, %{events: events})}
  end

  def handle_call(:poll_status, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    reply = %{
      checking?: state.poll_check_in_progress == true,
      next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms)
    }

    {:reply, reply, state}
  end

  def handle_call(:list_active_identifiers, _from, state) do
    identifiers =
      state.running
      |> Map.values()
      |> Enum.map(fn entry -> entry[:identifier] || Map.get(entry, :identifier) end)
      |> Enum.reject(&is_nil/1)

    {:reply, identifiers, state}
  end

  def handle_call(:list_running_active_identifiers, _from, state) do
    identifiers =
      state.running
      |> Map.values()
      |> Enum.filter(&active_running_entry?/1)
      |> Enum.map(fn entry -> entry[:identifier] || Map.get(entry, :identifier) end)
      |> Enum.reject(&is_nil/1)

    {:reply, identifiers, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, agent_statuses(state), state}
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        capabilities = issue_control_capabilities(state, metadata.identifier)

        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          tag: issue_tag(metadata.issue),
          title: Map.get(metadata.issue, :title),
          url: Map.get(metadata.issue, :url),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          agent_input_tokens: metadata.agent_input_tokens,
          agent_output_tokens: metadata.agent_output_tokens,
          agent_total_tokens: metadata.agent_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          work_state: get_in(metadata, [:control, :status]) || :working,
          pause_reason: Map.get(metadata, :paused_reason),
          tracker_paused: Issue.paused?(metadata.issue),
          queue_depth: capabilities.queue_depth,
          pending_operator_messages: pending_operator_messages_for_issue(state, metadata.identifier),
          control: capabilities,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       agent_totals: state.agent_totals,
       rate_limits: Map.get(state, :agent_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call(
        {:send_operator_message, issue_identifier, %{kind: :text, body: body} = payload},
        _from,
        state
      )
      when is_binary(issue_identifier) and is_binary(body) do
    {reply, next_state} = enqueue_operator_message(state, issue_identifier, body, payload)
    {:reply, reply, next_state}
  end

  def handle_call({:send_operator_message, _issue_identifier, _payload}, _from, state) do
    {:reply, {:error, :invalid_message}, state}
  end

  def handle_call({:control_capabilities, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {:reply, {:ok, issue_control_capabilities(state, issue_identifier)}, state}
  end

  def handle_call({:pause_agent, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {reply, state} = pause_agent_reply(state, issue_identifier)
    {:reply, reply, state}
  end

  def handle_call({:pause_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:interrupt_agent, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {:reply, interrupt_agent_reply(state, issue_identifier), state}
  end

  def handle_call({:interrupt_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:pane_interrupt, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {reply, state} = pane_interrupt_reply(state, issue_identifier)
    {:reply, reply, state}
  end

  def handle_call({:pane_interrupt, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:pane_interrupt_by_pane_id, pane_id}, _from, state) when is_binary(pane_id) do
    case find_running_by_repl_pane_id(state.running, pane_id) do
      %{identifier: identifier} ->
        {reply, state} = pane_interrupt_reply(state, to_string(identifier))
        {:reply, reply, state}

      nil ->
        {:reply, {:error, :no_pane_agent}, state}
    end
  end

  def handle_call({:resume_agent, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {reply, state} = resume_issue(state, issue_identifier)
    notify_dashboard(state)
    {:reply, reply, state}
  end

  def handle_call({:resume_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:set_remote_control, issue_identifier, on?}, _from, state)
      when is_binary(issue_identifier) and is_boolean(on?) do
    {reply, state} = set_remote_control_reply(state, issue_identifier, on?)
    notify_dashboard(state)
    {:reply, reply, state}
  end

  def handle_call({:set_remote_control, _issue_identifier, _on?}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:ensure_remote_control_trust, workspace}, _from, state)
      when is_binary(workspace) do
    {:reply, RemoteControl.ensure_workspace_trusted(workspace, remote_control_trust_opts()), state}
  end

  def handle_call(:max_concurrent_agents, _from, state) do
    {:reply, max_concurrent_agent_status(state), state}
  end

  def handle_call({:adjust_max_concurrent_agents, delta}, _from, state) when is_integer(delta) do
    next = max(max_concurrent_agent_limit(state) + delta, 1)
    apply_session_max_concurrent_agents(state, next)
  end

  def handle_call({:set_max_concurrent_agents, n}, _from, state) when is_integer(n) and n > 0 do
    apply_session_max_concurrent_agents(state, n)
  end

  def handle_call({:claim_next_queue_item, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {queue_store, item} =
      AgentQueueStore.claim_next_deliverable(state.queue_store, issue_identifier)

    {queue_store, item} =
      case item do
        %{category: :coordination_event, event_type: :events_digest} ->
          coalesce_events_digests(queue_store, issue_identifier, item)

        other ->
          {queue_store, other}
      end

    state = %{state | queue_store: queue_store}

    reply =
      case item do
        nil -> :empty
        _ -> {:ok, item}
      end

    {:reply, reply, state}
  end

  # Drain-time coalescing: pending `:events_digest` items for the same
  # identifier fold into a single delivery, so an agent that had three
  # events subscribed during a long turn sees ONE `<aiur:events>` block,
  # not three separate ones. Granularity is preserved upstream (one
  # queue item per publish so `[event:consumed]` markers and cursor
  # advance still reflect individual events); coalescing happens only
  # at the drain boundary.
  def handle_call({:claim_next_checkpoint_queue_item, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {queue_store, item} =
      AgentQueueStore.claim_next_deliverable_matching(
        state.queue_store,
        issue_identifier,
        fn item -> item.delivery[:interrupt_requested] != true end
      )

    state = %{state | queue_store: queue_store}

    reply =
      case item do
        nil -> :empty
        _ -> {:ok, item}
      end

    {:reply, reply, state}
  end

  # Mid-turn drain: claim ONLY events_digest queue items whose events include
  # at least one blocker-critical topic from a direct blocker of
  # `issue_identifier`. Delivered mid-turn at safe checkpoints; everything
  # else continues to drain at turn boundary via the regular claim path.
  def handle_call({:claim_blocker_critical_events_digest, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    direct_blockers = direct_blockers_for(state, issue_identifier)

    {queue_store, item} =
      AgentQueueStore.claim_next_deliverable_matching(
        state.queue_store,
        issue_identifier,
        fn item -> blocker_critical_digest?(item, direct_blockers) end
      )

    state = %{state | queue_store: queue_store}

    reply =
      case item do
        nil -> :empty
        item -> {:ok, item}
      end

    {:reply, reply, state}
  end

  def handle_call({:claim_next_operator_queue_item, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {queue_store, item} =
      AgentQueueStore.claim_next_deliverable_matching(
        state.queue_store,
        issue_identifier,
        &match?(%{category: :operator_message}, &1)
      )

    state = %{state | queue_store: queue_store}

    reply =
      case item do
        nil -> :empty
        _ -> {:ok, item}
      end

    {:reply, reply, state}
  end

  def handle_call({:mark_queue_item_consumed, item_id}, _from, state) when is_integer(item_id) do
    {queue_store, _item} = AgentQueueStore.mark_consumed(state.queue_store, item_id)
    {:reply, :ok, %{state | queue_store: queue_store}}
  end

  def handle_call({:restore_queue_item_pending, item_id}, _from, state)
      when is_integer(item_id) do
    {queue_store, _item} = AgentQueueStore.restore_pending(state.queue_store, item_id)
    {:reply, :ok, %{state | queue_store: queue_store}}
  end

  def handle_call({:mark_queue_item_failed, item_id, reason}, _from, state)
      when is_integer(item_id) do
    {queue_store, _item} = AgentQueueStore.mark_failed(state.queue_store, item_id, reason)
    {:reply, :ok, %{state | queue_store: queue_store}}
  end

  def handle_call({:consume_delivered_queue_items, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {queue_store, _items} = AgentQueueStore.consume_delivered(state.queue_store, issue_identifier)
    {:reply, :ok, %{state | queue_store: queue_store}}
  end

  def handle_call({:restore_delivered_queue_items, issue_identifier}, _from, state)
      when is_binary(issue_identifier) do
    {queue_store, _items} = AgentQueueStore.restore_delivered(state.queue_store, issue_identifier)
    {:reply, :ok, %{state | queue_store: queue_store}}
  end

  def handle_call({:fail_delivered_queue_items, issue_identifier, reason}, _from, state)
      when is_binary(issue_identifier) do
    {queue_store, _items} =
      AgentQueueStore.fail_delivered(state.queue_store, issue_identifier, reason)

    {:reply, :ok, %{state | queue_store: queue_store}}
  end

  @doc false
  @spec enqueue_event_digest_item(State.t(), String.t(), list(), map()) :: State.t()
  def enqueue_event_digest_item(state, identifier, events, summary_source),
    do: OM.enqueue_event_digest_item(state, identifier, events, summary_source)

  defp enqueue_operator_message(state, issue_identifier, body, payload),
    do: OM.enqueue_operator_message(state, issue_identifier, body, payload)

  defp maybe_emit_agent_control_alert(previous_status, status, running_entry),
    do: OM.maybe_emit_agent_control_alert(previous_status, status, running_entry)

  defp resume_issue(%State{} = state, issue_identifier), do: PauseResume.resume_issue(state, issue_identifier)
  @doc false
  @spec reactivate_issue(State.t(), map()) :: {{:ok, :reactivated} | {:error, term()}, State.t()}
  def reactivate_issue(%State{} = state, running_entry), do: PauseResume.reactivate_issue(state, running_entry)
  defp pause_agent_reply(state, issue_identifier), do: PauseResume.pause_agent_reply(state, issue_identifier)
  @doc false
  @spec send_pause_control_message(State.t(), String.t()) :: term()
  def send_pause_control_message(state, issue_identifier), do: PauseResume.send_pause_control_message(state, issue_identifier)
  defp interrupt_agent_reply(state, issue_identifier), do: Interrupts.interrupt_agent_reply(state, issue_identifier)
  defp pane_interrupt_reply(state, issue_identifier), do: Interrupts.pane_interrupt_reply(state, issue_identifier)
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

  # --- Agent liveness from claude hooks -------------------------------------
  #
  # An RC-claude agent works via lifecycle hooks (`Aiur.Claude.HookEvents`),
  # which never produce a codex update — so the stall watchdog's
  # `last_codex_timestamp` would sit at `started_at` while the agent is busy
  # and `reconcile_stalled_running_issues` would kill a working agent every
  # `stall_timeout_ms`. Each hook is proof of life (the same signal
  # `await_hook_turn` rides for turn detection), so refresh the entry's
  # activity timestamp on every hook.
  @doc "Refresh an agent's liveness timestamp on claude-hook activity (fire-and-forget)."
  @spec note_agent_activity(GenServer.server(), String.t()) :: :ok
  def note_agent_activity(server \\ __MODULE__, identifier) when is_binary(identifier) do
    GenServer.cast(server, {:note_agent_activity, identifier})
  end

  @doc false
  @spec note_agent_activity_state(State.t(), String.t()) :: State.t()
  def note_agent_activity_state(%State{} = state, identifier) when is_binary(identifier) do
    case find_running_key_by_identifier(state.running, identifier) do
      nil ->
        state

      issue_id ->
        update_in(state.running, &PauseResume.reset_last_codex_timestamp(&1, issue_id, DateTime.utc_now()))
    end
  end

  @impl true
  def handle_cast({:note_agent_activity, identifier}, state) do
    {:noreply, note_agent_activity_state(state, identifier)}
  end

  @impl true
  def handle_cast({:mark_sleeping, identifier}, state) when is_binary(identifier) do
    {:noreply, maybe_mark_sleeping(state, identifier)}
  end

  defp find_running_key_by_identifier(running, identifier), do: State.find_running_key_by_identifier(running, identifier)
  defp apply_pause_runtime_clock(entry, previous, next, now), do: State.apply_pause_runtime_clock(entry, previous, next, now)

  defp queue_depth_for_issue(state, id), do: OM.queue_depth_for_issue(state, id)

  defp pending_operator_messages_for_issue(state, id), do: OM.pending_operator_messages_for_issue(state, id)

  defp issue_control_capabilities(state, id), do: OM.issue_control_capabilities(state, id)

  defp set_remote_control_reply(state, id, on?), do: RC.set_remote_control_reply(state, id, on?)

  defp remote_control_trust_opts, do: RC.remote_control_trust_opts()
  # Kill the persistent-REPL pane + claude OS pid tracked on the running
  # entry. Idempotent and tolerant of a half-dead session (pane gone but
  # pid alive, or vice versa) — each kill is independent and a missing
  # pane/pid is a no-op.
  @doc false
  @spec kill_repl_session(map()) :: :ok
  def kill_repl_session(running_entry) do
    pane_id = Map.get(running_entry, :repl_pane_id)
    os_pid = Map.get(running_entry, :repl_os_pid)

    if is_binary(pane_id), do: Aiur.Tmux.kill_pane(pane_id)

    # The REPL pane's `exec claude` can spawn tool/MCP children that would
    # orphan and keep working on a single-pid kill, so reap the subtree.
    RemoteControl.graceful_kill_tree(os_pid)

    # The headless fallback has no pane; its `bash -lc` wrapper leaves
    # claude/node grandchildren that reparent to init, so reap the subtree.
    RemoteControl.graceful_kill_tree(Map.get(running_entry, :headless_os_pid))

    :ok
  end

  defp remote_control_summary(entry), do: RC.remote_control_summary(entry)
  defp cleanup_stray_remote_control_servers, do: RC.cleanup_stray_remote_control_servers()
  defp issue_tag(issue), do: State.issue_tag(issue)
  defp find_running_by_repl_pane_id(running, pane_id), do: State.find_running_by_repl_pane_id(running, pane_id)

  defp integrate_codex_update(running_entry, %{event: _, timestamp: _} = update),
    do: TokenAccounting.integrate_codex_update(running_entry, update)

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  @doc false
  @spec schedule_poll_cycle_start() :: :ok
  def schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id), do: State.pop_running_entry(state, issue_id)

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry),
    do: TokenAccounting.record_session_completion_totals(state, running_entry)

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_seconds * 1_000,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp sync_todo_capacity_alert(state, issues), do: IssueSync.sync_todo_capacity_alert(state, issues)
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
  def retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(issue, state), do: Slots.dispatch_slots_available?(issue, state)

  defp apply_agent_token_delta(
         %{agent_totals: _agent_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total),
       do: TokenAccounting.apply_agent_token_delta(state, token_delta)

  defp apply_agent_token_delta(state, _token_delta), do: state

  defp apply_agent_rate_limits(%State{} = state, update) when is_map(update),
    do: TokenAccounting.apply_agent_rate_limits(state, update)

  defp apply_agent_rate_limits(state, _update), do: state
  defp running_seconds(started_at, now), do: State.running_seconds(started_at, now)
  defp effective_runtime_seconds(entry, now), do: State.effective_runtime_seconds(entry, now)

  # Test seam — exposed so unit tests can exercise the coalescing pipeline
  # without spinning up the full orchestrator GenServer + supervision tree.
  @doc false
  @spec coalesce_for_test(AgentQueueStore.t(), String.t()) ::
          {AgentQueueStore.t(), AgentQueueItem.t() | nil}
  def coalesce_for_test(queue_store, issue_identifier) when is_binary(issue_identifier) do
    {queue_store, item} = AgentQueueStore.claim_next_deliverable(queue_store, issue_identifier)

    case item do
      %{category: :coordination_event, event_type: :events_digest} ->
        coalesce_events_digests(queue_store, issue_identifier, item)

      other ->
        {queue_store, other}
    end
  end

  defp coalesce_events_digests(queue_store, issue_identifier, first_item),
    do: DigestCoalescer.coalesce_events_digests(queue_store, issue_identifier, first_item)

  @spec subscribe_for_declared_blocker(String.t() | integer(), String.t() | integer()) :: :ok
  def subscribe_for_declared_blocker(blockee_identifier, blocker_identifier),
    do: AutoSubscriptions.subscribe_for_declared_blocker(blockee_identifier, blocker_identifier)

  defp direct_blockers_for(state, identifier), do: AutoSubscriptions.direct_blockers_for(state, identifier)

  defp blocker_critical_digest?(item, direct_blockers),
    do: AutoSubscriptions.blocker_critical_digest?(item, direct_blockers)
end
