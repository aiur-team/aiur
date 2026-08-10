defmodule Aiur.Orchestrator.Lifecycle do
  @moduledoc """
  Owns the orchestrator process lifecycle and tokenized polling clock.

  Every function runs synchronously inside the orchestrator GenServer process.
  """

  alias Aiur.{CIApprovalStore, Config, LiveConversation, ProcessReaper}
  alias Aiur.Events.{Exchange, Publisher}

  alias Aiur.Orchestrator.{
    AgentTeardown,
    CommentWake,
    ControlLifecycleStore,
    DispatchPolicy,
    GlobalPauseStore,
    PauseResume,
    RemoteControlMode,
    Slots,
    SnapshotStore,
    State,
    StatusReport,
    TrackedSet,
    WorkspaceCleanup
  }

  @poll_transition_render_delay_ms 20
  @control_ack_timeout_ms 30_000
  @orchestrator_topics [
    "ticket.*.pr.review_comment",
    "ticket.*.issue.commented",
    "ticket.*.pr.merged",
    "ticket.*.ci.failed",
    "ticket.*.ci.passed",
    "ticket.*.agent.pause.request",
    "ticket.*.agent.unblocked",
    "ticket.*.branch.push",
    "system.*.branch.push"
  ]
  @empty_agent_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @spec request_refresh_api() :: map() | :unavailable
  def request_refresh_api, do: request_refresh_api(Aiur.Orchestrator)

  @spec request_refresh_api(GenServer.server()) :: map() | :unavailable
  def request_refresh_api(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec init(keyword(), (term() -> boolean())) :: {:ok, State.t()}
  def init(opts, tracked_issue?) when is_function(tracked_issue?, 1) do
    # Trap exits so the supervisor's orderly shutdown lands in `terminate/2`,
    # which reaps every running agent's process tree (see `terminate/2`).
    Process.flag(:trap_exit, true)

    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    control_lifecycle =
      ControlLifecycleStore.load()
      |> ControlLifecycleStore.expire_unresolved_on_recovery()

    :ok = ControlLifecycleStore.save(control_lifecycle)

    snapshot_key = Keyword.get(opts, :name, Aiur.Orchestrator)
    persisted_global_pause = GlobalPauseStore.load()
    global_pause = initial_global_pause(persisted_global_pause)

    state = %State{
      snapshot_key: snapshot_key,
      # A restarted server keeps its prior fleet view until this generation has
      # completed a fresh poll and projection. Older projector tasks are fenced
      # by this token before they can replace that retained view.
      snapshot_generation: SnapshotStore.begin_generation(snapshot_key),
      poll_interval_ms: config.polling.interval_seconds * 1_000,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      # `--max-agents N` at launch: seed the session override (highest
      # precedence; `refresh_runtime_config/1` never clobbers it) so the cap
      # holds without editing `.aiur/config`.
      session_max_concurrent_agents: Slots.launch_max_concurrent_agents_override(),
      # `--pause` at launch: cold-start globally paused so no agents provision
      # even with agent:todo tickets, until the operator unpauses.
      globally_paused: global_pause.globally_paused,
      global_pause: Map.drop(global_pause, [:globally_paused]),
      effective_concurrent_agents: DispatchPolicy.initial_load_envelope_limit(config.agent),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      poll_frozen: false,
      tick_timer_ref: nil,
      tick_token: nil,
      initial_dispatch_cycle: true,
      ci_lifecycle:
        CIApprovalStore.load()
        |> Map.put(:poll_cache, %{})
        |> Map.put(:rewakes, %{}),
      agent_totals: @empty_agent_totals,
      agent_rate_limits: nil,
      control_lifecycle: control_lifecycle
    }

    :ok =
      SnapshotStore.publish_global_pause(
        snapshot_key,
        state.snapshot_generation,
        Map.put(state.global_pause, :globally_paused, state.globally_paused)
      )

    state = WorkspaceCleanup.run_terminal_workspace_cleanup(state)
    state = WorkspaceCleanup.run_startup_todo_workspace_cleanup(state)
    RemoteControlMode.cleanup_stray_remote_control_servers()
    TrackedSet.reset([])
    install_event_tracked_fn(tracked_issue?)
    subscribe_to_orchestrator_topics()
    _ = LiveConversation.subscribe_restarts()

    state = schedule_initial_tick(state, Keyword.get(opts, :initial_poll?, true))

    {:ok, state}
  end

  defp initial_global_pause({:ok, persisted}) do
    if Slots.launch_globally_paused?() do
      next = %{globally_paused: true, paused_at: DateTime.utc_now(), source: "CLI --pause"}
      :ok = GlobalPauseStore.save(next)
      next
    else
      persisted
    end
  end

  defp initial_global_pause({:error, _reason}) do
    if Slots.launch_globally_paused?() do
      next = %{globally_paused: true, paused_at: DateTime.utc_now(), source: "CLI --pause"}
      :ok = GlobalPauseStore.save(next)
      next
    else
      %{globally_paused: true, paused_at: DateTime.utc_now(), source: "persistence recovery failed"}
    end
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
  @spec terminate(term(), State.t() | term()) :: :ok
  def terminate(_reason, %State{running: running} = state) when is_map(running) do
    # Comment-rework retries reschedule themselves for up to a minute with
    # escalating delays. Cancel them here so a stopping orchestrator never leaves
    # a timer firing — and logging — into whatever runs after it (#1747).
    _ = CommentWake.cancel_comment_rework_retries(state)

    # Best-effort accelerator: sweep registered agent processes first.
    # drain: false is load-bearing — terminate/2 also runs on a supervised
    # crash-restart, and latching the app-lifetime reaper into draining
    # there would kill every agent the restarted orchestrator spawns.
    _ = ProcessReaper.reap([:agent], drain: false)
    Enum.each(running, fn {_issue_id, entry} -> AgentTeardown.kill_repl_session(entry) end)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @spec handle_tick(State.t()) :: {:noreply, State.t()}
  def handle_tick(%State{} = state) do
    state = refresh_runtime_config(state)
    state = PauseResume.expire_pending_controls(state, DateTime.utc_now(), @control_ack_timeout_ms)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    StatusReport.notify_dashboard(state)
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  @spec request_refresh(State.t()) :: {:reply, map(), State.t()}
  def request_refresh(%State{} = state) do
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

  @spec schedule_tick(State.t(), non_neg_integer()) :: State.t()
  def schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
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

  defp schedule_initial_tick(state, false), do: %{state | next_poll_due_at_ms: nil}
  defp schedule_initial_tick(state, _initial_poll?), do: schedule_tick(state, 0)

  @spec schedule_poll_cycle_start() :: :ok
  def schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  @spec refresh_runtime_config(State.t()) :: State.t()
  def refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_seconds * 1_000,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp install_event_tracked_fn(tracked_issue?) do
    if Process.whereis(Publisher) do
      Publisher.set_tracked_fn(tracked_issue?)
    end

    :ok
  end

  # Subscribe to the topics the orchestrator routes itself. These subscriptions
  # must be installed after startup cleanup and tracked-set initialization but
  # before the first tick is seeded.
  defp subscribe_to_orchestrator_topics do
    if Process.whereis(Exchange) do
      Enum.each(@orchestrator_topics, &Exchange.subscribe/1)
    end

    :ok
  end

  @doc false
  @spec orchestrator_topics() :: [String.t()]
  def orchestrator_topics, do: @orchestrator_topics
end
