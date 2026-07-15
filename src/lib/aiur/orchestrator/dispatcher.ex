defmodule Aiur.Orchestrator.Dispatcher do
  @moduledoc """
  Dispatch execution: choose loop, revalidation, thrash breaker, worker spawn.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{AgentRunner, Alerts, CodingAgent, Config, DispatchBudgetStore, Issue, RepoBase, Tracker}
  alias Aiur.Orchestrator

  alias Aiur.Orchestrator.{
    CiLifecycle,
    CommandScan,
    CommentPolling,
    DispatchPolicy,
    IssueSync,
    Lifecycle,
    PrAnchored,
    Reconciler,
    Slots,
    State,
    StatusReport,
    TrackedSet,
    TrackerHealth
  }

  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.RunTelemetry.Lifecycle, as: TelemetryLifecycle

  @spec run_poll_cycle(State.t()) :: {:noreply, State.t()}
  def run_poll_cycle(%State{} = state) do
    state = Lifecycle.refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = Lifecycle.schedule_tick(state, TrackerHealth.next_poll_delay_ms(state))
    state = %{state | poll_check_in_progress: false}

    StatusReport.notify_dashboard(state)
    {:noreply, state}
  end

  @spec maybe_dispatch(State.t()) :: State.t()
  def maybe_dispatch(%State{} = state) do
    state = Reconciler.reconcile_running_lifecycle(state)

    case TrackerHealth.ensure_tracker_preflight(state) do
      {:ok, state} ->
        do_maybe_dispatch(state)

      {:error, reason, state} ->
        TrackerHealth.log_tracker_preflight_error(reason)
        state
    end
  end

  defp do_maybe_dispatch(%State{} = state) do
    state = TrackedSet.refresh(state)
    state = CommentPolling.poll_github_firehose(state)
    state = CommentPolling.poll_github_comments(state)
    state = CiLifecycle.poll_github_ci(state)
    state = Reconciler.refresh_running_issue_states(state)
    state = CommandScan.scan_pr_commands(state)
    state = PrAnchored.maybe_stop_closed_pr_anchored_agents(state)

    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        state =
          state
          |> IssueSync.sync_polled_issue_state(issues)
          |> IssueSync.sync_todo_capacity_alert(issues)

        # The poll just refreshed `last_polled_issues`, so push a fresh
        # summary out to any open agent-list pane immediately.
        StatusReport.notify_dashboard(state)

        state = dispatch_or_hold(state, issues)
        %{state | initial_dispatch_cycle: false}

      {:error, reason} ->
        TrackerHealth.log_tracker_fetch_error(reason)
        state
    end
  end

  # The base is readied before CPU admission so per-issue workspaces can use it
  # instead of cold-cloning. A failed build deliberately falls back to dispatch,
  # while an in-progress build holds this tick.
  @spec dispatch_or_hold(State.t(), [Issue.t()]) :: State.t()
  def dispatch_or_hold(%State{} = state, issues) when is_list(issues) do
    enabled? = Config.prewarm_enabled?()
    phase = if enabled?, do: trigger_and_status(), else: :ready

    case DispatchPolicy.prewarm_gate(enabled?, phase) do
      :dispatch ->
        maybe_log_base_error(phase)
        maybe_choose_under_load(state, issues)

      :hold ->
        state
    end
  end

  # CPU load admission applies to NEW work only. Retries and reactivations bypass
  # this function so a capacity wait never burns their retry budget.
  @spec maybe_choose_under_load(State.t(), [Issue.t()]) :: State.t()
  def maybe_choose_under_load(%State{} = state, issues) when is_list(issues) do
    maybe_choose_under_load(state, issues, &maybe_choose/2)
  end

  @doc false
  @spec maybe_choose_under_load(State.t(), [Issue.t()], (State.t(), [Issue.t()] -> State.t())) :: State.t()
  def maybe_choose_under_load(%State{} = state, issues, choose_fun)
      when is_list(issues) and is_function(choose_fun, 2) do
    hard_threshold = Config.max_load_average()
    target = Config.target_load_average()
    memory_threshold_mb = Config.min_free_memory_mb()
    schedulers = System.schedulers_online()
    load = DispatchPolicy.read_load(hard_threshold, target)
    cpu_snapshot = DispatchPolicy.read_cpu(target)
    available_memory_mb = DispatchPolicy.read_memory(memory_threshold_mb)
    fd_sample = DispatchPolicy.read_file_descriptors()

    state =
      DispatchPolicy.update_load_envelope(
        state,
        load,
        target,
        schedulers,
        System.monotonic_time(:millisecond),
        cpu_snapshot,
        DispatchPolicy.queued_dispatch_demand?(issues, state)
      )

    case DispatchPolicy.memory_gate(available_memory_mb, memory_threshold_mb) do
      :hold ->
        log_memory_hold(available_memory_mb, memory_threshold_mb)
        state

      :dispatch ->
        maybe_choose_with_fd_headroom(state, issues, fd_sample, load, hard_threshold, schedulers, choose_fun)
    end
  end

  @spec choose_issues(State.t(), [Issue.t()]) :: State.t()
  def choose_issues(state, issues) do
    active_states = DispatchPolicy.active_state_set()
    terminal_states = DispatchPolicy.terminal_state_set()
    initial_dispatch_cycle? = state.initial_dispatch_cycle == true

    {state, _startup_todo_index} =
      issues
      |> DispatchPolicy.sort_issues_for_dispatch()
      |> Enum.reduce({state, 0}, fn issue, {state_acc, startup_todo_index} ->
        if DispatchPolicy.should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
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

  @spec dispatch_issue(State.t(), term(), term(), term()) :: State.t()
  def dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    dispatch_issue(state, issue, attempt, preferred_worker_host, [])
  end

  @doc false
  @spec dispatch_issue(State.t(), term(), term(), term(), keyword()) :: State.t()
  def dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, opts)
      when is_list(opts) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           DispatchPolicy.terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, opts)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{State.issue_context(issue)}")

        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{State.issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{State.issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  @spec do_dispatch_issue(State.t(), term(), term(), term()) :: State.t()
  def do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    do_dispatch_issue(state, issue, attempt, preferred_worker_host, [])
  end

  @doc false
  @spec do_dispatch_issue(State.t(), term(), term(), term(), keyword()) :: State.t()
  def do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, opts) when is_list(opts) do
    case CodingAgent.select_for_dispatch(issue) do
      {:all_limited, candidates} ->
        if MapSet.member?(state.model_fallback_waiting, issue.id) do
          state
        else
          Alerts.emit_system("ticket.#{issue.identifier}.agent.model_fallback_waiting",
            issue: issue.identifier,
            reason: "All configured fallback backends are usage-limited: #{Enum.join(candidates, ", ")}. Waiting for a reset before retrying.",
            needs_attention: true,
            severity: "warning"
          )

          %{state | model_fallback_waiting: MapSet.put(state.model_fallback_waiting, issue.id)}
        end

      {:ok, selected_issue} ->
        state = %{state | model_fallback_waiting: MapSet.delete(state.model_fallback_waiting, selected_issue.id)}

        case check_thrash_budget(state, selected_issue.id, System.monotonic_time(:millisecond)) do
          {:trip, tripped_state} ->
            trip_thrash_breaker(tripped_state, selected_issue)

          {:ok, budgeted_state} ->
            dispatch_to_worker(
              budgeted_state,
              selected_issue,
              attempt,
              preferred_worker_host,
              opts
            )
        end
    end
  end

  @doc false
  @spec redispatch_ready?(State.t(), Issue.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def redispatch_ready?(%State{} = state, %Issue{} = issue, preferred_worker_host, opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

    with {:ok, selected_issue} <- redispatch_backend(issue),
         :ok <- known_redispatch_backend(selected_issue),
         :ok <- redispatch_thrash_budget(state, selected_issue.id, now_ms),
         :ok <- redispatch_worker_slot(state, selected_issue.id, preferred_worker_host) do
      :ok
    else
      {:all_limited, candidates} -> {:error, {:all_limited, candidates}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec admit_redispatch(State.t(), Issue.t(), String.t() | nil, keyword()) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  def admit_redispatch(%State{} = state, %Issue{} = issue, preferred_worker_host, opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

    with {:ok, selected_issue} <- redispatch_backend(issue),
         :ok <- known_redispatch_backend(selected_issue),
         {:ok, state} <- admit_redispatch_thrash_budget(state, selected_issue, now_ms, opts),
         :ok <- redispatch_worker_slot(state, selected_issue.id, preferred_worker_host) do
      {:ok, state}
    else
      {:all_limited, candidates} -> {:error, {:all_limited, candidates}, state}
      {:error, reason, %State{} = rejected_state} -> {:error, reason, rejected_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp redispatch_backend(issue), do: CodingAgent.select_for_dispatch(issue)

  defp known_redispatch_backend(issue) do
    backend = CodingAgent.backend_for(issue)

    if backend in CodingAgent.known_backends(),
      do: :ok,
      else: {:error, {:unknown_backend, backend}}
  end

  defp redispatch_thrash_budget(state, issue_id, now_ms) do
    previous = Map.get(state.codex_thrash_budget, issue_id)
    entry = next_thrash_budget_entry(state, issue_id, now_ms)

    if active_trip?(previous, now_ms) or not is_nil(budget_trip_reason(entry)),
      do: {:error, :thrash_circuit_open},
      else: :ok
  end

  defp admit_redispatch_thrash_budget(state, issue, now_ms, opts) do
    previous = Map.get(state.codex_thrash_budget, issue.id)
    trip = Keyword.get(opts, :trip_fun, &trip_thrash_breaker/2)

    if active_trip?(previous, now_ms) do
      {:error, :thrash_circuit_open, trip.(state, issue)}
    else
      candidate = next_thrash_budget_entry(state, issue.id, now_ms)

      case budget_trip_reason(candidate) do
        nil ->
          {:ok, state}

        reason ->
          tripped = trip_budget_entry(previous, candidate, reason)
          state = %{state | codex_thrash_budget: Map.put(state.codex_thrash_budget, issue.id, tripped)}
          {:error, :thrash_circuit_open, trip.(state, issue)}
      end
    end
  end

  # A backend swap replaces the issue's existing host slot. Exclude that entry
  # from the capacity sample, but require an exact preferred-host match so the
  # workspace and on-disk rollout never migrate during the swap.
  defp redispatch_worker_slot(state, issue_id, preferred_worker_host) do
    capacity_state = %{state | running: Map.delete(state.running, issue_id)}

    case Slots.select_worker_host(capacity_state, preferred_worker_host) do
      ^preferred_worker_host -> :ok
      :no_worker_capacity -> {:error, :no_worker_capacity}
      _other_host -> {:error, :preferred_worker_unavailable}
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
  @spec check_thrash_budget(State.t(), String.t(), integer()) ::
          {:ok, State.t()} | {:trip, State.t()}
  def check_thrash_budget(%State{} = state, issue_id, now_ms) do
    previous = Map.get(state.codex_thrash_budget, issue_id)

    if active_trip?(previous, now_ms) do
      {:trip, state}
    else
      admit_next_thrash_budget(state, issue_id, previous, now_ms)
    end
  end

  defp admit_next_thrash_budget(state, issue_id, previous, now_ms) do
    entry = next_thrash_budget_entry(state, issue_id, now_ms)

    case budget_trip_reason(entry) do
      nil ->
        case persist_lifetime(entry, issue_id) do
          :ok ->
            state = %{state | codex_thrash_budget: Map.put(state.codex_thrash_budget, issue_id, entry)}
            {:ok, state}

          {:error, _reason} ->
            tripped = trip_budget_entry(previous, entry, :lifetime)
            state = %{state | codex_thrash_budget: Map.put(state.codex_thrash_budget, issue_id, tripped)}
            {:trip, state}
        end

      reason ->
        tripped = trip_budget_entry(previous, entry, reason)
        state = %{state | codex_thrash_budget: Map.put(state.codex_thrash_budget, issue_id, tripped)}
        {:trip, state}
    end
  end

  defp budget_trip_reason(entry) do
    cond do
      entry.count > Config.codex_thrash_max_per_window() -> :window
      lifetime_exhausted?(entry) -> :lifetime
      true -> nil
    end
  end

  defp active_trip?(%{tripped: :lifetime, lifetime: lifetime}, _now_ms) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 -> lifetime >= max
      _ -> false
    end
  end

  defp active_trip?(%{tripped: :window, window_start_ms: start}, now_ms) do
    now_ms - start < Config.codex_thrash_window_seconds() * 1_000
  end

  defp active_trip?(_entry, _now_ms), do: false

  defp trip_budget_entry(previous, candidate, reason) do
    spent =
      previous ||
        %{
          window_start_ms: candidate.window_start_ms,
          count: max(candidate.count - 1, 0),
          lifetime: max(candidate.lifetime - 1, 0)
        }

    spent
    |> Map.put(:tripped, reason)
    |> Map.put(:alert_emitted, false)
  end

  # The window counter resets on every lapsed window, so a ticket that churns
  # slowly (a dispatch every few minutes) never trips it — that is how a single
  # ticket accumulated 85 cold dispatches. `lifetime` counts every dispatch for
  # the issue regardless of window, and survives `reset_thrash_budget/2`, so a
  # structurally-stuck ticket latches instead of burning quota forever.
  # `0` (the default) disables the latch, matching the repo's existing
  # "0 disables it" idiom.
  defp lifetime_exhausted?(%{lifetime: lifetime}) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 -> lifetime > max
      _ -> false
    end
  end

  defp next_thrash_budget_entry(state, issue_id, now_ms) do
    window_ms = Config.codex_thrash_window_seconds() * 1_000
    previous = Map.get(state.codex_thrash_budget, issue_id)
    lifetime = max(lifetime_of(previous), persisted_lifetime(issue_id)) + 1

    case previous do
      %{window_start_ms: start, count: count} when now_ms - start < window_ms ->
        %{window_start_ms: start, count: count + 1, lifetime: lifetime}

      _ ->
        %{window_start_ms: now_ms, count: 1, lifetime: lifetime}
    end
  end

  defp lifetime_of(%{lifetime: lifetime}) when is_integer(lifetime), do: lifetime
  defp lifetime_of(_entry), do: 0

  defp persisted_lifetime(issue_id) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 ->
        case DispatchBudgetStore.lifetime(issue_id) do
          {:ok, lifetime} ->
            lifetime

          {:error, reason} ->
            Logger.error("Dispatch budget store read failed: issue_id=#{issue_id} reason=#{inspect(reason)}")
            max
        end

      _ ->
        0
    end
  end

  defp persist_lifetime(entry, issue_id) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 ->
        DispatchBudgetStore.put_lifetime(issue_id, entry.lifetime)

      _ ->
        :ok
    end
  end

  # Clears the window so an operator resume can move the ticket again, but
  # deliberately preserves `lifetime`: the dispatches were really spent, and
  # refunding them would let a resume loop bypass the latch forever.
  @spec reset_thrash_budget(State.t(), String.t()) :: State.t()
  def reset_thrash_budget(%State{} = state, issue_id) do
    case Map.get(state.codex_thrash_budget, issue_id) do
      %{lifetime: lifetime} when is_integer(lifetime) and lifetime > 0 ->
        entry = %{lifetime: lifetime}
        %{state | codex_thrash_budget: Map.put(state.codex_thrash_budget, issue_id, entry)}

      _ ->
        %{state | codex_thrash_budget: Map.delete(state.codex_thrash_budget, issue_id)}
    end
  end

  @spec revalidate_issue_for_dispatch(Issue.t(), function(), MapSet.t()) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
      when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if Orchestrator.retry_candidate_issue?(refreshed_issue, terminal_states) do
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

  def revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  @spec retry_dispatch_ready?(Issue.t(), State.t(), String.t() | nil) :: boolean()
  def retry_dispatch_ready?(%Issue{} = issue, %State{} = state, worker_host) do
    terminal_states = DispatchPolicy.terminal_state_set()

    DispatchPolicy.retry_candidate_issue?(issue, terminal_states) and
      Slots.dispatch_slots_available?(issue, state) and
      Slots.worker_slots_available?(state, worker_host)
  end

  defp log_load_hold(load, threshold, schedulers) do
    Logger.info(
      "aiur_perf load_hold load=#{load} threshold=#{threshold} " <>
        "schedulers=#{schedulers} limit=#{threshold * schedulers}"
    )
  end

  defp log_memory_hold(available_mb, threshold_mb) do
    Logger.info(
      "aiur_perf memory_hold surface=dispatch available_mb=#{available_mb} " <>
        "threshold_mb=#{threshold_mb}"
    )
  end

  defp log_fd_hold(:exhausted) do
    Logger.info(
      "aiur_perf fd_hold surface=dispatch status=exhausted used=unknown limit=unknown " <>
        "available=0 threshold=unknown threshold_pct=#{DispatchPolicy.fd_headroom_percent()}"
    )
  end

  defp log_fd_hold(sample) do
    Logger.info(
      "aiur_perf fd_hold surface=dispatch used=#{sample.used} limit=#{sample.limit} " <>
        "available=#{sample.available} threshold=#{DispatchPolicy.fd_headroom_threshold(sample)} " <>
        "threshold_pct=#{DispatchPolicy.fd_headroom_percent()}"
    )
  end

  defp maybe_choose_with_fd_headroom(state, issues, fd_sample, load, threshold, schedulers, choose_fun) do
    case DispatchPolicy.fd_gate(fd_sample) do
      :hold ->
        log_fd_hold(fd_sample)
        state

      :dispatch ->
        maybe_choose_under_hard_load(state, issues, load, threshold, schedulers, choose_fun)
    end
  end

  defp maybe_choose_under_hard_load(state, issues, load, threshold, schedulers, choose_fun) do
    case DispatchPolicy.load_gate(load, threshold, schedulers) do
      :hold ->
        log_load_hold(load, threshold, schedulers)
        state

      :dispatch ->
        choose_fun.(state, issues)
    end
  end

  defp trigger_and_status do
    RepoBase.refresh_async()
    RepoBase.status() |> elem(0)
  end

  defp maybe_choose(state, issues) do
    if Slots.available_slots(state) > 0, do: choose_issues(state, issues), else: state
  end

  defp maybe_log_base_error({:error, reason}),
    do: Logger.warning("prewarm base unavailable (#{inspect(reason)}); dispatching via cold clone")

  defp maybe_log_base_error(_phase), do: :ok

  defp maybe_schedule_startup_todo_alert(
         previous_state,
         next_state,
         %Issue{} = issue,
         index,
         true
       ) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "todo" and
         not MapSet.member?(previous_state.claimed, issue.id) and
         MapSet.member?(next_state.claimed, issue.id) do
      delay_ms = index * 1_000
      worker_host = Orchestrator.running_worker_host(next_state, issue.id)
      topic = "ticket.#{issue.identifier}.issue.label.added.agent.todo"
      Process.send_after(self(), {:emit_system_alert, topic, issue, worker_host}, delay_ms)
      index + 1
    else
      index
    end
  end

  defp maybe_schedule_startup_todo_alert(
         _previous_state,
         _next_state,
         _issue,
         index,
         _initial_dispatch_cycle?
       ),
       do: index

  defp dispatch_to_worker(%State{} = state, issue, attempt, preferred_worker_host, opts) do
    recipient = self()

    case Slots.select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{State.issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, opts)
    end
  end

  defp trip_thrash_breaker(%State{} = state, issue) do
    state = persist_lifetime_trip(state, issue, &Tracker.update_issue_state/2)
    entry = Map.get(state.codex_thrash_budget, issue.id, %{})

    if Map.get(entry, :alert_emitted, false) do
      state
    else
      count = Map.get(entry, :count, 0)
      lifetime = Map.get(entry, :lifetime, 0)
      reason = Map.get(entry, :tripped, :window)
      lifetime_max = Config.agent_max_dispatches_per_ticket()

      Logger.warning(
        "Codex thrash detected: issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{reason} restarts=#{count} lifetime=#{lifetime} lifetime_max=#{lifetime_max} window_seconds=#{Config.codex_thrash_window_seconds()}; skipping dispatch"
      )

      Alerts.emit_system("ticket.#{issue.identifier}.agent.thrash_circuit_open",
        issue: issue.identifier,
        reason: "Codex dispatch circuit opened (#{reason}); window restarts=#{count}, lifetime dispatches=#{lifetime}/#{lifetime_max}.",
        needs_attention: true,
        severity: "warning"
      )

      updated_entry = Map.put(entry, :alert_emitted, true)
      %{state | codex_thrash_budget: Map.put(state.codex_thrash_budget, issue.id, updated_entry)}
    end
  end

  @doc false
  @spec persist_lifetime_trip(State.t(), Issue.t(), (String.t(), String.t() -> :ok | {:error, term()})) ::
          State.t()
  def persist_lifetime_trip(%State{} = state, %Issue{} = issue, update_state_fun)
      when is_function(update_state_fun, 2) do
    entry = Map.get(state.codex_thrash_budget, issue.id, %{})

    if entry[:tripped] == :lifetime and entry[:durable_latch_applied] != true and
         is_binary(issue.identifier) do
      case update_state_fun.(issue.identifier, "error") do
        :ok ->
          updated_entry = Map.put(entry, :durable_latch_applied, true)

          %{
            state
            | codex_thrash_budget: Map.put(state.codex_thrash_budget, issue.id, updated_entry),
              claimed: MapSet.delete(state.claimed, issue.id)
          }

        {:error, reason} ->
          Logger.error("Unable to persist lifetime dispatch latch: issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")

          state
      end
    else
      state
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, opts) do
    runner = Keyword.get(opts, :runner, &AgentRunner.run/3)
    lifecycle_attempt_id = TelemetryLifecycle.new_attempt_id(dispatch_attempt_ticket(issue))

    if TelemetryLifecycle.enabled?() do
      TelemetryLifecycle.record(issue.identifier, lifecycle_attempt_id, :dispatch, :point, %{
        outcome: :requested,
        worker_host: worker_host,
        remote: is_binary(worker_host),
        retry_attempt: RetryEngine.normalize_retry_attempt(attempt)
      })
    end

    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
           runner.(issue, recipient,
             attempt: attempt,
             prior_work: Keyword.get(opts, :prior_work, false),
             telemetry_attempt_id: lifecycle_attempt_id,
             worker_host: worker_host,
             orchestrator: recipient
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{State.issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")
        record_rework_resume(issue, lifecycle_attempt_id)

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
            completed_turn_count: 0,
            control: default_running_control(issue),
            telemetry_attempt_id: lifecycle_attempt_id,
            retry_attempt: RetryEngine.normalize_retry_attempt(attempt),
            prior_work: Keyword.get(opts, :prior_work, false),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{State.issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        RetryEngine.schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          tracker_identity: Issue.tracker_identity(issue),
          error: "failed to spawn agent: #{inspect(reason)}",
          prior_work: Keyword.get(opts, :prior_work, false),
          worker_host: worker_host
        })
    end
  end

  defp dispatch_attempt_ticket(%Issue{} = issue) do
    case dispatch_attempt_identity(issue) do
      identity when is_binary(identity) ->
        "ticket-" <> (:crypto.hash(:sha256, identity) |> Base.encode16(case: :lower))

      nil ->
        "ticket-" <> (10 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
    end
  end

  # Attempt IDs are retained in Decision provenance, whose identity fields are
  # deliberately bounded and exclude arbitrary tracker payload. Hash the stable
  # tracker identity so accepted Decisions keep a collision-resistant correlator
  # without persisting a raw identifier such as `repo#1` or an overlong value.
  defp dispatch_attempt_identity(%Issue{identifier: identifier, id: issue_id}) do
    Enum.find([identifier, issue_id], &(is_binary(&1) and &1 != ""))
  end

  defp record_rework_resume(%Issue{} = issue, attempt_id) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "rework" do
      TelemetryLifecycle.record(
        issue.identifier,
        attempt_id,
        :agent_resume,
        :point,
        %{cause: :rework_dispatch}
      )
    end
  end

  defp default_running_control(%Issue{} = issue) do
    backend = CodingAgent.backend_for(issue)

    %{
      can_interrupt: CodingAgent.can_interrupt?(backend),
      safe_checkpoints: CodingAgent.safe_checkpoints(backend),
      immediate_delivery: CodingAgent.immediate_delivery?(backend),
      status: :working
    }
  end
end
