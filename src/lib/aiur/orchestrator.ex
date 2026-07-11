defmodule Aiur.Orchestrator do
  @moduledoc """
  Polls the issue tracker and dispatches repository copies to agent-backed workers.
  """

  use GenServer
  require Logger

  alias Aiur.{
    AgentQueueItem,
    AgentQueueStore,
    Alerts,
    CIApprovalStore,
    Config,
    Issue,
    RepoBase,
    Tracker
  }

  alias Aiur.Claude.RemoteControl

  alias Aiur.Events.{
    Exchange,
    GithubCIPoller,
    Publisher,
    UniversalSubscriptions
  }

  alias Aiur.Orchestrator.{
    AgentTeardown,
    AutoSubscriptions,
    CiLifecycle,
    CommandScan,
    CommentPolling,
    CommentWake,
    DigestCoalescer,
    Dispatcher,
    DispatchPolicy,
    EventTopics,
    HumanReview,
    Interrupts,
    IssueSync,
    PauseResume,
    PrAnchored,
    PushRouting,
    Reconciler,
    RetryEngine,
    RuntimeWatchdog,
    Slots,
    State,
    StatusReport,
    TokenAccounting,
    TrackedSet,
    TrackerHealth,
    WorkspaceCleanup
  }

  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.RemoteControlMode, as: RC

  # Slightly above the dashboard render interval so the `0s` in-progress
  # label can render before the poll finishes.
  @poll_transition_render_delay_ms 20
  @ci_wait_state "ci-wait"
  @human_review_state "human-review"
  @ci_poll_states [@ci_wait_state, @human_review_state]
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
    PauseResume.handle_worker_control_state(state, issue_id, status, %{})
  end

  def handle_info({:worker_control_state, issue_id, :paused, pause_payload}, state)
      when is_binary(issue_id) and is_map(pause_payload) do
    PauseResume.handle_worker_control_state(state, issue_id, :paused, pause_payload)
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
  def transition_control_status(state, running_entry, new_status, reason),
    do: PauseResume.transition_control_status(state, running_entry, new_status, reason)

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

  defp ci_target_for_issue(issue), do: CiLifecycle.ci_target_for_issue(issue)

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

  defp transition_ci_ticket(state, issue, next_state),
    do: CiLifecycle.transition_ci_ticket(state, issue, next_state)

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

  defp clear_ci_approved_head(state, issue),
    do: CiLifecycle.clear_ci_approved_head(state, issue)

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

  defp persist_ci_lifecycle_state(state),
    do: CiLifecycle.persist_ci_lifecycle_state(state)

  defp publish_ci_terminal_event(state, issue, result, outcome),
    do: CiLifecycle.publish_ci_terminal_event(state, issue, result, outcome)

  defp ensure_ci_failure_subscription(state, issue) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        :ok = UniversalSubscriptions.attach(target)
        state

      _ ->
        state
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
        issues = recover_startup_pause_overrides(state, issues)

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
    recover_startup_pause_overrides(state, issues)
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
    Reconciler.refresh_running_entry_issue(state, issue, running_entry)
  end

  @doc false
  @spec pause_issue_for_ci_wait(State.t(), Issue.t()) :: State.t()
  def pause_issue_for_ci_wait(state, issue),
    do: CiLifecycle.pause_issue_for_ci_wait(state, issue)

  @doc false
  @spec reconcile_pending_auto_resumes(State.t()) :: State.t()
  def reconcile_pending_auto_resumes(%State{} = state) do
    PushRouting.reconcile_pending_auto_resumes(state)
  end

  # Final-wave extraction wrappers.
  defp notify_dashboard(state), do: StatusReport.notify_dashboard(state)
  defp agent_statuses(state), do: StatusReport.agent_statuses(state)
  defp next_poll_in_ms(due_at, now_ms), do: StatusReport.next_poll_in_ms(due_at, now_ms)

  defp run_terminal_workspace_cleanup(state), do: WorkspaceCleanup.run_terminal_workspace_cleanup(state)
  defp run_startup_todo_workspace_cleanup(state), do: WorkspaceCleanup.run_startup_todo_workspace_cleanup(state)

  @doc false
  @spec cleanup_terminal_issue_artifacts(binary() | term(), binary() | nil) :: :ok
  def cleanup_terminal_issue_artifacts(identifier, worker_host \\ nil), do: WorkspaceCleanup.cleanup_terminal_issue_artifacts(identifier, worker_host)

  @doc false
  @spec clear_session_handle(binary() | term()) :: :ok
  def clear_session_handle(identifier), do: WorkspaceCleanup.clear_session_handle(identifier)

  @doc false
  @spec human_review_state?(term()) :: boolean()
  def human_review_state?(state_name), do: HumanReview.human_review_state?(state_name)

  @doc false
  @spec maybe_deactivate_human_review_issue(State.t(), Issue.t()) :: State.t()
  def maybe_deactivate_human_review_issue(state, issue), do: HumanReview.maybe_deactivate_human_review_issue(state, issue)

  @doc false
  @spec terminate_running_issue(State.t(), String.t(), boolean()) :: State.t()
  def terminate_running_issue(state, issue_id, cleanup_workspace), do: AgentTeardown.terminate_running_issue(state, issue_id, cleanup_workspace)

  @doc false
  @spec kill_repl_session(map()) :: :ok
  def kill_repl_session(entry), do: AgentTeardown.kill_repl_session(entry)

  @doc false
  @spec close_active_chat_streams(String.t() | term(), term()) :: :ok
  def close_active_chat_streams(identifier, reason), do: AgentTeardown.close_active_chat_streams(identifier, reason)

  @doc false
  @spec terminate_task(term()) :: :ok
  def terminate_task(pid), do: AgentTeardown.terminate_task(pid)

  @doc false
  @spec reconcile_overrunning_agents(State.t()) :: State.t()
  def reconcile_overrunning_agents(state), do: RuntimeWatchdog.reconcile_overrunning_agents(state)

  @doc false
  @spec reconcile_stalled_running_issues(State.t()) :: State.t()
  def reconcile_stalled_running_issues(state), do: RuntimeWatchdog.reconcile_stalled_running_issues(state)

  @doc false
  @spec overrunning_entry?(map(), DateTime.t(), non_neg_integer()) :: boolean()
  def overrunning_entry?(entry, now, max_seconds), do: RuntimeWatchdog.overrunning_entry?(entry, now, max_seconds)

  defp restart_stalled_issue(state, issue_id, entry, now, timeout_ms), do: RuntimeWatchdog.restart_stalled_issue(state, issue_id, entry, now, timeout_ms)
  defp maybe_pause_overrunning_entry(state, issue_id, entry, now, max_seconds), do: RuntimeWatchdog.maybe_pause_overrunning_entry(state, issue_id, entry, now, max_seconds)

  defp sync_polled_issue_state(state, issues), do: IssueSync.sync_polled_issue_state(state, issues)

  defp sort_issues_for_dispatch(issues), do: DispatchPolicy.sort_issues_for_dispatch(issues)
  defp should_dispatch_issue?(issue, state, active_states, terminal_states), do: DispatchPolicy.should_dispatch_issue?(issue, state, active_states, terminal_states)
  defp dispatch_candidate?(issue, state, active_states, terminal_states), do: DispatchPolicy.dispatch_candidate?(issue, state, active_states, terminal_states)
  defp candidate_issue?(issue, active_states, terminal_states), do: DispatchPolicy.candidate_issue?(issue, active_states, terminal_states)
  defp todo_issue_blocked_by_non_terminal?(issue, terminal_states), do: DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  defp normalize_issue_state(state_name), do: DispatchPolicy.normalize_issue_state(state_name)
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

  defp maybe_put_runtime_value(running_entry, key, value), do: State.maybe_put_runtime_value(running_entry, key, value)

  defp select_worker_host(state, preferred_worker_host), do: Slots.select_worker_host(state, preferred_worker_host)
  defp worker_slots_available?(state, preferred_worker_host), do: Slots.worker_slots_available?(state, preferred_worker_host)

  defp find_issue_id_for_ref(running, ref), do: State.find_issue_id_for_ref(running, ref)
  defp running_entry_session_id(running_entry), do: State.running_entry_session_id(running_entry)
  defp issue_context(issue), do: State.issue_context(issue)
  defp active_running_count(running), do: State.active_running_count(running)
  defp paused_running_count(running), do: State.paused_running_count(running)
  defp active_running_entry?(entry), do: State.active_running_entry?(entry)

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

  defp resume_issue(%State{} = state, issue_identifier), do: PauseResume.resume_issue(state, issue_identifier)

  # `agent:paused` is a durable override. A successful in-memory resume that
  # leaves it behind is undone by the next tracker poll, stranding the worker.
  # Clear the override before waking the worker and keep it parked if the
  # tracker write fails.
  @doc false
  @spec resume_label_overridden_issue(State.t(), map()) :: {{:ok, :resumed} | {:error, term()}, State.t()}
  def resume_label_overridden_issue(%State{} = state, %{paused_reason: :label_override} = running_entry) do
    case clear_pause_override(running_entry) do
      {:ok, cleared_entry} ->
        issue_id = get_in(cleared_entry, [:issue, Access.key(:id)])
        state = %{state | running: Map.put(state.running, issue_id, cleared_entry)}
        resume_paused_issue(state, cleared_entry)

      {:error, reason} ->
        Logger.warning("Pause override clear failed: #{rc_log_context(running_entry)} reason=#{inspect(reason)}")
        {{:error, {:pause_override_clear_failed, reason}}, state}
    end
  end

  def resume_label_overridden_issue(%State{} = state, running_entry), do: resume_paused_issue(state, running_entry)

  defp recover_startup_pause_overrides(%State{initial_dispatch_cycle: true} = state, issues) when is_list(issues) do
    Enum.map(issues, fn
      %Issue{} = issue -> recover_startup_pause_override(state, issue)
      issue -> issue
    end)
  end

  defp recover_startup_pause_overrides(_state, issues), do: issues

  defp recover_startup_pause_override(%State{} = state, %Issue{} = issue) do
    if Issue.paused?(issue) and DispatchPolicy.active_issue_state?(issue.state, active_state_set()) and not Map.has_key?(state.running, issue.id) do
      case clear_pause_override(issue) do
        {:ok, cleared_issue} ->
          Logger.info("Recovered stale pause override on startup: #{issue_context(issue)}")
          cleared_issue

        {:error, reason} ->
          Logger.warning("Startup pause override recovery deferred: #{issue_context(issue)} reason=#{inspect(reason)}")
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
      :ok -> {:ok, issue |> RC.remove_issue_label(label) |> Map.put(:paused, false)}
      {:error, _reason} = error -> error
    end
  end

  defp pause_override_label, do: "#{Config.settings!().tracker.github.label_prefix}:paused"

  defp rc_log_context(entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{Map.get(entry, :identifier)}"
  end

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
  defp pending_operator_messages_for_issue(state, id), do: OM.pending_operator_messages_for_issue(state, id)

  defp issue_control_capabilities(state, id), do: OM.issue_control_capabilities(state, id)

  defp set_remote_control_reply(state, id, on?), do: RC.set_remote_control_reply(state, id, on?)

  defp remote_control_trust_opts, do: RC.remote_control_trust_opts()
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
