defmodule Aiur.Orchestrator.Lifecycle do
  @moduledoc """
  Owns the orchestrator process lifecycle and tokenized polling clock.

  Every function runs synchronously inside the orchestrator GenServer process.
  """

  alias Aiur.{CIApprovalStore, Config, ProcessReaper}
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.GitHub.RateBudget

  alias Aiur.Orchestrator.{
    AgentTeardown,
    DispatchPolicy,
    RemoteControlMode,
    Slots,
    State,
    StatusReport,
    TrackedSet,
    WorkspaceCleanup
  }

  @poll_transition_render_delay_ms 20
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
  def init(_opts, tracked_issue?) when is_function(tracked_issue?, 1) do
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
      session_max_concurrent_agents: Slots.launch_max_concurrent_agents_override(),
      effective_concurrent_agents: DispatchPolicy.initial_load_envelope_limit(config.agent),
      load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil},
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      tick_budget_protected: false,
      initial_dispatch_cycle: true,
      ci_lifecycle:
        CIApprovalStore.load()
        |> Map.put(:poll_cache, %{})
        |> Map.put(:rewakes, %{}),
      agent_totals: @empty_agent_totals,
      agent_rate_limits: nil
    }

    state = WorkspaceCleanup.run_terminal_workspace_cleanup(state)
    state = WorkspaceCleanup.run_startup_todo_workspace_cleanup(state)
    RemoteControlMode.cleanup_stray_remote_control_servers()
    TrackedSet.reset([])
    install_event_tracked_fn(tracked_issue?)
    subscribe_to_orchestrator_topics()

    {:ok, schedule_tick(state, 0)}
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
  def terminate(_reason, %State{running: running}) when is_map(running) do
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

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil,
        tick_budget_protected: false
    }

    StatusReport.notify_dashboard(state)
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  @spec request_refresh(State.t(), keyword()) :: {:reply, map(), State.t()}
  def request_refresh(%State{} = state, opts \\ []) do
    now_ms = System.monotonic_time(:millisecond)
    budget_delay_fun = Keyword.get(opts, :budget_delay_fun, &RateBudget.delay_ms/0)
    budget_delay_ms = budget_delay_fun.()
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms

    protected_timer? =
      budget_delay_ms > 0 and state.tick_budget_protected == true and
        is_reference(state.tick_timer_ref)

    coalesced = state.poll_check_in_progress == true or already_due? or protected_timer?

    state =
      if coalesced do
        state
      else
        state = schedule_tick(state, budget_delay_ms)
        %{state | tick_budget_protected: budget_delay_ms > 0}
      end

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
        tick_budget_protected: false,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

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
      Exchange.subscribe("ticket.*.pr.review_comment")
      Exchange.subscribe("ticket.*.issue.commented")
      Exchange.subscribe("ticket.*.pr.merged")
      Exchange.subscribe("ticket.*.ci.failed")
      Exchange.subscribe("ticket.*.ci.passed")
      Exchange.subscribe("ticket.*.agent.pause.request")
      Exchange.subscribe("ticket.*.branch.push")
      Exchange.subscribe("system.*.branch.push")
    end

    :ok
  end
end
