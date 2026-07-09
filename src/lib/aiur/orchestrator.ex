defmodule Aiur.Orchestrator do
  @moduledoc """
  Polls the issue tracker and dispatches repository copies to agent-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias Aiur.{
    AgentEvents,
    AgentPubSub,
    AgentQueue,
    AgentQueueItem,
    AgentQueueStore,
    Alerts,
    CodingAgent,
    Config,
    Issue,
    RepoBase,
    SessionHandle,
    Tracker,
    Workspace
  }

  alias Aiur.Claude.{RemoteControl, ReplAgent}

  alias Aiur.Events.{
    Exchange,
    GithubCommentsPoller,
    GithubFirehose,
    GithubKeys,
    PrCommandScanner,
    Publisher,
    Sanitizer,
    SubscriptionStore,
    UniversalSubscriptions
  }

  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Connectivity, as: GitHubConnectivity
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, EventTopics, Reconciler, RetryEngine, Slots, State, TrackedSet}
  alias AiurWeb.ObservabilityPubSub

  @comment_rework_retry_delay_ms 2_000
  @comment_rework_max_attempts 5
  # Slightly above the dashboard render interval so the `0s` in-progress
  # label can render before the poll finishes.
  @poll_transition_render_delay_ms 20
  @human_review_state "human-review"
  @merging_state "merging"
  # Non-active review states whose idle tickets the comment listener still polls
  # so a trusted reviewer comment promotes them to `rework`, independent of the
  # configured `active_states`. `human-review` is the primary review stage;
  # `merging` covers a last-minute "actually, change this" before the merge lands
  # (and keeps coverage in configs where `merging` is not an active state).
  @comment_poll_review_states [@human_review_state, @merging_state]
  # Sentinel state for synthetic PR-anchored work units (watched/commanded human
  # PRs). Deliberately NOT a tracker active/terminal state: a PR-anchored unit is
  # dispatched directly (slot-capped) and never flows through reconcile/label
  # transitions that key on configured states.
  @pr_anchored_state "pr-watch"
  @human_review_comment_targets_per_poll 25
  @watch_comment_targets_per_poll 25
  @command_scan_pull_requests_per_poll 25
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
  @max_operator_message_chars 8_000

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

    state = %State{
      poll_interval_ms: config.polling.interval_seconds * 1_000,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      # `--max-agents N` at launch: seed the session override (highest
      # precedence; `refresh_runtime_config/1` never clobbers it) so the cap
      # holds without editing `.aiur/config`.
      session_max_concurrent_agents: launch_max_concurrent_agents_override(),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      initial_dispatch_cycle: true,
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
  defp refresh_tracked_set(state) do
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

  def handle_info({:worker_control_state, issue_id, status}, %{running: running} = state)
      when is_binary(issue_id) and status in [:paused, :working] do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        previous_status = get_in(running_entry, [:control, :status]) || :working

        updated_running_entry =
          running_entry
          |> put_in([:control, :status], status)
          |> apply_pause_runtime_clock(previous_status, status, DateTime.utc_now())

        maybe_emit_agent_control_alert(previous_status, status, updated_running_entry)

        state = %{state | running: Map.put(running, issue_id, updated_running_entry)}
        notify_dashboard(state)
        {:noreply, state}
    end
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
  defp parse_pause_request_topic(topic), do: EventTopics.parse_pause_request_topic(topic)
  defp parse_branch_push_topic(topic), do: EventTopics.parse_branch_push_topic(topic)
  defp parse_system_branch_push_topic(topic), do: EventTopics.parse_system_branch_push_topic(topic)
  defp classify_event_topic(topic), do: EventTopics.classify_event_topic(topic)

  defp maybe_reactivate_on_comment(%State{} = state, issue_number, source, event, attempt \\ 1) do
    case find_running_by_identifier(state.running, issue_number) do
      # An already-running entry (PR-anchored or legacy) resumes its SAME
      # session — a follow-up comment on a PR-anchored agent's PR resolves here
      # (identifier == to_string(pr#)) and never re-dispatches.
      running_entry when is_map(running_entry) ->
        reactivate_if_deactivated(state, running_entry, issue_number, source, event)

      _ ->
        maybe_route_pr_anchored_or_legacy(state, issue_number, source, event, attempt)
    end
  end

  # Routing fork for a comment with no running entry. Before the legacy
  # `agent:rework` transition, intercept a watched/commanded HUMAN PR and route
  # it PR-anchored instead — but ONLY when `pr_watch` is enabled. When disabled,
  # behave exactly as before: no `/pulls/N` fetch, legacy path byte-for-byte.
  #
  # Safety by construction: `issue_number` is the comment topic key. A legacy
  # ticket's key is a tracker issue number → `GET /pulls/N` 404s → `{:ok, nil}`
  # → legacy. A watched human PR → `{:ok, pr}` with a non-`aiur/<N>` head →
  # PR-anchored. An `aiur/<N>`-headed PR (a legacy aiur PR) → legacy. The
  # PR-anchored path NEVER touches an `agent:` label or opens a new `aiur/<N>` PR.
  defp maybe_route_pr_anchored_or_legacy(%State{} = state, issue_number, source, event, attempt) do
    if pr_anchored_routing_enabled?() and trusted_comment_event?(event) and
         not benign_review_pass_comment?(event) do
      case resolve_pr_anchored_unit(issue_number, event) do
        {:ok, %Issue{} = pr_issue} ->
          dispatch_pr_anchored_unit(state, pr_issue, source, event)

        :legacy ->
          maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt)
      end
    else
      maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt)
    end
  end

  defp pr_anchored_routing_enabled? do
    Config.tracker_kind() == "github" and Aiur.GitHub.Config.pr_watch_enabled?()
  end

  # Resolve the comment's PR number `N` to a PR-anchored work unit, or `:legacy`.
  # `:legacy` is the safe fall-through for: a plain issue (`/pulls/N` 404 → nil),
  # a closed/merged PR (nil), a legacy `aiur/<N>`-headed aiur PR, a fetch error,
  # or a non-integer key. The fetcher is injectable for tests via the event.
  defp resolve_pr_anchored_unit(issue_number, event) do
    with {:ok, pr_number} <- pr_number_from_identifier(issue_number),
         {:ok, %{} = pr} <- fetch_open_pull_request_for_routing(pr_number, event),
         head_ref when is_binary(head_ref) and head_ref != "" <- pr_head_ref(pr),
         false <- aiur_owned_head_ref?(head_ref, pr_number) do
      {:ok, build_pr_anchored_issue(pr_number, pr, head_ref)}
    else
      _ -> :legacy
    end
  end

  defp pr_number_from_identifier(issue_number) do
    case Integer.parse(to_string(issue_number)) do
      {pr_number, ""} when pr_number > 0 -> {:ok, pr_number}
      _ -> :error
    end
  end

  defp fetch_open_pull_request_for_routing(pr_number, event) do
    fetcher =
      case Map.get(event, :open_pull_request_fetcher) do
        fun when is_function(fun, 1) -> fun
        _ -> fn number -> GitHubClient.fetch_open_pull_request(number) end
      end

    case fetcher.(pr_number) do
      {:ok, pr} when is_map(pr) -> {:ok, pr}
      {:ok, nil} -> :legacy
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_open_pull_request, other}}
    end
  end

  defp pr_head_ref(%{"head" => %{"ref" => ref}}) when is_binary(ref), do: ref
  defp pr_head_ref(_pr), do: nil

  # A PR whose head is `aiur/<N>` is a LEGACY aiur-created PR — its comments
  # must keep flowing through the unchanged `aiur/<id>` reactivation, never the
  # PR-anchored path. Only an external/human branch is PR-anchored.
  defp aiur_owned_head_ref?(head_ref, pr_number) do
    head_ref == "aiur/#{pr_number}"
  end

  # A synthetic, slot-respecting work unit for a watched/commanded human PR.
  # `id: nil` keeps it OUT of `revalidate_issue_for_dispatch/3`'s tracker lookup
  # (there is no tracker issue); `identifier: to_string(pr#)` is the comment
  # topic / resume key (`find_running_by_identifier`); `pr_head_ref` tells the
  # workspace to check out the human branch instead of creating `aiur/<id>`.
  defp build_pr_anchored_issue(pr_number, pr, head_ref) do
    %Issue{
      id: pr_anchored_running_key(pr_number),
      identifier: to_string(pr_number),
      title: pr_field(pr, "title") || "PR ##{pr_number}",
      description: pr_field(pr, "body") || "",
      state: @pr_anchored_state,
      branch_name: head_ref,
      pr_head_ref: head_ref,
      labels: []
    }
  end

  # The running-map key for a PR-anchored unit. Distinct from any tracker issue
  # id (prefixed `pr-`) so two PR-anchored agents never collide on a `nil` key
  # and a PR-anchored unit never shadows a same-numbered tracker ticket.
  defp pr_anchored_running_key(pr_number), do: "pr-#{pr_number}"

  defp pr_field(pr, key) do
    case Map.get(pr, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # Dispatch a PR-anchored unit through the slot-respecting worker path. We gate
  # on the global agent cap (`available_slots`) explicitly — `should_dispatch_issue?`
  # cannot be reused because its `candidate_issue?` requires a configured active
  # state, which a synthetic PR unit deliberately is not. Then route straight to
  # `do_dispatch_issue/4` (thrash budget + worker-slot dispatch), SKIPPING
  # `revalidate_issue_for_dispatch/3`: there is no tracker issue to revalidate, and
  # routing already proved the PR is open. When the cap is full or the unit is
  # already running/claimed, log and skip — the next comment re-triggers (no
  # `agent:` label is touched and no persistent state is written).
  defp dispatch_pr_anchored_unit(%State{} = state, %Issue{} = issue, source, event) do
    cond do
      Map.has_key?(state.running, issue.id) or MapSet.member?(state.claimed, issue.id) ->
        Logger.info("#{source} PR-anchored dispatch skipped; already running/claimed: pr=#{issue.identifier}")

        state

      available_slots(state) <= 0 ->
        Logger.info("#{source} PR-anchored dispatch deferred; agent cap full: pr=#{issue.identifier}")

        state

      true ->
        Logger.info("#{source} routed PR-anchored (no agent:* label, no aiur/<pr#> PR): pr=#{issue.identifier} head_ref=#{issue.pr_head_ref}")

        pr_anchored_dispatch_fun(event).(state, issue)
    end
  end

  # The terminal spawn for a PR-anchored unit. Defaults to the real
  # `do_dispatch_issue/4` (slot-respecting worker dispatch). Tests inject a
  # capture fun via the event so routing can be asserted without spawning a
  # real agent.
  defp pr_anchored_dispatch_fun(event) do
    case Map.get(event, :pr_anchored_dispatch_fun) do
      fun when is_function(fun, 2) -> fun
      _ -> fn state, issue -> do_dispatch_issue(state, issue, nil, nil) end
    end
  end

  # When an agent emits `agent.pause.request` it has decided to stop
  # working — usually because it declared a blocker and has nothing
  # left to do until the blocker emits. Flip the control status to
  # `:paused` AND queue a `{:pause_agent, _}` control message on the
  # task pid so the worker actually enters `wait_for_operator_message`.
  # Without the queued control message a pause.request fired
  # mid-tool-call would only flip the orchestrator's bookkeeping; the
  # later auto-resume `:resume_agent` would have no receiver because
  # the worker loop never paused. Symmetry with the operator-pause
  # path makes the resume side trivially correct.
  defp maybe_pause_on_request(%State{} = state, identifier) do
    case find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        existing_status =
          (Map.get(running_entry, :control) || %{}) |> Map.get(:status, :working)

        cond do
          existing_status == :paused ->
            state

          deactivated_running_entry?(running_entry) ->
            state

          true ->
            # Queue the pause control message; ignore the reply because
            # we're about to transition the entry's status optimistically
            # in `transition_control_status`. The worker confirmation
            # arrives later via `:worker_control_state :paused` and the
            # already-equal status short-circuit drops the duplicate
            # transition cleanly.
            _ = send_pause_control_message(state, identifier)
            transition_control_status(state, running_entry, :paused, "agent.pause.request")
        end

      _ ->
        state
    end
  end

  # The default branch advanced (a PR merged to the base branch). We do NOT
  # touch active agents: terminating every agent on each merge thrashed the
  # whole fleet and discarded each in-flight turn. Notification needs no work
  # here — every agent universally subscribes to `system.<base>.branch.push`
  # (`UniversalSubscriptions.topics/1`), so the same push that reaches the
  # orchestrator is independently delivered into each agent's event digest by
  # its own `SubscriptionStore`, through the exact `enqueue_event_digest_item/4`
  # -> `event_digest_delivery_opts/2` -> `queue_wake_required?/1` path the
  # comment fan-out uses. That path already encodes the desired per-state
  # behavior:
  #
  #   * `:working` mid-turn  -> queued, NON-interrupting; seen at the next turn
  #     boundary, the current turn continues uninterrupted.
  #   * `:sleeping` (standby) -> woken so it can pull main and resume. A sleeping
  #     entry already holds its slot, so the wake consumes no new capacity and
  #     dispatches no new agent.
  #   * `:paused` (manual operator/agent pause) -> queued but NOT woken; a manual
  #     pause is never woken by a main update.
  #
  # So there is nothing for the orchestrator to do but record the advance for
  # operators. Re-emitting a notice here would double-deliver, since the
  # orchestrator and every agent's SubscriptionStore both receive this push. The
  # agent-facing `using-aiur` skill tells the agent it may see this signal and to
  # pull/rebase at its own discretion.
  defp maybe_notify_agents_on_default_branch_push(%State{} = state, branch, event)
       when is_binary(branch) do
    if branch == default_branch_name() do
      sha = Map.get(event, :sha) || Map.get(event, "sha")

      Logger.info(
        "Default branch advanced; not terminating agents — each handles the push via its system.#{branch}.branch.push subscription (active turns continue uninterrupted, standby wakes): sha=#{sha || "-"}"
      )
    end

    state
  end

  defp maybe_notify_agents_on_default_branch_push(%State{} = state, _branch, _event),
    do: state

  defp default_branch_name do
    case Config.settings!() do
      %{tracker: %{base_branch: name}} when is_binary(name) and name != "" -> name
      _ -> "main"
    end
  end

  # A bridge chat-completion stream idle-closed (the inactivity watchdog
  # saw no transcript/event activity for its window). Flip a `:working`
  # entry to `:sleeping` so every surface paints 💤
  # (`AgentEvents.state_emoji/1`). A `:paused`/`:deactivated` entry keeps
  # its more-specific state — sleeping never overrides those. The agent's
  # slot is still held (`:sleeping` counts as active), and the next turn's
  # `:worker_control_state :working` transitions it back to 🟢.
  defp maybe_mark_sleeping(%State{} = state, identifier) do
    case find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        existing_status =
          (Map.get(running_entry, :control) || %{}) |> Map.get(:status, :working)

        if existing_status == :working do
          transition_control_status(state, running_entry, :sleeping, "stream.idle_close")
        else
          state
        end

      _ ->
        state
    end
  end

  # `ticket.<blocker>.branch.push` arrived. For every paused running
  # entry that has this exact topic in its SubscriptionStore.snapshot
  # (i.e. it declared this ticket as a blocker via
  # `aiur_declare_blocker`), flip control back to `:working` and
  # re-dispatch so the bootstrap digest delivers the push and the
  # agent picks up the unblock signal on its next turn.
  defp maybe_resume_blockees_on_push(%State{} = state, blocker_identifier, topic) do
    Enum.reduce(state.running, state, fn {_issue_id, entry}, acc ->
      cond do
        not is_map(entry) -> acc
        not paused_running_entry?(entry) -> acc
        deactivated_running_entry?(entry) -> acc
        true -> maybe_resume_for_topic(acc, entry, blocker_identifier, topic)
      end
    end)
  end

  defp maybe_resume_for_topic(state, entry, blocker_identifier, topic) do
    identifier = Map.get(entry, :identifier)

    cond do
      not is_binary(identifier) ->
        state

      identifier == blocker_identifier ->
        state

      subscribed_to_topic?(identifier, topic) ->
        attempt_auto_resume(state, entry, identifier, blocker_identifier, topic)

      true ->
        state
    end
  end

  # Resume can fail when the concurrent-agent cap is already full —
  # the blockee would otherwise sit silently paused forever because
  # the push event is consumed exactly once and the firehose / ls-remote
  # dedup table prevents a re-emit. Log a warning so operators can see
  # the cap is blocking the resume, and stamp a hint on the entry so a
  # future reconcile tick (when a slot opens up) can drain the queue.
  defp attempt_auto_resume(state, entry, identifier, blocker_identifier, topic) do
    Logger.info("Auto-resume on blocker push: blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}")

    # operator?: false — an automated blocker resume must preserve a
    # duration-capped agent's cumulative overrun (no fresh budget).
    case resume_paused_issue(state, entry, false) do
      {{:ok, :resumed}, next_state} ->
        next_state

      {{:error, :max_concurrent_agents_reached}, next_state} ->
        Logger.warning("Auto-resume deferred (cap full): blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}; entry remains paused with pending_auto_resume hint")

        stamp_pending_auto_resume(next_state, identifier, blocker_identifier, topic)

      {{:error, reason}, next_state} ->
        Logger.warning("Auto-resume failed: blockee=#{identifier} blocker=#{blocker_identifier} reason=#{inspect(reason)}")

        next_state
    end
  end

  # Record a `pending_auto_resume` marker on the running entry so a
  # future tick (`reconcile_pending_auto_resumes/1`) can retry once a
  # slot opens up. Without this the cap-full case loses the push
  # signal and the blockee stays paused forever.
  defp stamp_pending_auto_resume(state, identifier, blocker_identifier, topic) do
    case find_running_by_identifier(state.running, identifier) do
      running_entry when is_map(running_entry) ->
        issue_id = get_in(running_entry, [:issue, Access.key(:id)])

        hint = %{
          blocker_identifier: blocker_identifier,
          topic: topic,
          stamped_at: DateTime.utc_now()
        }

        updated_entry = Map.put(running_entry, :pending_auto_resume, hint)
        %{state | running: Map.put(state.running, issue_id, updated_entry)}

      _ ->
        state
    end
  end

  # `snapshot/1` is a synchronous GenServer.call to the per-identifier
  # store. The case clauses handle the documented contract; the rescue
  # only narrows to `:exit` (call timeout) so genuine bugs surface as
  # exceptions in tests instead of being silently swallowed.
  defp subscribed_to_topic?(identifier, topic) do
    case SubscriptionStore.snapshot(identifier) do
      %{subscribed_to: subs} when is_list(subs) ->
        Enum.any?(subs, fn
          %{"topic" => t} -> t == topic
          %{topic: t} -> t == topic
          _ -> false
        end)

      _ ->
        false
    end
  catch
    :exit, reason ->
      Logger.warning("subscribed_to_topic? store call failed: identifier=#{identifier} topic=#{topic} reason=#{inspect(reason)}")

      false
  end

  # Flip an entry's control.status. Used by `maybe_pause_on_request/2`
  # to record the agent-initiated pause without going through the
  # `pause_agent_reply -> send_running_control_message` path, which
  # is for operator-initiated pauses against a running agent loop.
  # The agent is already idle when we get here.
  #
  # Also stamps the pause-clock side-effect (`apply_pause_runtime_clock`)
  # so the runtime ticker freezes while paused — without it the
  # subsequent auto-resume in `maybe_resume_blockees_on_push` would
  # find no `paused_at` to thaw against, and the agent's running
  # clock would include the paused interval. Then notifies the
  # dashboard so the agent list reflects the new state without
  # waiting for the next poll tick.
  defp transition_control_status(state, running_entry, new_status, reason) do
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

  defp reactivate_if_deactivated(state, running_entry, issue_number, source, event) do
    if deactivated_running_entry?(running_entry) do
      transition_and_revalidate_comment_reactivation(
        state,
        running_entry,
        issue_number,
        source,
        event
      )
    else
      state
    end
  end

  defp maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt) do
    case transition_comment_issue_to_rework(issue_number, source, event) do
      :ok ->
        seed_idle_comment_wake_event(state, issue_number, event)

      {:skip, reason} ->
        Logger.info("#{source} ignored for idle issue: issue_identifier=#{issue_number} reason=#{inspect(reason)}")

        state

      {:error, reason} ->
        Logger.warning("#{source} rework transition skipped; state update failed: issue_identifier=#{issue_number} reason=#{inspect(reason)}")

        schedule_comment_rework_retry(state, issue_number, source, event, attempt, reason)
    end
  end

  defp schedule_comment_rework_retry(
         %State{} = state,
         issue_number,
         source,
         event,
         attempt,
         reason
       ) do
    max_attempts = comment_rework_max_attempts()

    if attempt >= max_attempts do
      Logger.warning("#{source} rework transition retry exhausted: issue_identifier=#{issue_number} attempts=#{attempt} reason=#{inspect(reason)}")
    else
      next_attempt = attempt + 1
      delay_ms = comment_rework_retry_delay_ms(attempt)

      Process.send_after(
        self(),
        {:retry_comment_rework, issue_number, source, event, next_attempt},
        delay_ms
      )

      Logger.info("#{source} rework transition retry scheduled: issue_identifier=#{issue_number} attempt=#{next_attempt}/#{max_attempts} delay_ms=#{delay_ms}")
    end

    state
  end

  defp seed_idle_comment_wake_event(%State{} = state, issue_number, event) do
    identifier = to_string(issue_number)

    UniversalSubscriptions.attach(identifier)

    state
    |> enqueue_event_digest_item(identifier, [event], event)
    |> dispatch_reworked_comment_issue(identifier)
  end

  defp dispatch_reworked_comment_issue(%State{} = state, identifier) when is_binary(identifier) do
    case fetch_comment_dispatch_issue(identifier) do
      {:ok, %Issue{} = issue} ->
        dispatch_reworked_comment_issue(state, issue)

      {:skip, reason} ->
        Logger.info("Trusted comment dispatch deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        schedule_poll_cycle_start()
        state

      {:error, reason} ->
        Logger.warning("Trusted comment dispatch deferred: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        schedule_poll_cycle_start()
        state
    end
  end

  defp dispatch_reworked_comment_issue(%State{} = state, %Issue{} = issue) do
    if should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set()) do
      dispatch_issue(state, issue)
    else
      schedule_poll_cycle_start()
      state
    end
  end

  defp fetch_comment_dispatch_issue(identifier) do
    case Tracker.fetch_issue_states_by_ids([identifier]) do
      {:ok, [%Issue{} = issue | _]} ->
        {:ok, issue}

      {:ok, []} ->
        fetch_comment_dispatch_issue_from_candidates(identifier)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_comment_dispatch_issue_from_candidates(identifier) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        case find_issue_by_identifier_or_id(issues, identifier) do
          %Issue{} = issue -> {:ok, issue}
          nil -> {:skip, :missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_issue_by_identifier_or_id(issues, identifier) when is_list(issues) do
    Enum.find(issues, fn
      %Issue{id: id, identifier: issue_identifier} ->
        id == identifier or issue_identifier == identifier

      _ ->
        false
    end)
  end

  defp transition_and_revalidate_comment_reactivation(
         state,
         running_entry,
         issue_number,
         source,
         event
       ) do
    issue_key = rework_issue_key(running_entry, issue_number)

    case transition_comment_issue_to_rework(issue_key, source, event) do
      :ok ->
        revalidate_comment_reactivation(state, running_entry, issue_number, source)

      {:skip, reason} ->
        context = comment_reactivation_context(running_entry, issue_number)
        Logger.info("#{source} ignored for inactive issue: #{context} reason=#{inspect(reason)}")
        state

      {:error, reason} ->
        context = comment_reactivation_context(running_entry, issue_number)

        Logger.warning("#{source} reactivation skipped; state update failed: #{context} reason=#{inspect(reason)}")

        state
    end
  end

  defp transition_comment_issue_to_rework(issue_number, _source, event) do
    cond do
      not trusted_comment_event?(event) ->
        {:skip, :untrusted_author}

      benign_review_pass_comment?(event) ->
        {:skip, :benign_review_pass_comment}

      true ->
        Tracker.update_issue_state(to_string(issue_number), "rework")
    end
  end

  defp trusted_comment_event?(event) when is_map(event) do
    Map.get(event, :author_trusted?) == true or Map.get(event, "author_trusted?") == true
  end

  defp benign_review_pass_comment?(event) when is_map(event) do
    event
    |> comment_body()
    |> review_pass_comment?()
  end

  defp comment_body(event) do
    comment = Map.get(event, :comment) || Map.get(event, "comment") || %{}

    if is_map(comment) do
      Map.get(comment, :body) || Map.get(comment, "body")
    end
  end

  defp review_pass_comment?(body) when is_binary(body) do
    body
    |> String.trim()
    |> String.downcase()
    |> String.match?(~r/^\[codex\]\s+review\s+passed\b/)
  end

  defp review_pass_comment?(_body), do: false

  defp comment_rework_retry_delay_ms(attempt) when is_integer(attempt) do
    power = (attempt - 1) |> max(0) |> min(4)
    comment_rework_retry_base_delay_ms() * (1 <<< power)
  end

  defp comment_rework_retry_base_delay_ms do
    case Application.get_env(:aiur, :comment_rework_retry_delay_ms) do
      delay when is_integer(delay) and delay >= 0 -> delay
      _ -> @comment_rework_retry_delay_ms
    end
  end

  defp comment_rework_max_attempts do
    case Application.get_env(:aiur, :comment_rework_max_attempts) do
      attempts when is_integer(attempts) and attempts > 0 -> attempts
      _ -> @comment_rework_max_attempts
    end
  end

  defp mark_pr_merged_issue_done(%State{} = state, identifier) do
    case Tracker.update_issue_state(to_string(identifier), "done") do
      :ok ->
        clear_session_handle(identifier)

        case find_running_by_identifier(state.running, identifier) do
          %{issue: %Issue{id: issue_id}} ->
            terminate_running_issue(state, issue_id, true)

          _ ->
            state
        end

      {:error, reason} ->
        Logger.warning("PR merge terminal transition skipped: issue_identifier=#{identifier} reason=#{inspect(reason)}")

        state
    end
  end

  defp rework_issue_key(%{issue: %Issue{id: issue_id}}, _issue_number) when is_binary(issue_id),
    do: issue_id

  defp rework_issue_key(_running_entry, issue_number), do: issue_number

  defp revalidate_comment_reactivation(state, running_entry, issue_number, source) do
    context = comment_reactivation_context(running_entry, issue_number)

    case fetch_current_reactivation_issue(running_entry) do
      {:ok, %Issue{} = refreshed_issue} ->
        reactivate_current_issue(state, running_entry, refreshed_issue, issue_number, source)

      {:skip, reason} ->
        Logger.info("#{source} ignored for inactive issue: #{context} reason=#{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.warning("#{source} reactivation skipped; issue refresh failed: #{context} reason=#{inspect(reason)}")

        state
    end
  end

  defp fetch_current_reactivation_issue(%{issue: %Issue{id: issue_id} = issue})
       when is_binary(issue_id) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} -> {:ok, refreshed_issue}
      {:skip, %Issue{} = refreshed_issue} -> {:skip, refreshed_issue.state}
      {:skip, :missing} -> {:skip, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_current_reactivation_issue(_running_entry), do: {:skip, :missing_issue_id}

  defp reactivate_current_issue(state, running_entry, refreshed_issue, issue_number, source) do
    issue_id = refreshed_issue.id
    refreshed_entry = Map.put(running_entry, :issue, refreshed_issue)
    state = %{state | running: Map.put(state.running, issue_id, refreshed_entry)}

    Logger.info("#{source} reactivating: issue_id=#{issue_id} issue_identifier=#{issue_number}")

    {_reply, next_state} = reactivate_issue(state, refreshed_entry)
    next_state
  end

  defp comment_reactivation_context(running_entry, issue_number) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{issue_number}"
  end

  defp event_digest_summary(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"
    message = Map.get(event, "message") || Map.get(event, :message) || Map.get(event, "summary")

    case message do
      m when is_binary(m) and m != "" -> "#{topic}: #{m}"
      _ -> topic
    end
  end

  defp poll_github_firehose(%State{} = state, opts \\ []) do
    poll_opts =
      opts
      |> Keyword.put_new(:etag, state.events_etag)
      |> Keyword.put_new(:last_event_id, state.events_last_id)

    case GithubFirehose.poll(poll_opts) do
      {:ok, %{etag: etag, last_event_id: last_event_id, count: count} = result} ->
        if count > 0, do: Logger.debug("aiur_perf github_firehose published count=#{count}")

        state =
          state
          |> note_github_connectivity_success(:firehose)
          |> note_github_poll_interval(:firehose, Map.get(result, :poll_interval))

        %{state | events_etag: etag, events_last_id: last_event_id}

      {:error, reason} ->
        # Preserve cached etag so we retry as If-None-Match next tick; the
        # classified failure feeds the escalation policy so a sustained
        # DNS/auth break surfaces a loud operator blocker (#617).
        note_github_connectivity_failure(state, :firehose, reason)
    end
  end

  defp poll_github_comments(%State{} = state, opts \\ []) do
    case Config.tracker_kind() do
      "github" -> do_poll_github_comments(state, opts)
      _ -> state
    end
  end

  defp do_poll_github_comments(%State{} = state, opts) do
    case github_comment_poll_targets(state, opts) do
      {:ok, targets, human_review_targets, watch_targets} ->
        poll_github_comment_targets(state, targets, human_review_targets, watch_targets, opts)

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller target refresh skipped; reason=#{inspect(reason)}")
        state
    end
  end

  defp poll_github_comment_targets(%State{} = state, [], _human_review_targets, _watch_targets, _opts),
    do: state

  defp poll_github_comment_targets(%State{} = state, targets, human_review_targets, watch_targets, opts)
       when is_list(targets) do
    poll_opts =
      opts
      |> Keyword.put_new(:since, state.github_comments_since)
      |> put_open_pull_requests_by_target(human_review_targets)
      |> put_open_pull_requests_by_target(watch_targets)

    case GithubCommentsPoller.poll(targets, poll_opts) do
      {:ok, %{since: since, count: count, errors: errors}} ->
        if count > 0,
          do: Logger.debug("aiur_perf github_comments_poller published count=#{count}")

        if errors != [] do
          Logger.warning("GithubCommentsPoller partial failures; reason=#{inspect(errors)}")
        end

        state =
          if all_comment_targets_failed?(targets, errors) do
            note_github_connectivity_failure(state, :comments, comments_poll_classification(errors))
          else
            note_github_connectivity_success(state, :comments)
          end

        %{
          state
          | github_comments_since: merge_comment_cursors(state.github_comments_since, since),
            github_comment_issue_updated_at:
              remember_polled_human_review_targets(
                state.github_comment_issue_updated_at,
                human_review_targets,
                errors
              )
        }
    end
  end

  # The comments poller aggregates per-target failures as
  # `[{target, {scope, taxonomy}}]`; pull the first classified GitHub error
  # out so the escalation policy sees the underlying connectivity class.
  defp comments_poll_classification([{_target, {_scope, taxonomy}} | _]), do: taxonomy
  defp comments_poll_classification(reason), do: reason

  defp merge_comment_cursors(%{} = previous, %{} = next), do: Map.merge(previous, next)
  defp merge_comment_cursors(_previous, next), do: next

  defp all_comment_targets_failed?(_targets, []), do: false

  defp all_comment_targets_failed?(targets, errors) do
    failed_targets =
      errors
      |> Enum.map(fn {target, _reason} -> target end)
      |> MapSet.new()

    targets
    |> MapSet.new()
    |> MapSet.subset?(failed_targets)
  end

  # Records a successful poll for `source`, clearing any failure streak so a
  # later break re-arms a fresh operator escalation.
  defp note_github_connectivity_success(%State{} = state, source) do
    %{
      state
      | github_connectivity: GitHubConnectivity.note_success(state.github_connectivity, source),
        github_poll_delays: Map.delete(state.github_poll_delays, source)
    }
  end

  # Classifies a poll failure and, when a sustained DNS/auth streak crosses the
  # escalation threshold, emits a single operator-visible blocker alert (#617).
  defp note_github_connectivity_failure(%State{} = state, source, reason) do
    classification = connectivity_classification(reason)
    detail = connectivity_detail(reason)

    {streaks, alerts} =
      GitHubConnectivity.note_failure(state.github_connectivity, source, classification)

    Enum.each(alerts, &emit_github_connectivity_alert/1)

    backoff_ms =
      classification
      |> GitHubConnectivity.backoff_ms(connectivity_streak_count(streaks, source), detail)
      |> normalize_github_backoff_ms(state)

    %{
      state
      | github_connectivity: streaks,
        github_poll_delays: Map.put(state.github_poll_delays, source, backoff_ms)
    }
  end

  defp connectivity_classification({:github, classification, _detail}), do: classification
  defp connectivity_classification({:github_api_status, 429}), do: :rate_limited
  defp connectivity_classification(_reason), do: :transport

  defp connectivity_detail({:github, _classification, detail}) when is_map(detail), do: detail

  defp connectivity_detail({:github_api_status, status}) when is_integer(status),
    do: %{status: status}

  defp connectivity_detail(_reason), do: %{}

  defp connectivity_streak_count(streaks, source) do
    case Map.get(streaks, source) do
      {_classification, count} when is_integer(count) and count > 0 -> count
      _ -> 1
    end
  end

  defp normalize_github_backoff_ms(:escalate, _state), do: GitHubConnectivity.max_backoff_ms()

  defp normalize_github_backoff_ms(delay_ms, _state) when is_integer(delay_ms) and delay_ms >= 0,
    do: delay_ms

  defp normalize_github_backoff_ms(_delay_ms, %State{} = state), do: state.poll_interval_ms

  defp note_github_poll_interval(%State{} = state, source, seconds)
       when is_integer(seconds) and seconds > 0 do
    %{state | github_poll_delays: Map.put(state.github_poll_delays, source, seconds * 1_000)}
  end

  defp note_github_poll_interval(%State{} = state, _source, _seconds), do: state

  defp next_poll_delay_ms(%State{} = state) do
    github_next_poll_delay_ms(state) || state.poll_interval_ms
  end

  defp github_next_poll_delay_ms(%State{github_poll_delays: delays}) when is_map(delays) do
    delays
    |> Map.values()
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.max(fn -> nil end)
  end

  defp github_next_poll_delay_ms(_state), do: nil

  defp emit_github_connectivity_alert(alert) do
    message = GitHubConnectivity.alert_message(alert, repo: Aiur.GitHub.Config.repo())

    Alerts.emit_custom("system.github.connectivity_lost", message,
      reason: message,
      needs_attention: true,
      severity: "warning"
    )
  end

  # One-off per-comment command scan (the U3 trigger). Each cycle, scan the
  # repo-wide PR-comment STREAMS directly — `pulls/comments` (review/line
  # comments) and `issues/comments` (conversation comments), both with a
  # `since` cursor — for a trusted `/aiur …` or `@<bot_account>` comment and
  # publish the PR-number reactivation event so an agent handles that single
  # comment. Scanning the comment streams (NOT a per-PR `updated_at` fetch) is
  # load-bearing: a `/aiur` left as a review comment does not reliably bump the
  # PR's `updated_at`, and a busy PR can fall outside a recently-updated
  # window — both would silently drop the command. No label is required and no
  # persistent watch state is stored: a commanded PR is NOT in the poller's
  # tracked target set, so it is naturally one-and-done — the comment-stream
  # `since` cursor + the Publisher dedup window keep an already-handled comment
  # from re-firing. Gated on `pr_watch_enabled?`.
  defp scan_pr_commands(%State{} = state, opts \\ []) do
    if Config.tracker_kind() == "github" and Aiur.GitHub.Config.pr_watch_enabled?() do
      do_scan_pr_commands(state, opts)
    else
      state
    end
  end

  defp do_scan_pr_commands(%State{} = state, opts) do
    since = command_scan_since(state, opts)
    fetch_opts = Keyword.put(opts, :since, since)

    review_comments = command_scan_review_comments(fetch_opts)
    issue_comments = command_scan_issue_comments(fetch_opts)

    pr_comments =
      (review_comments ++ issue_comments)
      |> Enum.map(&command_scan_annotate(&1))
      |> Enum.reject(&is_nil(command_scan_comment_pr_number(&1)))

    # Advance the cursor over EVERY PR comment seen this cycle, not just the
    # command hits, so a non-command comment newer than a command doesn't make
    # the cursor stall and re-scan the command next cycle.
    newest = command_scan_newest_datetime(pr_comments)

    publish_command_hits(pr_comments, command_scan_repo(opts), command_scan_limit(opts))

    %{state | github_command_scan_since: advance_command_scan_since(since, newest)}
  end

  # Fetch the repo-wide review-comment stream (`pulls/comments`). A failure is
  # logged and yields `[]` so the scan never raises; the cursor is unaffected
  # because `command_scan_newest_datetime/1` only advances on comments seen.
  defp command_scan_review_comments(fetch_opts) do
    fetcher =
      Keyword.get_lazy(fetch_opts, :command_scan_review_comment_fetcher, fn ->
        fn scan_opts -> GitHubClient.fetch_recent_repo_review_comments(scan_opts) end
      end)

    case fetcher.(fetch_opts) do
      {:ok, comments} when is_list(comments) ->
        comments

      {:error, reason} ->
        Logger.warning("scan_pr_commands review-comment stream failed; reason=#{inspect(reason)}")
        []

      other ->
        Logger.warning("scan_pr_commands review-comment stream returned unexpected value: #{inspect(other)}")
        []
    end
  end

  # Fetch the repo-wide conversation-comment stream (`issues/comments`). The
  # endpoint returns comments on plain issues AND PR conversations; PR-number
  # derivation (`command_scan_comment_pr_number/1`) only resolves the PR ones,
  # so non-PR issue comments are dropped downstream (out of scope).
  defp command_scan_issue_comments(fetch_opts) do
    fetcher =
      Keyword.get_lazy(fetch_opts, :command_scan_issue_comment_fetcher, fn ->
        fn scan_opts -> GitHubClient.fetch_recent_repo_issue_comments(scan_opts) end
      end)

    case fetcher.(fetch_opts) do
      {:ok, comments} when is_list(comments) ->
        comments

      {:error, reason} ->
        Logger.warning("scan_pr_commands issue-comment stream failed; reason=#{inspect(reason)}")
        []

      other ->
        Logger.warning("scan_pr_commands issue-comment stream returned unexpected value: #{inspect(other)}")
        []
    end
  end

  # Stamp event-time trust (`author_trusted?` from the canonical CODEOWNERS ∪
  # bot ∪ trusted-accounts set) and pin the derived PR number so later steps
  # don't re-derive it. The body/author the scanner reads stay untouched.
  defp command_scan_annotate(comment) when is_map(comment) do
    comment
    |> Sanitizer.stamp_author_trust(actor: command_scan_comment_author(comment))
    |> Map.put(:pr_number, derive_command_scan_pr_number(comment))
  end

  # Group the trusted command comments by PR number, bound the scan to a capped
  # number of distinct commanded PRs per cycle (logging the drop), and publish
  # a reactivation event for each comment under a kept PR.
  defp publish_command_hits(comments, repo, limit) do
    comments
    |> PrCommandScanner.commands(
      Aiur.GitHub.Config.command_prefix(),
      Aiur.GitHub.Config.bot_account()
    )
    |> group_command_hits_by_pr()
    |> cap_command_pr_hits(limit)
    |> Enum.each(fn {pr_number, hits} ->
      Enum.each(hits, &publish_command_reactivation(pr_number, &1, repo))
    end)
  end

  defp group_command_hits_by_pr(hits) do
    Enum.group_by(hits, &command_scan_comment_pr_number/1)
  end

  # Cap distinct commanded PRs per cycle. The streams are small per cursor
  # window, but a burst could surface commands on many PRs at once; keep a
  # bounded number and log the drop rather than silently truncating. Sorted by
  # PR number so the cap is deterministic across cycles.
  defp cap_command_pr_hits(hits_by_pr, limit) do
    sorted = Enum.sort_by(hits_by_pr, fn {pr_number, _hits} -> pr_number end)
    kept = Enum.take(sorted, limit)
    dropped = map_size(hits_by_pr) - length(kept)

    if dropped > 0 do
      Logger.warning("scan_pr_commands capped: kept=#{length(kept)} dropped=#{dropped} limit=#{limit}")
    end

    kept
  end

  # Mid-run teardown for PR-anchored agents (U6). Each poll cycle, terminate any
  # RUNNING PR-anchored agent (a watched/commanded human PR dispatched by U4)
  # whose PR is no longer open — it would otherwise keep burning compute and
  # pushing to a dead branch. Most teardown is IMPLICIT: a merged/closed/untagged
  # PR simply stops producing watch poll targets (U2) and the command path stores
  # no state, so nothing new is dispatched. This function covers the one gap the
  # implicit drop cannot: an agent already in-flight when its PR reaches a
  # terminal state.
  #
  # DESIGN DECISION — an untag mid-run does NOT abort a running agent. The agent
  # was dispatched for a real comment; let it finish the work it started.
  # Untagging only stops NEW dispatches (U2's implicit target drop). ONLY a
  # closed/merged PR — observed as `{:ok, nil}` from `fetch_open_pull_request/1`,
  # the same signal that treats closed/merged as "not open" — triggers mid-run
  # termination here.
  #
  # Fetch isolation: `{:ok, pr}` (still open) and `{:error, _}` (transient — a
  # rate-limit or network blip) both LEAVE the agent running. We never terminate
  # on a fetch error; a real terminal state will be re-observed next cycle.
  #
  # Gated on `pr_watch_enabled?` and short-circuited when there are zero
  # PR-anchored running entries, so a repo not using the feature issues no
  # fetches.
  defp maybe_stop_closed_pr_anchored_agents(%State{} = state, opts \\ []) do
    if Config.tracker_kind() == "github" and Aiur.GitHub.Config.pr_watch_enabled?() do
      case pr_anchored_running_entries(state) do
        [] -> state
        entries -> stop_closed_pr_anchored_entries(state, entries, opts)
      end
    else
      state
    end
  end

  # Select the running entries dispatched as PR-anchored units. We key off the
  # stored `%Issue{}` `state == @pr_anchored_state` (the canonical sentinel
  # `build_pr_anchored_issue/1` stamps) rather than the `"pr-"` running-key
  # prefix: the state is a dedicated marker nothing else uses, while a key prefix
  # is a derived convention a tracker id could collide with.
  defp pr_anchored_running_entries(%State{running: running}) do
    Enum.filter(running, fn {_issue_id, running_entry} ->
      pr_anchored_running_entry?(running_entry)
    end)
  end

  defp pr_anchored_running_entry?(%{issue: %Issue{state: @pr_anchored_state}}), do: true
  defp pr_anchored_running_entry?(_running_entry), do: false

  defp stop_closed_pr_anchored_entries(%State{} = state, entries, opts) do
    fetcher = pr_open_state_fetcher(opts)

    Enum.reduce(entries, state, fn {issue_id, running_entry}, state_acc ->
      pr_number = Map.get(running_entry, :identifier)

      case fetcher.(pr_number) do
        {:ok, nil} ->
          Logger.warning("PR-anchored agent's PR is no longer open; stopping agent and cleaning workspace: issue_id=#{issue_id} pr=#{pr_number}")

          state_acc = terminate_running_issue(state_acc, issue_id, false)
          cleanup_pr_anchored_workspace(issue_id, running_entry)
          state_acc

        {:ok, _pr} ->
          # PR still open — let the agent keep working.
          state_acc

        {:error, reason} ->
          # Transient fetch failure — do NOT terminate. A real terminal state is
          # re-observed next cycle.
          Logger.warning("PR-anchored teardown PR fetch failed; leaving agent running: issue_id=#{issue_id} pr=#{pr_number} reason=#{inspect(reason)}")

          state_acc

        other ->
          Logger.warning("PR-anchored teardown PR fetch returned unexpected value; leaving agent running: issue_id=#{issue_id} pr=#{pr_number} value=#{inspect(other)}")

          state_acc
      end
    end)
  end

  defp pr_open_state_fetcher(opts) do
    case Keyword.get(opts, :open_pull_request_fetcher) do
      fun when is_function(fun, 1) -> fun
      _ -> fn pr_number -> GitHubClient.fetch_open_pull_request(pr_number) end
    end
  end

  # `terminate_running_issue/3`'s workspace cleanup keys off the running entry's
  # `identifier` (the bare PR number), but a PR-anchored workspace lives at the
  # `pr-<pr#>` leaf (`Workspace.workspace_identifier/2`), which equals the
  # running-map KEY (`issue.id`). Clean the `pr-<pr#>` leaf explicitly so no
  # orphan workspace is left behind, mirroring the legacy terminal cleanup.
  defp cleanup_pr_anchored_workspace(issue_id, running_entry) when is_binary(issue_id) do
    # A closed PR is terminal for a PR-anchored unit, but this path bypasses
    # `cleanup_terminal_issue_artifacts`, so the resume handle is never cleared
    # for it. The handle is keyed by the PR-number `identifier` (what
    # `start_agent_session` persisted under), not the `pr-<pr#>` running key;
    # without this, a reopened PR would `--resume` the finished thread now that
    # `claude-repl` is resumable (#613).
    clear_session_handle(Map.get(running_entry, :identifier))
    Workspace.remove_issue_workspaces(issue_id, Map.get(running_entry, :worker_host))
  end

  # Emit the SAME PR-number reactivation signal U2 uses
  # (`ticket.<pr#>.pr.review_comment`) with `bypass_contamination: true` so it
  # reaches the orchestrator even though the commanded PR is absent from the
  # tracked set (mirrors the firehose `bypass_contamination` path). The
  # Publisher's `bot_self_loop?` and dedup gates still apply.
  defp publish_command_reactivation(pr_number, comment, repo) do
    target = to_string(pr_number)
    actor = command_scan_comment_author(comment)

    payload =
      %{issue_number: target, comment: comment, source: :github}
      |> Sanitizer.scrub()
      |> Sanitizer.put_comment_message()

    Publisher.publish(
      "ticket.#{target}.pr.review_comment",
      payload,
      issue_number: target,
      actor: actor,
      bypass_contamination: true,
      dedup_key:
        GithubKeys.comment_dedup_key(
          repo,
          "pr_command",
          pr_number,
          Map.get(comment, "id")
        )
    )
  end

  defp command_scan_comment_author(comment) when is_map(comment) do
    get_in(comment, ["user", "login"]) || get_in(comment, ["author", "login"])
  end

  # The derived PR number, read from the annotation pinned by
  # `command_scan_annotate/1`.
  defp command_scan_comment_pr_number(comment) when is_map(comment) do
    Map.get(comment, :pr_number)
  end

  # Derive the PR number from a stream comment. Review comments carry
  # `pull_request_url` (`.../pulls/<n>`); conversation comments carry
  # `issue_url` (`.../issues/<n>`) and are PRs only when `html_url` contains
  # `/pull/` (a plain issue's `html_url` contains `/issues/`). Returns nil for
  # non-PR issue comments and any malformed URL, dropping them from the scan.
  defp derive_command_scan_pr_number(%{"pull_request_url" => url}) when is_binary(url) do
    parse_trailing_number(url)
  end

  defp derive_command_scan_pr_number(%{"issue_url" => url} = comment) when is_binary(url) do
    if command_scan_pr_html_url?(comment), do: parse_trailing_number(url)
  end

  defp derive_command_scan_pr_number(_comment), do: nil

  defp command_scan_pr_html_url?(%{"html_url" => html_url}) when is_binary(html_url) do
    String.contains?(html_url, "/pull/")
  end

  defp command_scan_pr_html_url?(_comment), do: false

  defp parse_trailing_number(url) when is_binary(url) do
    case url |> String.split("/") |> List.last() |> Integer.parse() do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp command_scan_repo(opts) do
    Keyword.get(opts, :repo) || Aiur.Tracker.project_identity()
  end

  defp command_scan_since(%State{github_command_scan_since: since}, _opts)
       when is_binary(since),
       do: since

  defp command_scan_since(%State{}, opts), do: GithubKeys.boot_cutoff_iso8601(opts)

  defp command_scan_limit(opts) do
    case Keyword.get(opts, :command_scan_pull_request_limit, @command_scan_pull_requests_per_poll) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @command_scan_pull_requests_per_poll
    end
  end

  defp command_scan_newest_datetime(comments) do
    Enum.reduce(comments, nil, fn comment, newest ->
      max_command_scan_datetime(newest, command_scan_comment_datetime(comment))
    end)
  end

  defp command_scan_comment_datetime(comment) when is_map(comment) do
    comment
    |> Map.get("updated_at", Map.get(comment, "created_at"))
    |> parse_command_scan_datetime()
  end

  defp parse_command_scan_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_command_scan_datetime(_value), do: nil

  defp max_command_scan_datetime(nil, datetime), do: datetime
  defp max_command_scan_datetime(datetime, nil), do: datetime

  defp max_command_scan_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :lt -> right
      _ -> left
    end
  end

  defp advance_command_scan_since(since, nil), do: since

  defp advance_command_scan_since(_since, %DateTime{} = newest) do
    newest
    |> DateTime.add(-1, :second)
    |> DateTime.to_iso8601()
  end

  defp github_comment_poll_targets(%State{} = state, opts) do
    with {:ok, human_review_targets} <- human_review_comment_poll_targets(state, opts),
         {:ok, watch_targets} <- watch_comment_poll_targets(state, opts) do
      running_targets = running_comment_poll_targets(state)

      targets =
        running_targets
        |> Kernel.++(Enum.map(human_review_targets, & &1.target))
        |> Kernel.++(Enum.map(watch_targets, & &1.target))
        |> Enum.uniq()

      {:ok, targets, human_review_targets, watch_targets}
    end
  end

  # Discovers open PRs labeled `agent:watch` repo-wide and turns each into a
  # PR-number-keyed comment poll target carrying its PR object, so the poller
  # never branch-derives for watched PRs (it consumes the passed PR via
  # `open_pull_requests_by_target`). Mirrors `human_review_comment_poll_targets/2`:
  # closed/merged PRs are excluded at the query, the set is deduped and capped per
  # poll, and the drop is logged (never silent). Returns `{:ok, []}` when the
  # feature is disabled so the rest of the poll cycle is untouched.
  defp watch_comment_poll_targets(%State{} = _state, opts) do
    if Aiur.GitHub.Config.pr_watch_enabled?() do
      fetcher = watch_pull_request_fetcher(opts)

      case fetcher.(Aiur.GitHub.Config.watch_label()) do
        {:ok, pull_requests} when is_list(pull_requests) ->
          {:ok, build_watch_targets(pull_requests, opts)}

        {:error, _reason} = error ->
          error

        other ->
          {:error, {:unexpected_watch_targets, other}}
      end
    else
      {:ok, []}
    end
  end

  defp watch_pull_request_fetcher(opts) do
    Keyword.get_lazy(opts, :watch_pull_request_fetcher, fn ->
      fn label -> GitHubClient.fetch_open_pull_requests_by_label(label, opts) end
    end)
  end

  defp build_watch_targets(pull_requests, opts) do
    targets =
      pull_requests
      |> Enum.map(&watch_comment_target_for_pull_request/1)
      |> Enum.reject(&is_nil/1)
      |> dedupe_watch_targets()

    limit = watch_comment_target_limit(opts)
    kept = Enum.take(targets, limit)

    dropped = length(targets) - length(kept)

    if dropped > 0 do
      Logger.warning("watch_comment_poll_targets capped: kept=#{length(kept)} dropped=#{dropped} limit=#{limit}")
    end

    kept
  end

  # A watched PR's identifier/topic is its PR number (string). Open/closed is
  # already filtered at the query, so any PR reaching here is an active watch
  # target. `open` defends against a fetcher that returns non-open PRs.
  defp watch_comment_target_for_pull_request(%{"number" => number} = pr)
       when is_integer(number) do
    if pull_request_open?(pr) do
      %{target: to_string(number), open_pull_request: pr}
    end
  end

  defp watch_comment_target_for_pull_request(_pr), do: nil

  defp pull_request_open?(%{"state" => state}) when is_binary(state), do: state == "open"
  defp pull_request_open?(%{"merged_at" => merged_at}) when is_binary(merged_at), do: false
  defp pull_request_open?(_pr), do: true

  defp dedupe_watch_targets(targets) do
    targets
    |> Enum.reduce(%{}, fn %{target: target} = entry, acc ->
      Map.put_new(acc, target, entry)
    end)
    |> Map.values()
  end

  defp watch_comment_target_limit(opts) do
    case Keyword.get(opts, :watch_comment_target_limit, @watch_comment_targets_per_poll) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @watch_comment_targets_per_poll
    end
  end

  defp running_comment_poll_targets(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.map(&Map.get(&1, :identifier))
    |> normalize_comment_targets()
  end

  # Discovers idle (non-running) tickets in the comment-actionable review states
  # (`human-review` + `merging`) and turns each into a comment poll target, so a
  # trusted reviewer comment on them is seen and promotes the ticket to `rework`
  # even though those states are not in `active_states`.
  defp human_review_comment_poll_targets(%State{} = state, opts) do
    fetcher = Keyword.get(opts, :review_issue_fetcher, &Tracker.fetch_issues_by_states/1)

    case fetcher.(@comment_poll_review_states) do
      {:ok, issues} when is_list(issues) ->
        targets =
          issues
          |> Enum.reject(&Issue.paused?/1)
          |> Enum.map(&human_review_comment_target_for_issue/1)
          |> Enum.reject(&is_nil/1)
          |> dedupe_human_review_targets()
          |> Enum.sort_by(&human_review_comment_target_sort_key(state, &1))
          |> Enum.take(human_review_comment_target_limit(opts))
          |> Enum.map(&with_human_review_pr_updated_at(&1, opts))
          |> Enum.reject(&unchanged_human_review_comment_target?(state, &1))

        {:ok, targets}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_human_review_targets, other}}
    end
  end

  defp comment_target_for_issue(%Issue{identifier: identifier}) when not is_nil(identifier),
    do: identifier

  defp comment_target_for_issue(%Issue{id: id}) when not is_nil(id), do: id
  defp comment_target_for_issue(_issue), do: nil

  defp human_review_comment_target_for_issue(%Issue{} = issue) do
    case normalize_comment_targets([comment_target_for_issue(issue)]) do
      [target] ->
        issue_updated_at = issue_updated_at_key(issue.updated_at)
        %{target: target, issue_updated_at: issue_updated_at, updated_at: issue_updated_at}

      [] ->
        nil
    end
  end

  defp with_human_review_pr_updated_at(%{target: target} = entry, opts) do
    fetcher = human_review_pr_fetcher(opts)

    case fetcher.(target) do
      {:ok, pr} when is_map(pr) ->
        pr_updated_at =
          pr
          |> Map.get("updated_at", Map.get(pr, :updated_at))
          |> issue_updated_at_key()

        entry
        |> Map.put(:open_pull_request, pr)
        |> Map.put(:updated_at, human_review_target_updated_at_key(entry.issue_updated_at, pr_updated_at))

      {:ok, nil} ->
        entry
        |> Map.put(:open_pull_request, nil)
        |> Map.put(:updated_at, human_review_target_updated_at_key(entry.issue_updated_at, nil))

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller PR freshness lookup failed: issue=#{target} reason=#{inspect(reason)}")
        %{entry | updated_at: nil}

      other ->
        Logger.warning("GithubCommentsPoller PR freshness lookup returned unexpected value: issue=#{target} result=#{inspect(other)}")
        %{entry | updated_at: nil}
    end
  end

  defp human_review_pr_fetcher(opts) do
    Keyword.get_lazy(opts, :review_pull_request_fetcher, fn ->
      fn target -> GitHubClient.fetch_open_pull_request_for_branch(target, opts) end
    end)
  end

  defp dedupe_human_review_targets(targets) do
    targets
    |> Enum.reduce(%{}, fn %{target: target} = entry, acc ->
      Map.put_new(acc, target, entry)
    end)
    |> Map.values()
  end

  defp unchanged_human_review_comment_target?(
         %State{github_comment_issue_updated_at: updated_at_by_target},
         %{target: target, updated_at: updated_at}
       )
       when is_binary(updated_at) do
    Map.get(updated_at_by_target, target) == updated_at
  end

  defp unchanged_human_review_comment_target?(_state, _target), do: false

  defp human_review_comment_target_sort_key(
         %State{
           github_comments_since: cursors,
           github_comment_issue_updated_at: updated_at_by_target
         },
         %{target: target, issue_updated_at: issue_updated_at}
       ) do
    {
      human_review_pr_probe_priority(updated_at_by_target, target, issue_updated_at),
      comment_cursor_sort_key(cursors, target),
      target
    }
  end

  defp comment_cursor_sort_key(%{} = cursors, target), do: Map.get(cursors, target) || ""
  defp comment_cursor_sort_key(cursor, _target) when is_binary(cursor), do: cursor
  defp comment_cursor_sort_key(_cursor, _target), do: ""

  defp human_review_pr_probe_priority(%{} = updated_at_by_target, target, issue_updated_at)
       when is_binary(issue_updated_at) do
    case Map.get(updated_at_by_target, target) do
      updated_at when is_binary(updated_at) ->
        if human_review_target_known_at_issue_updated_at?(updated_at, issue_updated_at), do: 1, else: 0

      _other ->
        0
    end
  end

  defp human_review_pr_probe_priority(_updated_at_by_target, _target, _issue_updated_at), do: 0

  defp human_review_target_known_at_issue_updated_at?(updated_at, issue_updated_at) do
    updated_at == issue_updated_at or String.starts_with?(updated_at, "issue=#{issue_updated_at};pr=")
  end

  defp human_review_comment_target_limit(opts) do
    case Keyword.get(opts, :human_review_comment_target_limit, @human_review_comment_targets_per_poll) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @human_review_comment_targets_per_poll
    end
  end

  defp put_open_pull_requests_by_target(opts, targets) do
    open_pull_requests =
      targets
      |> Enum.reduce(%{}, fn
        %{target: target} = entry, acc when is_binary(target) ->
          if Map.has_key?(entry, :open_pull_request) do
            Map.put(acc, target, Map.get(entry, :open_pull_request))
          else
            acc
          end

        _entry, acc ->
          acc
      end)

    if map_size(open_pull_requests) == 0 do
      opts
    else
      existing = Keyword.get(opts, :open_pull_requests_by_target, %{})
      Keyword.put(opts, :open_pull_requests_by_target, Map.merge(existing, open_pull_requests))
    end
  end

  defp issue_updated_at_key(%DateTime{} = updated_at), do: DateTime.to_iso8601(updated_at)
  defp issue_updated_at_key(updated_at) when is_binary(updated_at), do: updated_at
  defp issue_updated_at_key(_updated_at), do: nil

  defp human_review_target_updated_at_key(issue_updated_at, pr_updated_at)
       when is_binary(pr_updated_at) do
    IO.iodata_to_binary(["issue=", issue_updated_at || "", ";pr=", pr_updated_at])
  end

  defp human_review_target_updated_at_key(issue_updated_at, _pr_updated_at), do: issue_updated_at

  defp remember_polled_human_review_targets(updated_at_by_target, human_review_targets, errors) do
    failed_targets =
      errors
      |> Enum.map(fn {target, _reason} -> target end)
      |> MapSet.new()

    human_review_targets
    |> Enum.reject(&(MapSet.member?(failed_targets, &1.target) or is_nil(&1.updated_at)))
    |> Map.new(&{&1.target, &1.updated_at})
    |> then(&Map.merge(updated_at_by_target || %{}, &1))
  end

  defp normalize_comment_targets(targets) when is_list(targets) do
    targets
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
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
    state = refresh_running_issue_states(state)
    state = refresh_tracked_set(state)
    state = poll_github_firehose(state)
    state = poll_github_comments(state)
    state = scan_pr_commands(state)
    state = maybe_stop_closed_pr_anchored_agents(state)

    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
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
  def ensure_tracker_preflight(%State{} = state) do
    case Config.validate!() do
      :ok ->
        case Config.tracker_kind() do
          "github" -> ensure_github_auth_preflight(state)
          _ -> {:ok, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp ensure_github_auth_preflight(%State{} = state) do
    case GitHubTracker.auth_preflight() do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp log_tracker_preflight_error({:github_auth_preflight_failed, _diagnostic} = reason) do
    Logger.error(GitHubClient.format_auth_preflight_error(reason))
  end

  defp log_tracker_preflight_error(:missing_linear_api_token),
    do: Logger.error("Linear API token missing in .aiurconfig")

  defp log_tracker_preflight_error(:missing_linear_project_slug),
    do: Logger.error("Linear project slug missing in .aiurconfig")

  defp log_tracker_preflight_error(:missing_tracker_kind),
    do: Logger.error("Tracker kind missing in .aiurconfig")

  defp log_tracker_preflight_error({:unsupported_tracker_kind, kind}),
    do: Logger.error("Unsupported tracker kind in .aiurconfig: #{inspect(kind)}")

  defp log_tracker_preflight_error({:invalid_workflow_config, message}),
    do: Logger.error("Invalid .aiurconfig config: #{message}")

  defp log_tracker_preflight_error({:missing_workflow_file, path, reason}),
    do: Logger.error("Missing .aiurconfig at #{path}: #{inspect(reason)}")

  defp log_tracker_preflight_error({:missing_prompt_file, path, reason}),
    do: Logger.error("Missing prompt_file at #{path}: #{inspect(reason)}")

  defp log_tracker_preflight_error(:workflow_front_matter_not_a_map),
    do: Logger.error("Failed to parse .aiurconfig: top-level YAML must be a map")

  defp log_tracker_preflight_error({:workflow_parse_error, reason}),
    do: Logger.error("Failed to parse .aiurconfig: #{inspect(reason)}")

  defp log_tracker_preflight_error({:missing_hooks_file, path, reason}),
    do: Logger.error("Missing hooks_file at #{path}: #{inspect(reason)}")

  defp log_tracker_preflight_error({:invalid_hooks_file, path, reason}),
    do: Logger.error("Invalid hooks_file at #{path}: #{inspect(reason)}")

  defp log_tracker_preflight_error(reason),
    do: Logger.error("Tracker preflight failed for #{tracker_log_label()}: #{inspect(reason)}")

  defp log_tracker_fetch_error(reason) do
    Logger.error("Failed to fetch from #{tracker_log_label()}: #{inspect(reason)}")
  end

  defp tracker_log_label do
    case Config.settings() do
      {:ok, settings} -> settings.tracker.kind || "tracker"
      _ -> "tracker"
    end
  end

  # Eager pre-warm gate. When pre-warm is enabled, hold dispatch until the shared
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
    threshold = Config.max_load_average()
    schedulers = System.schedulers_online()
    load = read_load(threshold)

    case load_gate(load, threshold, schedulers) do
      :hold ->
        log_load_hold(load, threshold, schedulers)
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
  defp close_active_chat_streams(identifier, reason) when is_binary(identifier) do
    for aiur_turn_id <- ActiveTurns.active_turn_ids(identifier) do
      AgentPubSub.broadcast_aiur_turn_done(identifier, aiur_turn_id, reason)
      ActiveTurns.mark_closed(identifier, aiur_turn_id, reason)
    end

    :ok
  end

  defp close_active_chat_streams(_identifier, _reason), do: :ok

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

  # Retry blockee resumes that were deferred when the concurrent-agent
  # cap was full at branch.push time. Without this hook the push event
  # is consumed exactly once (Publisher dedupes `(repo, ref, sha)`),
  # so a blockee that couldn't fit in a slot would stay paused
  # forever even after another agent finished and freed capacity.
  @doc false
  @spec reconcile_pending_auto_resumes(State.t()) :: State.t()
  def reconcile_pending_auto_resumes(%State{} = state) do
    Enum.reduce(state.running, state, fn {_issue_id, entry}, acc ->
      case Map.get(entry, :pending_auto_resume) do
        %{} = hint when is_map(hint) ->
          maybe_drain_pending_auto_resume(acc, entry, hint)

        _ ->
          acc
      end
    end)
  end

  defp maybe_drain_pending_auto_resume(state, entry, hint) do
    cond do
      not paused_running_entry?(entry) ->
        # Already resumed by another path (operator chat, label flip);
        # clear the stale hint.
        clear_pending_auto_resume(state, entry)

      deactivated_running_entry?(entry) ->
        clear_pending_auto_resume(state, entry)

      true ->
        identifier = Map.get(entry, :identifier)
        blocker_identifier = Map.get(hint, :blocker_identifier)
        topic = Map.get(hint, :topic)

        # operator?: false — same automated path as `attempt_auto_resume`,
        # just deferred until a slot opened; preserve the duration overrun.
        case resume_paused_issue(state, entry, false) do
          {{:ok, :resumed}, next_state} ->
            Logger.info("Auto-resume drained: blockee=#{identifier} blocker=#{blocker_identifier} topic=#{topic}")

            clear_pending_auto_resume(next_state, entry)

          {{:error, _reason}, next_state} ->
            # Cap still full or another error — keep the hint for the
            # next reconcile tick.
            next_state
        end
    end
  end

  defp clear_pending_auto_resume(state, entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])

    case Map.get(state.running, issue_id) do
      running_entry when is_map(running_entry) ->
        updated = Map.delete(running_entry, :pending_auto_resume)
        %{state | running: Map.put(state.running, issue_id, updated)}

      _ ->
        state
    end
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

      Logger.warning("Issue exceeded max_agent_duration: issue_id=#{issue_id} issue_identifier=#{identifier} running_seconds=#{seconds} cap_seconds=#{max_seconds}; pausing agent")

      _ = send_pause_control_message(state, identifier)

      paused_entry = Map.put(running_entry, :paused_reason, :max_agent_duration)
      transition_control_status(state, paused_entry, :paused, "max_agent_duration")
    else
      state
    end
  end

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

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(Aiur.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :kill)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp sync_polled_issue_state(%State{} = state, issues) when is_list(issues) do
    previous_issues = state.last_polled_issues

    state =
      Enum.reduce(issues, state, fn issue, state_acc ->
        previous_issue = Map.get(previous_issues, issue.id)

        state_acc
        |> emit_task_state_transition_alert(previous_issue, issue)
        |> emit_dependency_transition_events(previous_issue, issue)
      end)

    %{state | last_polled_issues: issues_by_id(issues)}
  end

  defp sync_polled_issue_state(%State{} = state, _issues), do: state

  defp issues_by_id(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{id: issue_id} = issue, acc when is_binary(issue_id) -> Map.put(acc, issue_id, issue)
      _issue, acc -> acc
    end)
  end

  defp emit_dependency_transition_events(%State{} = state, previous_issue, %Issue{} = issue) do
    if is_nil(previous_issue) do
      state
    else
      previous_blockers = blocker_map(previous_issue)
      current_blockers = blocker_map(issue)

      added_blocker_ids = Map.keys(current_blockers) -- Map.keys(previous_blockers)
      removed_blocker_ids = Map.keys(previous_blockers) -- Map.keys(current_blockers)
      shared_blocker_ids = Map.keys(current_blockers) -- added_blocker_ids

      state =
        Enum.reduce(added_blocker_ids, state, fn blocker_id, state_acc ->
          auto_subscribe_for_dependency(issue, current_blockers[blocker_id])

          enqueue_dependency_event(
            state_acc,
            issue,
            current_blockers[blocker_id],
            :dependency_added
          )
        end)

      state =
        Enum.reduce(removed_blocker_ids, state, fn blocker_id, state_acc ->
          auto_unsubscribe_for_dependency(issue, previous_blockers[blocker_id])

          enqueue_dependency_event(
            state_acc,
            issue,
            previous_blockers[blocker_id],
            :dependency_removed
          )
        end)

      Enum.reduce(shared_blocker_ids, state, fn blocker_id, state_acc ->
        maybe_enqueue_blocker_terminality_event(
          state_acc,
          issue,
          previous_blockers[blocker_id],
          current_blockers[blocker_id]
        )
      end)
    end
  end

  defp emit_dependency_transition_events(%State{} = state, _previous_issue, _issue), do: state

  defp emit_task_state_transition_alert(%State{} = state, nil, %Issue{}), do: state

  defp emit_task_state_transition_alert(
         %State{} = state,
         %Issue{} = previous_issue,
         %Issue{} = issue
       ) do
    previous_state = state_slug(previous_issue.state)
    current_state = state_slug(issue.state)

    if previous_state != current_state and current_state != nil do
      # Ticket B: label-flip alerts route through the new topic shape so
      # `alerts.yaml` can glob-match per state without one entry per state.
      Alerts.emit_system(
        "ticket.#{issue.identifier}.issue.label.added.agent.#{current_state}",
        issue: issue,
        worker_host: running_worker_host(state, issue.id),
        reason: task_state_alert_reason(current_state),
        needs_attention: task_state_needs_attention?(current_state),
        severity: task_state_alert_severity(current_state)
      )
    end

    state
  end

  defp emit_task_state_transition_alert(%State{} = state, _previous_issue, _issue), do: state

  defp task_state_alert_reason("human-review"),
    do: "Agent marked the ticket ready for human review"

  defp task_state_alert_reason(_state), do: nil

  defp task_state_needs_attention?("human-review"), do: true
  defp task_state_needs_attention?(_state), do: false

  defp task_state_alert_severity("human-review"), do: "warning"
  defp task_state_alert_severity(_state), do: nil

  defp blocker_map(%Issue{blocked_by: blockers}) when is_list(blockers) do
    Enum.reduce(blockers, %{}, fn
      %{id: blocker_id} = blocker, acc when is_binary(blocker_id) ->
        Map.put(acc, blocker_id, blocker)

      _blocker, acc ->
        acc
    end)
  end

  defp blocker_map(_issue), do: %{}

  defp blocker_terminal?(%{state: state_name}) when is_binary(state_name) do
    terminal_issue_state?(state_name, terminal_state_set())
  end

  defp blocker_terminal?(_blocker), do: false

  defp maybe_enqueue_blocker_terminality_event(state, issue, previous_blocker, current_blocker) do
    cond do
      blocker_terminal?(previous_blocker) and !blocker_terminal?(current_blocker) ->
        enqueue_dependency_event(state, issue, current_blocker, :blocker_became_non_terminal)

      !blocker_terminal?(previous_blocker) and blocker_terminal?(current_blocker) ->
        enqueue_dependency_event(state, issue, current_blocker, :blocker_became_terminal)

      true ->
        state
    end
  end

  defp enqueue_dependency_event(%State{} = state, %Issue{} = issue, blocker, update_kind)
       when is_map(blocker) do
    body = blocker_event_body(issue, blocker, update_kind)

    {queue_store, item} =
      AgentQueue.coordination_event(issue.identifier, update_kind, body,
        source: :tracker,
        dedupe_key: dependency_event_dedupe_key(issue, blocker, update_kind),
        causal_refs: dependency_causal_refs(issue, blocker),
        subscription: dependency_subscription(issue, blocker)
      )
      |> then(&AgentQueueStore.enqueue(state.queue_store, &1))

    next_state = %{state | queue_store: queue_store}

    case find_running_by_identifier(state.running, issue.identifier) do
      nil ->
        next_state

      running_entry ->
        notify_running_queue_update(running_entry, item)
        next_state
    end
  end

  defp enqueue_dependency_event(%State{} = state, _issue, _blocker, _update_kind), do: state

  defp blocker_event_body(issue, blocker, update_kind) do
    %{
      blocked_issue_id: issue.id,
      blocked_issue_identifier: issue.identifier,
      blocker_issue_id: blocker[:id],
      blocker_issue_identifier: blocker[:identifier],
      blocker_state: blocker[:state],
      update_kind: update_kind,
      summary: blocker_event_summary(issue, blocker, update_kind)
    }
  end

  defp blocker_event_summary(_issue, blocker, :dependency_added),
    do: "Issue is now blocked by #{blocker[:identifier] || blocker[:id]}"

  defp blocker_event_summary(_issue, blocker, :dependency_removed),
    do: "Dependency on #{blocker[:identifier] || blocker[:id]} was removed"

  defp blocker_event_summary(_issue, blocker, :blocker_became_terminal),
    do: "Blocker #{blocker[:identifier] || blocker[:id]} reached terminal state #{blocker[:state]}"

  defp blocker_event_summary(_issue, blocker, :blocker_became_non_terminal),
    do: "Blocker #{blocker[:identifier] || blocker[:id]} returned to non-terminal state #{blocker[:state]}"

  defp dependency_event_dedupe_key(issue, blocker, update_kind) do
    [
      Atom.to_string(update_kind),
      issue.id || issue.identifier,
      blocker[:id] || blocker[:identifier],
      blocker[:state]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp dependency_causal_refs(issue, blocker) do
    [issue.id, blocker[:id]]
    |> Enum.reject(&is_nil/1)
  end

  defp dependency_subscription(issue, blocker) do
    %{
      subscription_type: :blocked_by,
      source_issue_id: blocker[:id],
      target_issue_id: issue.id
    }
  end

  defp sort_issues_for_dispatch(issues), do: DispatchPolicy.sort_issues_for_dispatch(issues)
  defp should_dispatch_issue?(issue, state, active_states, terminal_states), do: DispatchPolicy.should_dispatch_issue?(issue, state, active_states, terminal_states)
  defp dispatch_candidate?(issue, state, active_states, terminal_states), do: DispatchPolicy.dispatch_candidate?(issue, state, active_states, terminal_states)
  defp state_slots_available?(issue, state), do: DispatchPolicy.state_slots_available?(issue, state)
  defp candidate_issue?(issue, active_states, terminal_states), do: DispatchPolicy.candidate_issue?(issue, active_states, terminal_states)
  defp issue_routable_to_worker?(issue), do: DispatchPolicy.issue_routable_to_worker?(issue)
  defp todo_issue_blocked_by_non_terminal?(issue, terminal_states), do: DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  defp terminal_issue_state?(state_name, terminal_states), do: DispatchPolicy.terminal_issue_state?(state_name, terminal_states)
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
  defp dispatch_issue(state, issue, attempt \\ nil, preferred_worker_host \\ nil), do: Dispatcher.dispatch_issue(state, issue, attempt, preferred_worker_host)
  defp do_dispatch_issue(state, issue, attempt, preferred_worker_host), do: Dispatcher.do_dispatch_issue(state, issue, attempt, preferred_worker_host)
  defp reset_thrash_budget(state, issue_id), do: Dispatcher.reset_thrash_budget(state, issue_id)
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

  defp clear_session_handle(identifier) when is_binary(identifier), do: SessionHandle.clear(identifier)
  defp clear_session_handle(_identifier), do: :ok

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
  defp sleeping_running_entry?(entry), do: State.sleeping_running_entry?(entry)
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

  defp enqueue_event_digest_item(%State{} = state, identifier, events, summary_source)
       when is_binary(identifier) and is_list(events) do
    body = %{
      summary: event_digest_summary(summary_source),
      events: events
    }

    running_entry = find_running_by_identifier(state.running, identifier)
    delivery_opts = event_digest_delivery_opts(running_entry, events)

    {queue_store, item} =
      AgentQueue.coordination_event(identifier, :events_digest, body, delivery_opts)
      |> then(&AgentQueueStore.enqueue(state.queue_store, &1))

    next_state = %{state | queue_store: queue_store}

    case running_entry do
      nil ->
        :ok

      running_entry ->
        notify_running_queue_update(running_entry, item)
    end

    next_state
  end

  defp enqueue_operator_message(state, issue_identifier, body, payload) do
    delivery_policy = Map.get(payload, :delivery_policy, :checkpoint)
    fallback = Map.get(payload, :fallback)
    turn_id = Map.get(payload, :turn_id)

    case validate_operator_message(body) do
      {:ok, text} ->
        enqueue_validated_operator_message(
          state,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp enqueue_validated_operator_message(
         state,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    case find_running_by_identifier(state.running, issue_identifier) do
      nil ->
        {{:error, :no_running_agent}, state}

      running_entry ->
        enqueue_for_running_entry(
          state,
          running_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )
    end
  end

  # Chatting with a paused agent auto-resumes it — but only if a slot is
  # free. Routing through `resume_paused_issue/2` reuses the same
  # active-cap and per-state slot gates as the explicit space-key resume,
  # so we can't push active over max no matter which entry point the
  # operator uses. If no slot is free, the cap error propagates and the
  # conversation pane surfaces it.
  defp enqueue_for_running_entry(
         state,
         running_entry,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    cond do
      deactivated_running_entry?(running_entry) ->
        enqueue_after_reactivate(
          state,
          running_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      paused_running_entry?(running_entry) ->
        enqueue_after_resume(
          state,
          running_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      true ->
        do_enqueue_running_operator_message(
          state,
          running_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )
    end
  end

  # Mirrors `enqueue_after_resume/7` for the `:deactivated → :working`
  # transition. The fresh agent task spawned by `reactivate_issue/2`
  # will pick up the queued operator message when it boots.
  defp enqueue_after_reactivate(
         state,
         running_entry,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    case reactivate_issue(state, running_entry) do
      {{:ok, :reactivated}, next_state} ->
        reactivated_entry = find_running_by_identifier(next_state.running, issue_identifier)

        do_enqueue_running_operator_message(
          next_state,
          reactivated_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      {{:error, _reason} = error, next_state} ->
        {error, next_state}
    end
  end

  defp enqueue_after_resume(
         state,
         running_entry,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    case resume_paused_issue(state, running_entry) do
      {{:ok, :resumed}, next_state} ->
        resumed_entry = find_running_by_identifier(next_state.running, issue_identifier)

        do_enqueue_running_operator_message(
          next_state,
          resumed_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      {{:error, _reason} = error, next_state} ->
        {error, next_state}
    end
  end

  defp do_enqueue_running_operator_message(
         state,
         running_entry,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    capabilities = issue_control_capabilities(state, issue_identifier)

    case normalize_delivery_request(delivery_policy, fallback, capabilities) do
      {:ok, queue_opts} ->
        {queue_store, item} =
          AgentQueue.operator_message(
            issue_identifier,
            text,
            Keyword.put(queue_opts, :turn_id, turn_id)
          )
          |> then(&AgentQueueStore.enqueue(state.queue_store, &1))

        # NOTE: previously we emitted a `chat.send` alert here for every
        # operator message. That alert was pure noise — it duplicated
        # the `[user]` line the pane already renders and added a
        # `[alert] chat.send: Message sent` row plus a log line for
        # every keystroke-submitted message. Removed.

        next_state = %{state | queue_store: queue_store}
        notify_running_queue_update(running_entry, item)
        {{:ok, item.id}, next_state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  # `:auto` lets the caller defer to the backend: the persistent REPL takes
  # operator messages immediately mid-turn; everything else holds at a safe
  # checkpoint (native codex/headless-claude turn UX).
  defp normalize_delivery_request(:auto, _fallback, %{immediate_delivery: true}) do
    {:ok, [delivery_policy: :immediate]}
  end

  defp normalize_delivery_request(:auto, _fallback, _capabilities) do
    {:ok, [delivery_policy: :checkpoint]}
  end

  defp normalize_delivery_request(:immediate, _fallback, %{immediate_delivery: true}) do
    {:ok, [delivery_policy: :immediate]}
  end

  defp normalize_delivery_request(:immediate, _fallback, _capabilities) do
    {:error, :immediate_not_supported}
  end

  defp normalize_delivery_request(:checkpoint, _fallback, _capabilities) do
    {:ok, [delivery_policy: :checkpoint]}
  end

  defp normalize_delivery_request(:interrupt, fallback, %{can_interrupt: true}) do
    {:ok, [delivery_policy: :interrupt, fallback: fallback]}
  end

  defp normalize_delivery_request(:interrupt, :queue_next, _capabilities) do
    {:ok, [delivery_policy: :checkpoint, fallback: :queue_next]}
  end

  defp normalize_delivery_request(:interrupt, _fallback, _capabilities) do
    {:error, :interrupt_not_supported}
  end

  defp normalize_delivery_request(_other, _fallback, _capabilities) do
    {:error, :invalid_message}
  end

  defp maybe_emit_agent_control_alert(:working, :paused, running_entry)
       when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.agent.paused",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Agent paused and may need operator input before continuing.",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp maybe_emit_agent_control_alert(:paused, :working, running_entry)
       when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.agent.unpaused",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Agent resumed; no operator action is needed.",
      needs_attention: false,
      severity: "info"
    )
  end

  defp maybe_emit_agent_control_alert(_previous_status, _status, _running_entry), do: :ok

  defp validate_operator_message(body) do
    text = String.trim(body)

    cond do
      text == "" -> {:error, :empty_message}
      String.length(text) > @max_operator_message_chars -> {:error, :message_too_long}
      true -> {:ok, text}
    end
  end

  defp send_running_control_message(state, issue_identifier, build_message) do
    case find_running_by_identifier(state.running, issue_identifier) do
      nil ->
        {:error, :no_running_agent}

      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          request_id = :erlang.unique_integer([:positive])
          send(pid, build_message.(request_id))
          {:ok, request_id}
        else
          {:error, :agent_finished}
        end

      _ ->
        {:error, :agent_finished}
    end
  end

  defp notify_running_queue_update(%{pid: pid} = running_entry, item) when is_pid(pid) do
    if Process.alive?(pid) do
      send(
        pid,
        {:agent_queue_updated, item.target_issue_identifier, item.id, deliver_now?(running_entry, item)}
      )
    end

    :ok
  end

  defp notify_running_queue_update(_running_entry, _item), do: :ok

  defp deliver_now?(running_entry, item) do
    queue_wake_required?(running_entry) or
      item.delivery[:interrupt_requested] == true or
      item.delivery[:immediate] == true
  end

  defp event_digest_delivery_opts(running_entry, event_or_events) do
    if queue_wake_required?(running_entry) or
         trusted_comment_wake_required?(running_entry, event_or_events) do
      [source: :system, priority: :now, interrupt_requested: true]
    else
      [source: :system]
    end
  end

  defp trusted_comment_wake_required?(running_entry, event_or_events) do
    active_running_entry?(running_entry) and trusted_comment_event_digest?(event_or_events)
  end

  defp trusted_comment_event_digest?(events) when is_list(events) do
    Enum.any?(events, &trusted_comment_event_digest?/1)
  end

  defp trusted_comment_event_digest?(event) when is_map(event) do
    comment_event_topic?(event) and trusted_comment_event?(event) and
      not benign_review_pass_comment?(event)
  end

  defp trusted_comment_event_digest?(_event), do: false

  defp comment_event_topic?(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic")

    if is_binary(topic) do
      case classify_event_topic(topic) do
        {:pr_review_comment, _identifier} -> true
        {:issue_commented, _identifier} -> true
        _ -> false
      end
    else
      false
    end
  end

  defp queue_wake_required?(running_entry) do
    sleeping_running_entry?(running_entry) or
      (active_running_entry?(running_entry) and no_active_turn?(running_entry))
  end

  defp no_active_turn?(%{identifier: identifier}) when is_binary(identifier) do
    ActiveTurns.active_turn_ids(identifier) == []
  end

  defp no_active_turn?(_running_entry), do: false

  defp resume_issue(%State{} = state, issue_identifier) do
    case find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        cond do
          deactivated_running_entry?(running_entry) ->
            reactivate_issue(state, running_entry)

          paused_running_entry?(running_entry) ->
            resume_paused_issue(state, running_entry)

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
    if active_running_count(state.running) >= max_concurrent_agent_limit(state) do
      {{:error, :max_concurrent_agents_reached}, state}
    else
      do_reactivate(state, running_entry)
    end
  end

  # Pause-key behaviour, split out so the GenServer clause stays at
  # max-depth 2. A `:deactivated` row has no live pid to pause; we
  # return `:already_inactive` and rely on `:resume_agent` to handle
  # the wake path on the same space-key.
  defp pause_agent_reply(state, issue_identifier) do
    case find_running_by_identifier(state.running, issue_identifier) do
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
    if deactivated_running_entry?(running_entry) do
      {{:error, :already_inactive}, state}
    else
      reply = send_pause_control_message(state, issue_identifier)
      {reply, transition_control_status(state, running_entry, :paused, "operator.pause")}
    end
  end

  defp send_pause_control_message(state, issue_identifier) do
    send_running_control_message(state, issue_identifier, fn request_id ->
      {:pause_agent, request_id}
    end)
  end

  # Out-of-band interrupt: send Ctrl+C straight to the REPL pane so Claude
  # cuts its active turn and its native queue drains the waiting message.
  # Only the persistent-REPL backend exposes a pane to interrupt; every
  # other backend folds operator input at a turn boundary instead, so they
  # report `:interrupt_not_supported`.
  defp interrupt_agent_reply(state, issue_identifier) do
    case find_running_by_identifier(state.running, issue_identifier) do
      %{repl_pane_id: pane_id} when is_binary(pane_id) ->
        ReplAgent.interrupt(%{tmux: Aiur.Tmux, pane_id: pane_id})

      running_entry when is_map(running_entry) ->
        {:error, :interrupt_not_supported}

      _ ->
        {:error, :not_running}
    end
  end

  # Operator pressed Ctrl+C on the agent's opencode pane. The action is
  # derived from the agent's live state, matching the Claude/Codex mental
  # model: a queued message drains right away, an idle agent pauses, and a
  # second press on an already-paused agent closes the pane (the caller
  # performs the kill; the agent stays parked and paused). Only the
  # persistent-REPL backend exposes a pane to drain, so other backends
  # report `:interrupt_not_supported` and the caller falls back to a plain
  # pane close.
  defp pane_interrupt_reply(state, issue_identifier) do
    case find_running_by_identifier(state.running, issue_identifier) do
      %{repl_pane_id: pane_id} = entry when is_binary(pane_id) ->
        action =
          pane_interrupt_action(
            paused_running_entry?(entry),
            queue_depth_for_issue(state, issue_identifier)
          )

        perform_pane_interrupt(action, state, entry, issue_identifier, pane_id)

      running_entry when is_map(running_entry) ->
        # opencode/codex own their queue and turn; Aiur cannot see them via
        # AgentQueueStore. The one turn-activity signal Aiur owns is
        # ActiveTurns — a live aiur-mediated codex turn registers there. So a
        # Ctrl+C on a working agent sends opencode's native interrupt (the
        # caller forwards Esc to the pane), which drains its queued message and
        # keeps it working. Only a genuinely idle agent pauses; a second press
        # on the now-paused agent closes the pane.
        working? = ActiveTurns.active_turn_ids(issue_identifier) != []

        action =
          pane_interrupt_action_no_pane(
            paused_running_entry?(running_entry),
            working?
          )

        perform_pane_interrupt(action, state, running_entry, issue_identifier, nil)

      _ ->
        {{:error, :not_running}, state}
    end
  end

  defp perform_pane_interrupt(:close_pane, state, _entry, _issue_identifier, _pane_id),
    do: {{:ok, :close_pane}, state}

  # The agent is mid-turn. opencode owns the interrupt: the bridge forwards its
  # native interrupt key (Esc) to the pane, which drains opencode's queued
  # operator message and continues the turn. Aiur mutates no state — it does
  # not flip control status or send a pause message — and the bridge keeps the
  # pane open on this reply.
  defp perform_pane_interrupt(:send_interrupt, state, _entry, _issue_identifier, _pane_id),
    do: {{:ok, :send_interrupt}, state}

  defp perform_pane_interrupt(:interrupt, state, _entry, _issue_identifier, pane_id) do
    # `:interrupt` is only ever chosen when a message is queued. The hardware
    # interrupt is best-effort: a failure (repl pane already gone, tmux hiccup)
    # must not close the pane out from under the pending message — propagating
    # the error makes the bridge controller map it to :close_pane and the
    # helper kill the pane, dropping the queued input. Keep the pane open so
    # the message folds at the next turn boundary.
    _ = ReplAgent.interrupt(%{tmux: Aiur.Tmux, pane_id: pane_id})
    {{:ok, :interrupted}, state}
  end

  # Optimistically flip the entry to `:paused` (mirrors `maybe_pause_on_request`)
  # so a second Ctrl+C reads the agent as paused and closes the pane. An idle
  # agent emits no `:worker_control_state :paused` confirmation, so depending on
  # that async signal alone would strand the agent reporting `:pause` forever
  # and the close branch would never be reachable. The queued control message
  # still drives the worker loop when it is mid-turn; its reply is ignored
  # because the optimistic transition is the source of truth for the UI.
  defp perform_pane_interrupt(:pause, state, entry, issue_identifier, _pane_id) do
    _ = send_pause_control_message(state, issue_identifier)
    {{:ok, :paused}, transition_control_status(state, entry, :paused, "pane.ctrl_c.pause")}
  end

  @doc """
  Pure 3-state Ctrl+C decision. A paused agent closes its pane; an agent
  with a queued message drains it; an idle agent pauses. Public so the
  mapping can be unit-tested without scaffolding the REPL pane or queue.
  """
  @spec pane_interrupt_action(boolean(), non_neg_integer()) ::
          :close_pane | :interrupt | :pause
  def pane_interrupt_action(paused?, queue_depth)
      when is_boolean(paused?) and is_integer(queue_depth) do
    cond do
      paused? -> :close_pane
      queue_depth > 0 -> :interrupt
      true -> :pause
    end
  end

  @doc """
  Pure Ctrl+C decision for backends with no Aiur-interruptible pane
  (codex/opencode), which own their own queue and turn. `working?` is the
  ActiveTurns signal: true when a live aiur-mediated turn is in flight. A
  working agent gets opencode's native interrupt forwarded (the caller sends
  Esc to the pane) so its queued message drains and it keeps working — Aiur
  takes no destructive action and mutates no state. A genuinely idle agent
  pauses (pane stays open); a second press on the now-paused agent closes it.
  Public so the mapping can be unit-tested without scaffolding a worker.
  """
  @spec pane_interrupt_action_no_pane(boolean(), boolean()) ::
          :send_interrupt | :close_pane | :pause
  def pane_interrupt_action_no_pane(paused?, working?)
      when is_boolean(paused?) and is_boolean(working?) do
    cond do
      paused? -> :close_pane
      working? -> :send_interrupt
      true -> :pause
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
    state = refresh_tracked_set(state)

    Logger.info("Reactivating deactivated issue: identifier=#{Map.get(running_entry, :identifier)}; spawning fresh agent task")

    # Reactivation is a deliberate operator restart; clear the thrash
    # budget so the fresh task starts with a full window.
    state = reset_thrash_budget(state, issue_id)

    {{:ok, :reactivated}, do_dispatch_issue(state, issue, nil, worker_host)}
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
      active_running_count(state.running) >= max_concurrent_agent_limit(state) ->
        {{:error, :max_concurrent_agents_reached}, state}

      not state_slots_available?(Map.get(running_entry, :issue), state) ->
        {{:error, :max_concurrent_agents_reached}, state}

      not resume_worker_slot_available?(state, Map.get(running_entry, :worker_host)) ->
        {{:error, :max_concurrent_agents_reached}, state}

      true ->
        send_resume_control_message(state, running_entry, operator?)
    end
  end

  defp send_resume_control_message(%State{} = state, running_entry, operator?) do
    case send_running_control_message(state, Map.get(running_entry, :identifier), fn request_id ->
           {:resume_agent, request_id}
         end) do
      {:ok, _request_id} ->
        issue_id = get_in(running_entry, [:issue, Access.key(:id)])
        previous_status = get_in(running_entry, [:control, :status]) || :working
        now = DateTime.utc_now()
        state = put_running_control_status(state, issue_id, :working)
        state = update_in(state.running, &thaw_pause_clock(&1, issue_id, previous_status, now))
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
        state = reset_thrash_budget(state, issue_id)
        # Sync-flip happens here so the cap accounting stays consistent.
        # That means the worker's later `:worker_control_state :working`
        # confirmation finds previous_status already :working and emits
        # no transition alert — so emit the unpause alert ourselves now.
        updated_entry = Map.get(state.running, issue_id, running_entry)
        maybe_emit_agent_control_alert(previous_status, :working, updated_entry)
        {{:ok, :resumed}, state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp reset_last_codex_timestamp(running, issue_id, %DateTime{} = now) when is_map(running) do
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
  defp reset_duration_clock_if_capped(running, issue_id, %DateTime{} = now, operator?)
       when is_map(running) do
    case Map.get(running, issue_id) do
      %{paused_reason: :max_agent_duration} = entry ->
        updated =
          entry
          |> maybe_reset_started_at(now, operator?)
          |> Map.delete(:paused_reason)

        Map.put(running, issue_id, updated)

      %{paused_reason: :label_override} = entry ->
        Map.put(running, issue_id, Map.delete(entry, :paused_reason))

      _ ->
        running
    end
  end

  defp maybe_reset_started_at(entry, now, true), do: Map.put(entry, :started_at, now)
  defp maybe_reset_started_at(entry, _now, false), do: entry

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
        update_in(state.running, &reset_last_codex_timestamp(&1, issue_id, DateTime.utc_now()))
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
  defp thaw_pause_clock(running, issue_id, previous_status, now), do: State.thaw_pause_clock(running, issue_id, previous_status, now)

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
      active_running_count(state.running) >= max_concurrent_agent_limit(state) ->
        {{:error, :max_concurrent_agents_reached}, state}

      not dispatch_candidate?(issue, state, active_state_set(), terminal_state_set()) ->
        {{:error, :not_resumable}, state}

      true ->
        next_state = dispatch_issue(state, issue)

        if MapSet.member?(next_state.claimed, issue.id) do
          {{:ok, :started}, next_state}
        else
          {{:error, :dispatch_failed}, next_state}
        end
    end
  end

  defp put_running_control_status(%State{} = state, issue_id, status)
       when is_binary(issue_id) and status in [:paused, :working] do
    update_in(state.running, fn running ->
      case Map.get(running, issue_id) do
        nil -> running
        entry -> Map.put(running, issue_id, put_in(entry, [:control, :status], status))
      end
    end)
  end

  defp put_running_control_status(%State{} = state, _issue_id, _status), do: state

  defp resume_worker_slot_available?(state, worker_host), do: Slots.resume_worker_slot_available?(state, worker_host)

  defp queue_depth_for_issue(%State{} = state, issue_identifier)
       when is_binary(issue_identifier) do
    state.queue_store
    |> AgentQueueStore.list_pending(issue_identifier)
    |> length()
  end

  defp pending_operator_messages_for_issue(%State{} = state, issue_identifier)
       when is_binary(issue_identifier) do
    state.queue_store
    |> AgentQueueStore.list_visible_operator_messages(issue_identifier)
    |> Enum.map(fn item ->
      %{
        id: item.id,
        # item is an %AgentQueueItem{} struct (no Access), so reach into its body
        # map directly rather than via get_in/2 — the latter crashed the whole
        # Orchestrator whenever the dashboard rendered an issue with a visible
        # operator message.
        text: operator_item_text(item),
        status: item.status
      }
    end)
  end

  defp operator_item_text(%{body: %{text: text}}) when is_binary(text), do: text
  defp operator_item_text(_item), do: ""

  defp issue_control_capabilities(%State{} = state, issue_identifier)
       when is_binary(issue_identifier) do
    running_entry = find_running_by_identifier(state.running, issue_identifier)
    can_interrupt = get_in(running_entry || %{}, [:control, :can_interrupt]) == true
    safe_checkpoints = get_in(running_entry || %{}, [:control, :safe_checkpoints]) || []
    immediate_delivery = get_in(running_entry || %{}, [:control, :immediate_delivery]) == true
    accepts_operator_messages = not is_nil(running_entry)

    %{
      accepts_operator_messages: accepts_operator_messages,
      can_interrupt: can_interrupt,
      immediate_delivery: immediate_delivery,
      accepted_delivery_policies: accepted_delivery_policies(can_interrupt, immediate_delivery),
      safe_checkpoints: safe_checkpoints,
      status: get_in(running_entry || %{}, [:control, :status]) || :working,
      queue_depth: queue_depth_for_issue(state, issue_identifier)
    }
  end

  # The REPL backend forwards operator messages straight into the live
  # process, so it offers :immediate instead of the hold-then-deliver
  # :checkpoint / :interrupt policies.
  defp accepted_delivery_policies(_can_interrupt, true), do: [:immediate]
  defp accepted_delivery_policies(true, false), do: [:checkpoint, :interrupt]
  defp accepted_delivery_policies(false, false), do: [:checkpoint]

  # ----------------------------------------------------------- remote control

  defp set_remote_control_reply(state, issue_identifier, on?) do
    case find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        if on?,
          do: promote_to_remote(state, running_entry),
          else: demote_from_remote(state, running_entry)

      _ ->
        {{:error, :not_running}, state}
    end
  end

  # Promote any running agent (headless `claude` or `codex`) to remote control:
  # add the durable `model:remote` label, stop the current agent, and
  # re-dispatch the same issue. The re-dispatch resolves `claude-repl` + forced
  # RC (the alias from `CodingAgent`) and resumes the transcript by cwd, so the
  # operator gets a persistent REPL with RC attached on the same conversation.
  defp promote_to_remote(state, running_entry) do
    issue = Map.get(running_entry, :issue)
    workspace = Map.get(running_entry, :workspace_path)

    cond do
      # Already remote (label present) — toggling on again is a no-op.
      CodingAgent.remote_control_forced?(issue) ->
        {{:ok, :on}, state}

      # v1 is local-only: a remote worker_host means the RC session would
      # attach on the wrong machine.
      not is_nil(Map.get(running_entry, :worker_host)) ->
        {{:error, :remote_unsupported}, state}

      is_nil(workspace) ->
        {{:error, :workspace_unavailable}, state}

      true ->
        # Trust the workspace before tearing down the current agent. If trust
        # fails RC can't attach, so abort with the current agent intact rather
        # than stranding the issue with no running agent.
        case RemoteControl.ensure_workspace_trusted(workspace, remote_control_trust_opts()) do
          :ok ->
            do_promote_to_remote(state, running_entry, issue)

          {:error, reason} ->
            Logger.error("Remote Control promote trust failed: #{rc_log_context(running_entry)} workspace=#{workspace} reason=#{inspect(reason)}")

            {{:error, {:rc_trust_failed, reason}}, state}
        end
    end
  end

  defp do_promote_to_remote(state, running_entry, issue) do
    label = CodingAgent.remote_control_alias_label()

    case Tracker.add_label(Map.get(running_entry, :identifier), label) do
      :ok ->
        relabeled = add_issue_label(issue, label)
        state = teardown_for_redispatch(state, running_entry)

        Logger.info("Remote Control promote; re-dispatching with model:remote: #{rc_log_context(running_entry)}")

        {{:ok, :on}, do_dispatch_issue(state, relabeled, nil, nil)}

      {:error, reason} ->
        Logger.error("Remote Control promote label-add failed: #{rc_log_context(running_entry)} reason=#{inspect(reason)}")

        {{:error, {:rc_label_failed, reason}}, state}
    end
  end

  # Demote a remote-control agent back to the default backend: remove the
  # label, stop the current REPL agent, and re-dispatch. `r` is a true toggle.
  defp demote_from_remote(state, running_entry) do
    issue = Map.get(running_entry, :issue)

    cond do
      # Not remote (no label) — toggling off again is a no-op.
      not CodingAgent.remote_control_forced?(issue) ->
        {{:ok, :off}, state}

      is_nil(Map.get(running_entry, :workspace_path)) ->
        {{:error, :workspace_unavailable}, state}

      true ->
        label = CodingAgent.remote_control_alias_label()

        case Tracker.remove_label(Map.get(running_entry, :identifier), label) do
          :ok ->
            relabeled = remove_issue_label(issue, label)
            state = teardown_for_redispatch(state, running_entry)

            Logger.info("Remote Control demote; re-dispatching as default backend: #{rc_log_context(running_entry)}")

            {{:ok, :off}, do_dispatch_issue(state, relabeled, nil, nil)}

          {:error, reason} ->
            Logger.error("Remote Control demote label-remove failed: #{rc_log_context(running_entry)} reason=#{inspect(reason)}")

            {{:error, {:rc_label_failed, reason}}, state}
        end
    end
  end

  # Stop the current agent cleanly so the same issue can be re-dispatched under
  # a different backend. Mirrors `terminate_running_issue/3`'s task-teardown
  # half (stop RC, kill the REPL pane+pid, close chat streams, demonitor, kill
  # the task) but KEEPS the entry in `state.running` and does NOT clean the
  # workspace or release the claim — the workspace is reused so the re-dispatched
  # agent resumes the transcript by cwd. Demonitor BEFORE killing so the agent
  # :DOWN handler doesn't fire a retry that re-dispatches underneath us.
  defp teardown_for_redispatch(state, running_entry) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    identifier = Map.get(running_entry, :identifier)
    pid = Map.get(running_entry, :pid)
    ref = Map.get(running_entry, :ref)

    kill_repl_session(running_entry)
    close_active_chat_streams(identifier, :remote_control)
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    if is_pid(pid), do: terminate_task(pid)

    cleared =
      running_entry
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)

    %{
      state
      | running: Map.put(state.running, issue_id, cleared),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp add_issue_label(%Issue{labels: labels} = issue, label) do
    down = String.downcase(label)
    if down in labels, do: issue, else: %{issue | labels: labels ++ [down]}
  end

  defp remove_issue_label(%Issue{labels: labels} = issue, label) do
    down = String.downcase(label)
    %{issue | labels: Enum.reject(labels, &(&1 == down))}
  end

  defp rc_log_context(entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{Map.get(entry, :identifier)}"
  end

  # Tests redirect the trust-config write off the real `~/.claude.json`.
  defp remote_control_trust_opts do
    case Application.get_env(:aiur, :remote_control_claude_json) do
      path when is_binary(path) -> [path: path]
      _ -> []
    end
  end

  # Kill the persistent-REPL pane + claude OS pid tracked on the running
  # entry. Idempotent and tolerant of a half-dead session (pane gone but
  # pid alive, or vice versa) — each kill is independent and a missing
  # pane/pid is a no-op.
  defp kill_repl_session(running_entry) do
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

  # The indicator reflects a *live* remote session, not the label. The REPL
  # only earns RC mode when it actually attaches and prints its
  # `https://claude.ai/code/session_…` banner, which the runner forwards to
  # `:repl_rc_session_url` (a capability token, never logged). A labeled issue
  # whose RC never attached — degraded to headless, or routed to a backend that
  # has no RC path at all (codex) — has no URL, so it shows no phone icon.
  defp remote_control_summary(entry) do
    issue = Map.get(entry, :issue)

    with true <- is_map(issue) and match?(%Issue{}, issue),
         true <- CodingAgent.remote_control_forced?(issue),
         url when is_binary(url) <- Map.get(entry, :repl_rc_session_url) do
      %{status: :on, session_url: url}
    else
      _ -> nil
    end
  end

  defp cleanup_stray_remote_control_servers do
    RemoteControl.reap_orphaned_servers()
    ReplAgent.reap_orphaned_panes()
  rescue
    _ -> :ok
  end

  defp issue_tag(issue), do: State.issue_tag(issue)
  defp find_running_by_identifier(running, issue_identifier), do: State.find_running_by_identifier(running, issue_identifier)
  defp find_running_by_repl_pane_id(running, pane_id), do: State.find_running_by_repl_pane_id(running, pane_id)

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    agent_input_tokens = Map.get(running_entry, :agent_input_tokens, 0)
    agent_output_tokens = Map.get(running_entry, :agent_output_tokens, 0)
    agent_total_tokens = Map.get(running_entry, :agent_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :agent_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :agent_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :agent_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        agent_input_tokens: agent_input_tokens + token_delta.input_tokens,
        agent_output_tokens: agent_output_tokens + token_delta.output_tokens,
        agent_total_tokens: agent_total_tokens + token_delta.total_tokens,
        agent_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        agent_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        agent_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

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

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id), do: State.pop_running_entry(state, issue_id)

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    agent_totals =
      apply_token_delta(
        state.agent_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | agent_totals: agent_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_seconds * 1_000,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp sync_todo_capacity_alert(%State{} = state, issues) when is_list(issues) do
    todo_issues = routable_todo_issues(issues)

    over_capacity? = length(todo_issues) > max_concurrent_agent_limit(state)

    cond do
      over_capacity? and not state.todo_over_capacity_alert_active ->
        emit_todo_capacity_alert(state, todo_issues)
        %{state | todo_over_capacity_alert_active: true}

      not over_capacity? and state.todo_over_capacity_alert_active ->
        %{state | todo_over_capacity_alert_active: false}

      true ->
        state
    end
  end

  defp sync_todo_capacity_alert(%State{} = state, _issues), do: state

  defp routable_todo_issues(issues) when is_list(issues) do
    issues
    |> Enum.filter(fn
      %Issue{} = issue ->
        normalize_issue_state(issue.state) == "todo" and
          not Issue.paused?(issue) and
          issue_routable_to_worker?(issue) and
          !todo_issue_blocked_by_non_terminal?(issue, terminal_state_set())

      _ ->
        false
    end)
    |> sort_issues_for_dispatch()
  end

  defp emit_todo_capacity_alert(%State{} = state, todo_issues) when is_list(todo_issues) do
    case List.first(todo_issues) do
      %Issue{} = issue ->
        Alerts.emit_system("system.dispatch.todo_capacity_exceeded",
          issue: issue,
          worker_host: running_worker_host(state, issue.id),
          reason: "Todo issue count exceeds the current dispatch capacity.",
          needs_attention: true,
          severity: "warning"
        )

      _ ->
        Alerts.emit_system("system.dispatch.todo_capacity_exceeded",
          reason: "Todo issue count exceeds the current dispatch capacity.",
          needs_attention: true,
          severity: "warning"
        )
    end
  end

  @doc false
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
         %{agent_totals: agent_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | agent_totals: apply_token_delta(agent_totals, token_delta)}
  end

  defp apply_agent_token_delta(state, _token_delta), do: state

  defp apply_agent_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | agent_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_agent_rate_limits(state, _update), do: state

  defp apply_token_delta(nil, token_delta),
    do: apply_token_delta(@empty_agent_totals, token_delta)

  defp apply_token_delta(agent_totals, token_delta) do
    input_tokens = Map.get(agent_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(agent_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(agent_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(agent_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :agent_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :agent_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :agent_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(started_at, now), do: State.running_seconds(started_at, now)
  defp effective_runtime_seconds(entry, now), do: State.effective_runtime_seconds(entry, now)

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

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

  # Drain-time coalescing: pending `:events_digest` items for the same
  # identifier fold into a single delivery, so an agent that had three
  # events subscribed during a long turn sees ONE `<aiur:events>` block,
  # not three separate ones. Granularity is preserved upstream (one
  # queue item per publish so `[event:consumed]` markers and cursor
  # advance still reflect individual events); coalescing happens only
  # at the drain boundary.
  defp coalesce_events_digests(queue_store, issue_identifier, first_item) do
    do_coalesce_events_digests(queue_store, issue_identifier, first_item)
  end

  defp do_coalesce_events_digests(queue_store, issue_identifier, acc_item) do
    {next_store, next_item} =
      AgentQueueStore.claim_next_deliverable_matching(
        queue_store,
        issue_identifier,
        fn item -> match?(%{category: :coordination_event, event_type: :events_digest}, item) end
      )

    case next_item do
      nil ->
        {next_store, acc_item}

      %{} = item ->
        merged = merge_events_digest_items(acc_item, item)
        do_coalesce_events_digests(next_store, issue_identifier, merged)
    end
  end

  defp merge_events_digest_items(first, next) do
    first_events = first.body |> Map.get(:events, []) |> List.wrap()
    next_events = next.body |> Map.get(:events, []) |> List.wrap()

    sorted =
      (first_events ++ next_events)
      |> Enum.uniq_by(&event_dedupe_key/1)
      |> Enum.sort_by(&event_sort_key/1)

    new_body =
      first.body
      |> Map.put(:events, sorted)
      |> Map.put(:summary, event_digest_summary(%{events: sorted}))

    %{first | body: new_body}
  end

  defp event_sort_key(%{id: id}) when is_integer(id), do: id
  defp event_sort_key(%{"id" => id}) when is_integer(id), do: id
  defp event_sort_key(_), do: 0

  defp event_dedupe_key(event) when is_map(event) do
    topic = event_topic(event)

    case {comment_event_topic?(event), event_comment_id(event), event_sort_key(event)} do
      {true, id, _} when is_integer(id) -> {topic, :comment, id}
      {_, _, id} when is_integer(id) and id > 0 -> {topic, :event, id}
      _ -> event
    end
  end

  defp event_dedupe_key(event), do: event

  defp event_topic(event) when is_map(event),
    do: Map.get(event, :topic) || Map.get(event, "topic")

  defp event_comment_id(event) when is_map(event) do
    comment = Map.get(event, :comment) || Map.get(event, "comment") || %{}
    Map.get(comment, :id) || Map.get(comment, "id")
  end

  # Asymmetric auto-subscribe: when the orchestrator's poll observes a new blocker on
  # `issue.blocked_by`, asymmetrically auto-subscribe both sides:
  # - blockee subscribes to the actionable subset of the blocker's events
  # - blocker subscribes to blockee's block-state events only
  # See origin: docs/brainstorms/2026-05-24-aiur-event-publishing-
  # subscriptions-requirements.md (Subscriptions section). Idempotent via
  # SubscriptionStore.add_subscription's existing duplicate short-circuit.
  defp auto_subscribe_for_dependency(blockee, blocker) when is_map(blocker) do
    with blockee_identifier when is_binary(blockee_identifier) <- blockee_identifier_for(blockee),
         blocker_identifier when is_binary(blocker_identifier) <- blocker_identifier_for(blocker) do
      attach_and_subscribe(
        blockee_identifier,
        default_blockee_subscriptions(blocker_identifier),
        "blocker:auto"
      )

      attach_and_subscribe(
        blocker_identifier,
        default_blocker_subscriptions(blockee_identifier),
        "blockee:auto"
      )
    end

    :ok
  end

  defp auto_subscribe_for_dependency(_blockee, _blocker), do: :ok

  @doc """
  Attach the standard blocker→blockee subscription pair WITHOUT
  going through GitHub poll detection. Called from
  `Aiur.AgentRunner.declare_blocker_for_issue/2` so the subscription
  goes in the SubscriptionStore at declare-time, not on the next
  reconcile tick after GitHub eventually surfaces the dependency.

  This matters because:
    * `IssueDependencies.declare/2` posts to GitHub's `/issues/.../dependencies`
      API and may return `:already_present` for a stale dependency
      that GitHub later mutates away (PR close + open cycle has been
      observed to drop the dependency).
    * Without the direct subscribe, the blockee's SubscriptionStore
      never receives `ticket.<blocker>.branch.push`, so when the
      blocker pushes the orchestrator's `subscribed_to_topic?/2`
      check returns false and the blockee never auto-resumes.

  Idempotent: SubscriptionStore.add_subscription short-circuits on
  duplicate `(identifier, topic)`.
  """
  @spec subscribe_for_declared_blocker(String.t() | integer(), String.t() | integer()) :: :ok
  def subscribe_for_declared_blocker(blockee_identifier, blocker_identifier) do
    blockee_str = to_string(blockee_identifier)
    blocker_str = to_string(blocker_identifier)

    attach_and_subscribe(
      blockee_str,
      default_blockee_subscriptions(blocker_str),
      "blocker:auto"
    )

    attach_and_subscribe(
      blocker_str,
      default_blocker_subscriptions(blockee_str),
      "blockee:auto"
    )

    :ok
  end

  defp auto_unsubscribe_for_dependency(blockee, blocker) when is_map(blocker) do
    with blockee_identifier when is_binary(blockee_identifier) <- blockee_identifier_for(blockee),
         blocker_identifier when is_binary(blocker_identifier) <- blocker_identifier_for(blocker) do
      remove_auto_subscriptions(
        blockee_identifier,
        default_blockee_subscriptions(blocker_identifier),
        "blocker:auto"
      )

      remove_auto_subscriptions(
        blocker_identifier,
        default_blocker_subscriptions(blockee_identifier),
        "blockee:auto"
      )
    end

    :ok
  end

  defp auto_unsubscribe_for_dependency(_blockee, _blocker), do: :ok

  defp attach_and_subscribe(identifier, topics, reason) do
    :ok = SubscriptionStore.attach(identifier)

    Enum.each(topics, fn topic ->
      _ = SubscriptionStore.add_subscription(identifier, topic, reason)
    end)
  end

  defp remove_auto_subscriptions(identifier, topics, expected_reason) do
    Enum.each(topics, fn topic ->
      _ = SubscriptionStore.remove_subscription(identifier, topic, expected_reason)
    end)
  end

  defp default_blockee_subscriptions(blocker_identifier) when is_binary(blocker_identifier) do
    base = "ticket." <> blocker_identifier

    # Topic strings must match the publisher source modules literally
    # (Exchange routes by literal segment match):
    #   LsRemoteTicker        -> ticket.<N>.branch.push
    #   GithubCommentsPoller  -> ticket.<N>.issue.commented / pr.review_comment
    #   GithubFirehose        -> ticket.<N>.pr.{opened,merged,closed,…}
    [
      base <> ".branch.push",
      base <> ".branch.force-push",
      base <> ".pr.opened",
      base <> ".pr.merged",
      base <> ".agent.decision.*",
      base <> ".agent.blocked",
      base <> ".agent.unblocked",
      base <> ".agent.attention.*",
      base <> ".issue.commented"
    ]
  end

  defp default_blocker_subscriptions(blockee_identifier) when is_binary(blockee_identifier) do
    base = "ticket." <> blockee_identifier

    [
      base <> ".agent.blocked",
      base <> ".agent.unblocked"
    ]
  end

  defp blockee_identifier_for(%Issue{identifier: identifier}) when is_binary(identifier),
    do: identifier

  defp blockee_identifier_for(_), do: nil

  defp blocker_identifier_for(%{identifier: identifier}) when is_binary(identifier),
    do: identifier

  defp blocker_identifier_for(%{"identifier" => identifier}) when is_binary(identifier),
    do: identifier

  defp blocker_identifier_for(_), do: nil

  # Mid-turn-drain helpers. Returns the list of direct-blocker
  # identifiers for the running ticket (small — typically 0-3).
  # Kept as a list rather than a MapSet so the consumer doesn't have
  # to navigate dialyzer's opaque-type complaints on MapSet.member?.
  defp direct_blockers_for(%State{last_polled_issues: polled}, identifier)
       when is_map(polled) do
    case Enum.find(polled, fn {_id, %Issue{identifier: i}} -> i == identifier end) do
      {_id, %Issue{} = issue} ->
        issue
        |> blocker_map()
        |> Map.values()
        |> Enum.map(&blocker_identifier_for/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp direct_blockers_for(_state, _identifier), do: []

  defp blocker_critical_digest?(
         %{category: :coordination_event, event_type: :events_digest, body: body},
         direct_blockers
       ) do
    events = Map.get(body || %{}, :events, [])
    Enum.any?(events, fn event -> blocker_critical_event?(event, direct_blockers) end)
  end

  defp blocker_critical_digest?(_item, _direct_blockers), do: false

  defp blocker_critical_event?(event, direct_blockers) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic")

    cond do
      not is_binary(topic) -> false
      Enum.empty?(direct_blockers) -> false
      true -> blocker_critical_topic?(topic, direct_blockers)
    end
  end

  defp blocker_critical_event?(_event, _direct_blockers), do: false

  defp blocker_critical_topic?(topic, direct_blockers) do
    case String.split(topic, ".") do
      ["ticket", id, "branch", "push"] -> id in direct_blockers
      ["ticket", id, "branch", "force-push"] -> id in direct_blockers
      ["ticket", id, "agent", "unblocked"] -> id in direct_blockers
      ["ticket", id, "agent", "decision", _slug] -> id in direct_blockers
      _ -> false
    end
  end
end
