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
    AgentRunner,
    Alerts,
    CodingAgent,
    Config,
    Issue,
    Tracker,
    Workspace
  }

  alias Aiur.Claude.{RemoteControl, ReplAgent}
  alias Aiur.Events.{Exchange, GithubFirehose, Publisher, SubscriptionStore}
  alias Aiur.Opencode.ActiveTurns
  alias AiurWeb.ObservabilityPubSub

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so the `0s` in-progress
  # label can render before the poll finishes.
  @poll_transition_render_delay_ms 20
  @empty_agent_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }
  @max_operator_message_chars 8_000

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    @type t :: %__MODULE__{
            poll_interval_ms: integer() | nil,
            max_concurrent_agents: integer() | nil,
            session_max_concurrent_agents: integer() | nil,
            next_poll_due_at_ms: integer() | nil,
            poll_check_in_progress: boolean() | nil,
            tick_timer_ref: reference() | nil,
            tick_token: reference() | nil,
            initial_dispatch_cycle: boolean() | nil,
            queue_store: term(),
            last_polled_issues: map(),
            todo_over_capacity_alert_active: boolean(),
            running: map(),
            completed: MapSet.t(),
            claimed: MapSet.t(),
            retry_attempts: map(),
            codex_thrash_budget: map(),
            agent_totals: map() | nil,
            agent_rate_limits: map() | nil,
            codex_totals: map() | nil,
            codex_rate_limits: map() | nil
          }

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :session_max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :initial_dispatch_cycle,
      queue_store: AgentQueueStore.new(),
      last_polled_issues: %{},
      todo_over_capacity_alert_active: false,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_thrash_budget: %{},
      agent_totals: nil,
      agent_rate_limits: nil,
      codex_totals: nil,
      codex_rate_limits: nil,
      events_etag: nil
    ]
  end

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
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      initial_dispatch_cycle: true,
      agent_totals: @empty_agent_totals,
      agent_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
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
  defp subscribe_to_orchestrator_topics do
    if Process.whereis(Exchange) do
      Exchange.subscribe("ticket.*.pr.review_comment")
      Exchange.subscribe("ticket.*.agent.pause.request")
      Exchange.subscribe("ticket.*.branch.push")
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

  @tracked_table __MODULE__.TrackedSet

  defp init_tracked_set_table do
    case :ets.whereis(@tracked_table) do
      :undefined ->
        :ets.new(@tracked_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ets.delete_all_objects(@tracked_table)
    end

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
    needle = to_string(issue_number)

    case :ets.whereis(@tracked_table) do
      :undefined -> true
      _ -> :ets.member(@tracked_table, needle)
    end
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

    :ets.delete_all_objects(@tracked_table)
    Enum.each(needles, &:ets.insert(@tracked_table, {&1, true}))
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
    state = schedule_tick(state, state.poll_interval_ms)
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

  # PR review-comment fan-out from `Aiur.Events.Exchange`. The publisher's
  # `bot_self_loop?` filter drops self-comments before they reach here,
  # so any event arriving is from an external actor (a human reviewer,
  # another agent, etc.). Reactivate the matching `:deactivated` row;
  # `:working` / `:paused` entries are left alone (the live agent is
  # already in the loop and will see the comment via its own per-ticket
  # subscription).
  def handle_info({:event, %{topic: topic} = _event}, state) when is_binary(topic) do
    case classify_event_topic(topic) do
      {:pr_review_comment, identifier} ->
        {:noreply, maybe_reactivate_on_pr_comment(state, identifier)}

      {:pause_request, identifier} ->
        {:noreply, maybe_pause_on_request(state, identifier)}

      {:branch_push, blocker_identifier} ->
        {:noreply, maybe_resume_blockees_on_push(state, blocker_identifier, topic)}

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

  defp parse_pr_review_comment_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.pr\.review_comment\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  defp parse_pause_request_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.agent\.pause\.request\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  defp parse_branch_push_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.branch\.push\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  # Single-pass topic classifier: runs each parser at most once and
  # returns a tagged tuple the caller pattern-matches on. Cheaper than
  # a `cond` that calls every parser twice (once for the match? test,
  # once to extract the identifier).
  defp classify_event_topic(topic) do
    with :nomatch <- tag_topic(:pr_review_comment, parse_pr_review_comment_topic(topic)),
         :nomatch <- tag_topic(:pause_request, parse_pause_request_topic(topic)) do
      tag_topic(:branch_push, parse_branch_push_topic(topic))
    end
  end

  defp tag_topic(tag, {:ok, identifier}), do: {tag, identifier}
  defp tag_topic(_tag, :nomatch), do: :nomatch

  defp maybe_reactivate_on_pr_comment(%State{} = state, issue_number) do
    case find_running_by_identifier(state.running, issue_number) do
      running_entry when is_map(running_entry) ->
        reactivate_if_deactivated(state, running_entry, issue_number)

      _ ->
        state
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

    case resume_paused_issue(state, entry) do
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

  defp reactivate_if_deactivated(state, running_entry, issue_number) do
    if deactivated_running_entry?(running_entry) do
      Logger.info("PR review comment reactivating: identifier=#{issue_number}")

      {_reply, next_state} = reactivate_issue(state, running_entry)
      next_state
    else
      state
    end
  end

  defp event_digest_summary(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic") || "(unknown)"
    message = Map.get(event, "message") || Map.get(event, :message) || Map.get(event, "summary")

    case message do
      m when is_binary(m) and m != "" -> "#{topic}: #{m}"
      _ -> topic
    end
  end

  defp poll_github_firehose(%State{} = state) do
    case GithubFirehose.poll(etag: state.events_etag) do
      {:ok, %{etag: etag, count: count}} ->
        if count > 0, do: Logger.debug("aiur_perf github_firehose published count=#{count}")
        %{state | events_etag: etag}

      {:error, _reason} ->
        # Preserve cached etag so we retry as If-None-Match next tick
        state
    end
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)
    state = refresh_tracked_set(state)
    state = poll_github_firehose(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      state =
        state
        |> sync_polled_issue_state(issues)
        |> sync_todo_capacity_alert(issues)

      # The poll just refreshed `last_polled_issues`, so push a fresh
      # summary out to any open agent-list pane immediately — without
      # this, the pane only sees new candidate tickets after the next
      # dispatch or completion event.
      notify_dashboard(state)

      state =
        if available_slots(state) > 0 do
          choose_issues(state, issues)
        else
          state
        end

      %{state | initial_dispatch_cycle: false}
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in .aiurconfig")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in .aiurconfig")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in .aiurconfig")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in .aiurconfig: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid .aiurconfig config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing .aiurconfig at #{path}: #{inspect(reason)}")
        state

      {:error, {:missing_prompt_file, path, reason}} ->
        Logger.error("Missing prompt_file at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse .aiurconfig: top-level YAML must be a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse .aiurconfig: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    state = reconcile_pending_auto_resumes(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
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
  @spec apply_pause_request_for_test(State.t(), String.t()) :: State.t()
  def apply_pause_request_for_test(%State{} = state, identifier) when is_binary(identifier) do
    maybe_pause_on_request(state, identifier)
  end

  @doc false
  @spec apply_branch_push_for_test(State.t(), String.t()) :: State.t()
  def apply_branch_push_for_test(%State{} = state, blocker_identifier)
      when is_binary(blocker_identifier) do
    topic = "ticket." <> blocker_identifier <> ".branch.push"
    maybe_resume_blockees_on_push(state, blocker_identifier, topic)
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
  @spec apply_thrash_check_for_test(State.t(), String.t(), integer()) :: {:ok, State.t()} | {:trip, State.t()}
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
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
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

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        maybe_reactivate_or_refresh(state, issue)

      human_review_state?(issue.state) ->
        deactivate_running_issue(state, issue.id)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  # Matches the `agent:human-review` label (after `normalize_issue_state`,
  # this is `"human-review"`). Reserved for the deactivate path — keeps the
  # running entry visible at 🏁 / 100% while releasing the slot and chat
  # pane, instead of dropping it the way the catch-all `true →` branch
  # would.
  defp human_review_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "human-review"
  end

  defp human_review_state?(_), do: false

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
  # fresh agent task is spawned. Otherwise just refresh the stored
  # issue (existing behaviour for `:working` / `:paused` entries).
  defp maybe_reactivate_or_refresh(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{control: %{status: :deactivated}} = running_entry ->
        # Update the stored issue first so the dispatched agent sees
        # the freshest label state.
        new_entry = Map.put(running_entry, :issue, issue)
        state = %{state | running: Map.put(state.running, issue.id, new_entry)}

        case reactivate_issue(state, new_entry) do
          {{:ok, :reactivated}, next_state} -> next_state
          {{:error, _reason}, next_state} -> next_state
        end

      _ ->
        refresh_running_issue_state(state, issue)
    end
  end

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
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
          cleanup_issue_workspace(identifier, worker_host)
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
  defp reconcile_pending_auto_resumes(%State{} = state) do
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

        case resume_paused_issue(state, entry) do
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

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

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

  defp last_activity_timestamp(_running_entry), do: nil

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
          enqueue_dependency_event(state_acc, issue, current_blockers[blocker_id], :dependency_added)
        end)

      state =
        Enum.reduce(removed_blocker_ids, state, fn blocker_id, state_acc ->
          auto_unsubscribe_for_dependency(issue, previous_blockers[blocker_id])
          enqueue_dependency_event(state_acc, issue, previous_blockers[blocker_id], :dependency_removed)
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

  defp emit_task_state_transition_alert(%State{} = state, %Issue{} = previous_issue, %Issue{} = issue) do
    previous_state = state_slug(previous_issue.state)
    current_state = state_slug(issue.state)

    if previous_state != current_state and current_state != nil do
      # Ticket B: label-flip alerts route through the new topic shape so
      # `alerts.yaml` can glob-match per state without one entry per state.
      Alerts.emit_system(
        "ticket.#{issue.identifier}.issue.label.added.agent.#{current_state}",
        issue: issue,
        worker_host: running_worker_host(state, issue.id)
      )
    end

    state
  end

  defp emit_task_state_transition_alert(%State{} = state, _previous_issue, _issue), do: state

  defp blocker_map(%Issue{blocked_by: blockers}) when is_list(blockers) do
    Enum.reduce(blockers, %{}, fn
      %{id: blocker_id} = blocker, acc when is_binary(blocker_id) -> Map.put(acc, blocker_id, blocker)
      _blocker, acc -> acc
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

  defp enqueue_dependency_event(%State{} = state, %Issue{} = issue, blocker, update_kind) when is_map(blocker) do
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

  defp choose_issues(state, issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    initial_dispatch_cycle? = state.initial_dispatch_cycle == true

    {state, _startup_todo_index} =
      issues
      |> sort_issues_for_dispatch()
      |> Enum.reduce({state, 0}, fn issue, {state_acc, startup_todo_index} ->
        if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
          next_state = dispatch_issue(state_acc, issue)

          startup_todo_index =
            maybe_schedule_startup_todo_alert(
              state_acc,
              next_state,
              issue,
              startup_todo_index,
              initial_dispatch_cycle?
            )

          {next_state, startup_todo_index}
        else
          {state_acc, startup_todo_index}
        end
      end)

    state
  end

  defp maybe_schedule_startup_todo_alert(previous_state, next_state, %Issue{} = issue, index, true) do
    if normalize_issue_state(issue.state) == "todo" and
         not MapSet.member?(previous_state.claimed, issue.id) and
         MapSet.member?(next_state.claimed, issue.id) do
      delay_ms = index * 1_000
      worker_host = running_worker_host(next_state, issue.id)
      topic = "ticket.#{issue.identifier}.issue.label.added.agent.todo"
      Process.send_after(self(), {:emit_system_alert, topic, issue, worker_host}, delay_ms)
      index + 1
    else
      index
    end
  end

  defp maybe_schedule_startup_todo_alert(_previous_state, _next_state, _issue, index, _initial_dispatch_cycle?),
    do: index

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    dispatch_candidate?(issue, state, active_states, terminal_states) and
      available_slots(state) > 0
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  # All dispatch preconditions except the global active+paused slot reservation.
  # Polling layers `available_slots > 0` on top of this to honor paused-agent
  # slot holds; manual start paths (e.g., space on a queued ticket) instead
  # gate on `active < max` so the operator can claim a free slot even when a
  # parallel paused agent is parked in the running map.
  defp dispatch_candidate?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      state_slots_available?(issue, state) and
      worker_slots_available?(state)
  end

  defp state_slots_available?(%Issue{state: issue_state}, %State{} = state) do
    limit = effective_state_limit(issue_state, state)
    used = running_issue_count_for_state(state.running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _state), do: false

  # Per-state cap honors explicit overrides in
  # `agent.max_concurrent_agents_by_state` first, then falls back to the
  # *session-aware* global limit. Without this, bumping the global cap at
  # runtime (←/→ in the agent list) had no effect on dispatch eligibility
  # because the per-state default was pinned to the workflow file value.
  defp effective_state_limit(issue_state, %State{} = state) do
    config = Config.settings!()
    normalized = normalize_issue_state(issue_state)
    Map.get(config.agent.max_concurrent_agents_by_state, normalized, max_concurrent_agent_limit(state))
  end

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}} = entry} ->
        normalize_issue_state(state_name) == normalized_state and active_running_entry?(entry)

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  # Nil / non-binary state happens when the GitHub poll returns an
  # issue with no `agent:*` label — extract_state returns nil. Treat
  # as 'not active' so the reconcile cond falls through to the
  # catch-all instead of crashing the orchestrator GenServer.
  defp active_issue_state?(_state_name, _active_states), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  # Same nil-safety reasoning as `active_issue_state?/2` above.
  # Direct callers (routable_todo_issues, state_slots_available?,
  # effective_state_limit, running_issue_count_for_state) all feed
  # `issue.state` here without a binary guard; without this clause
  # any unlabeled issue crashes the orchestrator.
  defp normalize_issue_state(_state_name), do: ""

  defp state_slug(state_name) when is_binary(state_name) do
    state_name
    |> normalize_issue_state()
    |> String.replace(~r/[\s_]+/, "-")
    |> case do
      "" -> nil
      slug -> slug
    end
  end

  defp state_slug(_state_name), do: nil

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    case check_thrash_budget(state, issue.id, System.monotonic_time(:millisecond)) do
      {:trip, tripped_state} ->
        trip_thrash_breaker(tripped_state, issue)

      {:ok, budgeted_state} ->
        dispatch_to_worker(budgeted_state, issue, attempt, preferred_worker_host)
    end
  end

  defp dispatch_to_worker(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  # Time-windowed restart budget. Independent of the willRetry:false
  # hard-failure path: catches thrash that never surfaces willRetry
  # (transport timeouts, sandbox refusals, future error classes that
  # still complete a turn as :normal and reschedule as a continuation,
  # bypassing max_retry_attempts). Counts (re)dispatches per issue per
  # window and trips once they exceed `codex_thrash_max_per_window`
  # within `codex_thrash_window_seconds`. Gating here, before
  # spawn_issue_on_worker_host, means a tripped attempt pays no workspace
  # clone cost. The breaker resets when the window lapses, so the issue
  # gets another window on the next poll tick.
  @spec check_thrash_budget(State.t(), String.t(), integer()) :: {:ok, State.t()} | {:trip, State.t()}
  defp check_thrash_budget(%State{} = state, issue_id, now_ms) do
    window_ms = Config.codex_thrash_window_seconds() * 1_000

    entry =
      case Map.get(state.codex_thrash_budget, issue_id) do
        %{window_start_ms: start, count: count} when now_ms - start < window_ms ->
          %{window_start_ms: start, count: count + 1}

        _ ->
          %{window_start_ms: now_ms, count: 1}
      end

    state = %{state | codex_thrash_budget: Map.put(state.codex_thrash_budget, issue_id, entry)}

    if entry.count > Config.codex_thrash_max_per_window() do
      {:trip, state}
    else
      {:ok, state}
    end
  end

  defp trip_thrash_breaker(%State{} = state, issue) do
    count = get_in(state.codex_thrash_budget, [issue.id, :count]) || 0

    Logger.warning("Codex thrash detected: issue_id=#{issue.id} issue_identifier=#{issue.identifier} restarts=#{count} window_seconds=#{Config.codex_thrash_window_seconds()}; skipping dispatch")

    Alerts.emit_system("ticket.#{issue.identifier}.agent.thrash_circuit_open", issue: issue.identifier)

    state
  end

  defp reset_thrash_budget(%State{} = state, issue_id) do
    %{state | codex_thrash_budget: Map.delete(state.codex_thrash_budget, issue_id)}
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host, orchestrator: recipient)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            repl_pane_id: nil,
            repl_os_pid: nil,
            headless_os_pid: nil,
            agent_input_tokens: 0,
            agent_output_tokens: 0,
            agent_total_tokens: 0,
            agent_last_reported_input_tokens: 0,
            agent_last_reported_output_tokens: 0,
            agent_last_reported_total_tokens: 0,
            turn_count: 0,
            control: default_running_control(issue),
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)

    if failure_retry?(metadata) and next_attempt > Config.max_retry_attempts() do
      if is_reference(old_timer), do: Process.cancel_timer(old_timer)

      error_suffix = if is_binary(error), do: " error=#{error}", else: ""

      Logger.warning(
        "Giving up on issue_id=#{issue_id} issue_identifier=#{identifier} after #{previous_retry.attempt} failed attempt(s); max_retry_attempts=#{Config.max_retry_attempts()}#{error_suffix}"
      )

      %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
    else
      delay_ms = retry_delay(next_attempt, metadata)
      retry_token = make_ref()
      due_at_ms = System.monotonic_time(:millisecond) + delay_ms

      if is_reference(old_timer), do: Process.cancel_timer(old_timer)

      timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

      error_suffix = if is_binary(error), do: " error=#{error}", else: ""

      Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

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
              worker_host: worker_host,
              workspace_path: workspace_path
            })
      }
    end
  end

  defp failure_retry?(metadata) when is_map(metadata) do
    Map.get(metadata, :delay_type) != :continuation
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard(state) do
    state
    |> running_summaries()
    |> AgentPubSub.broadcast_running_change()

    AgentPubSub.broadcast_poll_state(%{
      checking?: state.poll_check_in_progress == true,
      next_poll_due_at_ms: state.next_poll_due_at_ms,
      max_concurrent_agents: state.max_concurrent_agents
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
              work_state: :idle
            })

          entry ->
            AgentEvents.agent_summary(identifier, :running, 0, %{
              tag: tag,
              title: title,
              runtime_seconds: effective_runtime_seconds(entry, now),
              turn_count: Map.get(entry, :turn_count, 0),
              work_state: get_in(entry, [:control, :status]) || :working,
              backend: entry_backend(entry),
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
              backend: entry_backend(entry),
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
      tracker_state: Map.get(issue || %{}, :state),
      tag: issue_tag(issue),
      title: Map.get(issue || %{}, :title),
      url: Map.get(issue || %{}, :url),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      runtime_seconds: running_seconds(Map.get(entry, :started_at), now),
      queue_depth: queue_depth_for_issue(state, identifier)
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
      tag: issue_tag(issue),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      runtime_seconds: 0,
      queue_depth: idle_queue_depth(state, identifier)
    }
  end

  defp idle_queue_depth(%State{} = state, identifier) when is_binary(identifier) do
    queue_depth_for_issue(state, identifier)
  end

  defp idle_queue_depth(_state, _identifier), do: 0

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host} = entry} -> active_running_entry?(entry)
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp active_running_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, entry} -> active_running_entry?(entry)
    end)
  end

  defp active_running_count(_running), do: 0

  defp paused_running_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, entry} -> paused_running_entry?(entry)
    end)
  end

  defp paused_running_count(_running), do: 0

  defp active_running_entry?(entry) when is_map(entry) do
    not (paused_running_entry?(entry) or deactivated_running_entry?(entry))
  end

  defp active_running_entry?(_entry), do: false

  defp paused_running_entry?(entry) when is_map(entry) do
    (get_in(entry, [:control, :status]) || :working) == :paused
  end

  defp paused_running_entry?(_entry), do: false

  defp deactivated_running_entry?(entry) when is_map(entry) do
    get_in(entry, [:control, :status]) == :deactivated
  end

  defp deactivated_running_entry?(_entry), do: false

  defp max_concurrent_agent_limit(%State{} = state) do
    cond do
      is_integer(state.session_max_concurrent_agents) and state.session_max_concurrent_agents > 0 ->
        state.session_max_concurrent_agents

      is_integer(state.max_concurrent_agents) and state.max_concurrent_agents > 0 ->
        state.max_concurrent_agents

      true ->
        Config.settings!().agent.max_concurrent_agents
    end
  end

  defp max_concurrent_agent_status(%State{} = state) do
    %{
      active: active_running_count(state.running),
      paused: paused_running_count(state.running),
      configured: state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents,
      max: max_concurrent_agent_limit(state),
      session_override?: is_integer(state.session_max_concurrent_agents)
    }
  end

  # Paused agents keep their slot reserved: a deliberate pause should not
  # free capacity for the polling loop to auto-claim the next agent:todo
  # ticket. Resuming a paused agent reuses the held slot via
  # `resume_paused_issue/2`, which bypasses this check.
  defp available_slots(%State{} = state) do
    used = active_running_count(state.running) + paused_running_count(state.running)
    max(max_concurrent_agent_limit(state) - used, 0)
  end

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

  @spec resume_agent(GenServer.server(), String.t()) :: {:ok, :resumed | :started} | {:error, term()}
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

  @spec adjust_max_concurrent_agents(GenServer.server(), integer()) :: {:ok, map()} | {:error, term()}
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

  @spec control_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def control_capabilities(issue_identifier), do: control_capabilities(__MODULE__, issue_identifier)

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
  def set_remote_control(issue_identifier, on?), do: set_remote_control(__MODULE__, issue_identifier, on?)

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
  def ensure_remote_control_trust(workspace), do: ensure_remote_control_trust(__MODULE__, workspace)

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

  @spec claim_next_queue_item(GenServer.server(), String.t()) :: {:ok, map()} | :empty | {:error, term()}
  def claim_next_queue_item(server, issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(server, {:claim_next_queue_item, issue_identifier}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec claim_next_checkpoint_queue_item(GenServer.server(), String.t()) :: {:ok, map()} | :empty | {:error, term()}
  def claim_next_checkpoint_queue_item(server, issue_identifier) when is_binary(issue_identifier) do
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
  @spec claim_next_queue_item_for_test(GenServer.server(), String.t()) :: {:ok, map()} | :empty | {:error, term()}
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

  @spec fail_delivered_queue_items(GenServer.server(), String.t(), term()) :: :ok | {:error, term()}
  def fail_delivered_queue_items(server, issue_identifier, reason) when is_binary(issue_identifier) do
    GenServer.call(server, {:fail_delivered_queue_items, issue_identifier, reason}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  @spec mark_queue_item_failed_for_test(GenServer.server(), integer(), term()) :: :ok | {:error, term()}
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
    body = %{
      summary: event_digest_summary(event),
      events: [event]
    }

    {queue_store, item} =
      AgentQueue.coordination_event(identifier, :events_digest, body, source: :system)
      |> then(&AgentQueueStore.enqueue(state.queue_store, &1))

    next_state = %{state | queue_store: queue_store}

    case find_running_by_identifier(state.running, identifier) do
      nil ->
        :ok

      running_entry ->
        notify_running_queue_update(running_entry, item)
    end

    {:reply, :ok, next_state}
  end

  # Bootstrap-digest batched enqueue: one queue item carries every
  # missed event, so a long-offline agent's bootstrap doesn't fan out
  # into N serial GenServer.calls through the orchestrator mailbox.
  # The drain-time coalesce path still folds this digest with any
  # other events_digest items that arrive between enqueue and drain.
  def handle_call({:enqueue_event_digest_batch, identifier, events}, _from, state)
      when is_binary(identifier) and is_list(events) do
    body = %{
      summary: event_digest_summary(%{events: events}),
      events: events
    }

    {queue_store, item} =
      AgentQueue.coordination_event(identifier, :events_digest, body, source: :system)
      |> then(&AgentQueueStore.enqueue(state.queue_store, &1))

    next_state = %{state | queue_store: queue_store}

    case find_running_by_identifier(state.running, identifier) do
      nil ->
        :ok

      running_entry ->
        notify_running_queue_update(running_entry, item)
    end

    {:reply, :ok, next_state}
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

  def handle_call({:pause_agent, issue_identifier}, _from, state) when is_binary(issue_identifier) do
    reply = pause_agent_reply(state, issue_identifier)
    {:reply, reply, state}
  end

  def handle_call({:pause_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:interrupt_agent, issue_identifier}, _from, state) when is_binary(issue_identifier) do
    {:reply, interrupt_agent_reply(state, issue_identifier), state}
  end

  def handle_call({:interrupt_agent, _issue_identifier}, _from, state) do
    {:reply, {:error, :invalid_identifier}, state}
  end

  def handle_call({:pane_interrupt, issue_identifier}, _from, state) when is_binary(issue_identifier) do
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

  def handle_call({:resume_agent, issue_identifier}, _from, state) when is_binary(issue_identifier) do
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
    current = max_concurrent_agent_limit(state)
    next = max(current + delta, 1)
    active = active_running_count(state.running)

    if next < active do
      {:reply, {:error, :below_active_count}, state}
    else
      state = %{state | session_max_concurrent_agents: next}
      notify_dashboard(state)
      {:reply, {:ok, max_concurrent_agent_status(state)}, state}
    end
  end

  def handle_call({:claim_next_queue_item, issue_identifier}, _from, state) when is_binary(issue_identifier) do
    {queue_store, item} = AgentQueueStore.claim_next_deliverable(state.queue_store, issue_identifier)

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

  def handle_call({:restore_queue_item_pending, item_id}, _from, state) when is_integer(item_id) do
    {queue_store, _item} = AgentQueueStore.restore_pending(state.queue_store, item_id)
    {:reply, :ok, %{state | queue_store: queue_store}}
  end

  def handle_call({:mark_queue_item_failed, item_id, reason}, _from, state) when is_integer(item_id) do
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
    {queue_store, _items} = AgentQueueStore.fail_delivered(state.queue_store, issue_identifier, reason)
    {:reply, :ok, %{state | queue_store: queue_store}}
  end

  defp enqueue_operator_message(state, issue_identifier, body, payload) do
    delivery_policy = Map.get(payload, :delivery_policy, :checkpoint)
    fallback = Map.get(payload, :fallback)
    turn_id = Map.get(payload, :turn_id)

    case validate_operator_message(body) do
      {:ok, text} ->
        enqueue_validated_operator_message(state, issue_identifier, text, delivery_policy, fallback, turn_id)

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp enqueue_validated_operator_message(state, issue_identifier, text, delivery_policy, fallback, turn_id) do
    case find_running_by_identifier(state.running, issue_identifier) do
      nil ->
        {{:error, :no_running_agent}, state}

      running_entry ->
        enqueue_for_running_entry(state, running_entry, issue_identifier, text, delivery_policy, fallback, turn_id)
    end
  end

  # Chatting with a paused agent auto-resumes it — but only if a slot is
  # free. Routing through `resume_paused_issue/2` reuses the same
  # active-cap and per-state slot gates as the explicit space-key resume,
  # so we can't push active over max no matter which entry point the
  # operator uses. If no slot is free, the cap error propagates and the
  # conversation pane surfaces it.
  defp enqueue_for_running_entry(state, running_entry, issue_identifier, text, delivery_policy, fallback, turn_id) do
    cond do
      deactivated_running_entry?(running_entry) ->
        enqueue_after_reactivate(state, running_entry, issue_identifier, text, delivery_policy, fallback, turn_id)

      paused_running_entry?(running_entry) ->
        enqueue_after_resume(state, running_entry, issue_identifier, text, delivery_policy, fallback, turn_id)

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
  defp enqueue_after_reactivate(state, running_entry, issue_identifier, text, delivery_policy, fallback, turn_id) do
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

  defp enqueue_after_resume(state, running_entry, issue_identifier, text, delivery_policy, fallback, turn_id) do
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
          AgentQueue.operator_message(issue_identifier, text, Keyword.put(queue_opts, :turn_id, turn_id))
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

  defp maybe_emit_agent_control_alert(:working, :paused, running_entry) when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.agent.paused",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host)
    )
  end

  defp maybe_emit_agent_control_alert(:paused, :working, running_entry) when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.agent.unpaused",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host)
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

  defp notify_running_queue_update(%{pid: pid}, item) when is_pid(pid) do
    if Process.alive?(pid) do
      send(
        pid,
        {:agent_queue_updated, item.target_issue_identifier, item.id, item.delivery[:interrupt_requested] == true or item.delivery[:immediate] == true}
      )
    end

    :ok
  end

  defp notify_running_queue_update(_running_entry, _item), do: :ok

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
  defp reactivate_issue(%State{} = state, running_entry) do
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
        send_pause_control_message(state, issue_identifier)
    end
  end

  defp pause_running_or_inactive(state, running_entry, issue_identifier) do
    if deactivated_running_entry?(running_entry) do
      {:error, :already_inactive}
    else
      send_pause_control_message(state, issue_identifier)
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

  defp resume_paused_issue(%State{} = state, running_entry) do
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
        send_resume_control_message(state, running_entry)
    end
  end

  defp send_resume_control_message(%State{} = state, running_entry) do
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

  # Freeze the runtime clock while the agent is paused and shift
  # `started_at` forward on resume so `now - started_at` excludes the
  # paused interval. The age column in the agent list (and any other
  # consumer of `running_seconds/2`) stops advancing while paused.
  defp apply_pause_runtime_clock(entry, :working, :paused, now) when is_map(entry) do
    Map.put(entry, :paused_at, now)
  end

  defp apply_pause_runtime_clock(entry, :paused, :working, now) when is_map(entry) do
    shift_started_at_by_pause(entry, now)
  end

  defp apply_pause_runtime_clock(entry, _previous, _next, _now), do: entry

  defp thaw_pause_clock(running, issue_id, previous_status, now) when is_map(running) do
    case Map.get(running, issue_id) do
      nil -> running
      entry -> Map.put(running, issue_id, shift_started_at_by_pause_if(entry, previous_status, now))
    end
  end

  defp shift_started_at_by_pause_if(entry, :paused, now), do: shift_started_at_by_pause(entry, now)
  defp shift_started_at_by_pause_if(entry, _previous, _now), do: entry

  defp shift_started_at_by_pause(%{paused_at: %DateTime{} = paused_at} = entry, %DateTime{} = now) do
    paused_for = max(0, DateTime.diff(now, paused_at, :second))

    entry
    |> Map.update(:started_at, nil, fn
      %DateTime{} = started_at -> DateTime.add(started_at, paused_for, :second)
      other -> other
    end)
    |> Map.put(:paused_at, nil)
  end

  defp shift_started_at_by_pause(entry, _now), do: entry

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

  defp resume_worker_slot_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    worker_host_slots_available?(state, worker_host)
  end

  defp resume_worker_slot_available?(%State{}, _worker_host), do: true

  defp queue_depth_for_issue(%State{} = state, issue_identifier) when is_binary(issue_identifier) do
    state.queue_store
    |> AgentQueueStore.list_pending(issue_identifier)
    |> length()
  end

  defp pending_operator_messages_for_issue(%State{} = state, issue_identifier) when is_binary(issue_identifier) do
    state.queue_store
    |> AgentQueueStore.list_visible_operator_messages(issue_identifier)
    |> Enum.map(fn item ->
      %{
        id: item.id,
        text: get_in(item, [:body, :text]) || "",
        status: item.status
      }
    end)
  end

  defp issue_control_capabilities(%State{} = state, issue_identifier) when is_binary(issue_identifier) do
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

  defp default_running_control(%Issue{} = issue) do
    backend = CodingAgent.backend_for(issue)

    %{
      can_interrupt: CodingAgent.can_interrupt?(backend),
      safe_checkpoints: CodingAgent.safe_checkpoints(backend),
      immediate_delivery: CodingAgent.immediate_delivery?(backend),
      status: :working
    }
  end

  # ----------------------------------------------------------- remote control

  defp set_remote_control_reply(state, issue_identifier, on?) do
    case find_running_by_identifier(state.running, issue_identifier) do
      running_entry when is_map(running_entry) ->
        if on?, do: promote_to_remote(state, running_entry), else: demote_from_remote(state, running_entry)

      _ ->
        {{:error, :not_running}, state}
    end
  end

  # Promote any running agent (headless `claude` or `codex`) to `claude-remote`:
  # add the durable `model:claude-remote` label, stop the current agent, and
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
        Logger.info("Remote Control promote; re-dispatching as claude-remote: #{rc_log_context(running_entry)}")
        {{:ok, :on}, do_dispatch_issue(state, relabeled, nil, nil)}

      {:error, reason} ->
        Logger.error("Remote Control promote label-add failed: #{rc_log_context(running_entry)} reason=#{inspect(reason)}")
        {{:error, {:rc_label_failed, reason}}, state}
    end
  end

  # Demote a `claude-remote` agent back to the default backend: remove the
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

  defp issue_tag(%Issue{} = issue) do
    issue
    |> Issue.label_names()
    |> Enum.find(fn label -> is_binary(label) and String.starts_with?(label, "agent:") end)
  end

  defp issue_tag(_issue), do: nil

  defp find_running_by_identifier(running, issue_identifier) do
    Enum.find_value(running, fn
      {_issue_id, %{identifier: identifier} = entry} ->
        if to_string(identifier) == issue_identifier, do: entry, else: nil

      _ ->
        nil
    end)
  end

  defp find_running_by_repl_pane_id(running, pane_id) do
    Enum.find_value(running, fn
      {_issue_id, %{repl_pane_id: ^pane_id} = entry} -> entry
      _ -> nil
    end)
  end

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

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

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
          worker_host: running_worker_host(state, issue.id)
        )

      _ ->
        Alerts.emit_system("system.dispatch.todo_capacity_exceeded")
    end
  end

  defp running_worker_host(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{worker_host: worker_host} -> worker_host
      _ -> nil
    end
  end

  defp running_worker_host(_state, _issue_id), do: nil

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state)
  end

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

  defp apply_token_delta(nil, token_delta), do: apply_token_delta(@empty_agent_totals, token_delta)

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

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  # Wall-clock seconds the agent has spent *actively working*. If the
  # entry is currently paused, the clock is frozen at the moment of
  # pause; on resume `shift_started_at_by_pause/2` shifts `started_at`
  # forward so any future delta excludes the paused interval.
  defp effective_runtime_seconds(entry, %DateTime{} = now) when is_map(entry) do
    case {Map.get(entry, :started_at), Map.get(entry, :paused_at)} do
      {%DateTime{} = started_at, %DateTime{} = paused_at} ->
        running_seconds(started_at, paused_at)

      {started_at, _} ->
        running_seconds(started_at, now)
    end
  end

  defp effective_runtime_seconds(_entry, _now), do: 0

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

    sorted = Enum.sort_by(first_events ++ next_events, &event_sort_key/1)

    new_body =
      first.body
      |> Map.put(:events, sorted)
      |> Map.put(:summary, event_digest_summary(%{events: sorted}))

    %{first | body: new_body}
  end

  defp event_sort_key(%{id: id}) when is_integer(id), do: id
  defp event_sort_key(%{"id" => id}) when is_integer(id), do: id
  defp event_sort_key(_), do: 0

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
      attach_and_subscribe(blockee_identifier, default_blockee_subscriptions(blocker_identifier), "blocker:auto")
      attach_and_subscribe(blocker_identifier, default_blocker_subscriptions(blockee_identifier), "blockee:auto")
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
      remove_auto_subscriptions(blockee_identifier, default_blockee_subscriptions(blocker_identifier), "blocker:auto")
      remove_auto_subscriptions(blocker_identifier, default_blocker_subscriptions(blockee_identifier), "blockee:auto")
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

    # Topic strings must match what GithubFirehose publishes literally
    # (Exchange routes by literal segment match). See Aiur.Events.GithubFirehose
    # `translate/2` clauses for the canonical names:
    #   PushEvent             -> ticket.<N>.branch.push
    #   IssuesEvent           -> ticket.<N>.issue.*
    #   IssueCommentEvent     -> ticket.<N>.issue.commented
    #   PullRequestEvent      -> ticket.<N>.pr.{opened,merged,closed,…}
    #   PullRequestReviewComment -> ticket.<N>.pr.review_comment
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

  defp blockee_identifier_for(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp blockee_identifier_for(_), do: nil

  defp blocker_identifier_for(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp blocker_identifier_for(%{"identifier" => identifier}) when is_binary(identifier), do: identifier
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

  defp blocker_critical_digest?(%{category: :coordination_event, event_type: :events_digest, body: body}, direct_blockers) do
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
