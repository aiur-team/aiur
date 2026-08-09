defmodule Aiur.Orchestrator.Dispatcher do
  @moduledoc """
  Dispatch execution: choose loop, revalidation, thrash breaker, worker spawn.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{AgentRunner, AlertFeed, Alerts, CodingAgent, Config, DispatchBudgetStore, Issue, RepoBase, Tracker}
  alias Aiur.GitHub.{AuthPreflight, CiReadiness, CycleFetchCache, Errors}
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Orchestrator

  alias Aiur.Orchestrator.{
    AutoResume,
    CiLifecycle,
    CommandScan,
    CommentPolling,
    DispatchPolicy,
    IssueSync,
    Lifecycle,
    PrAnchored,
    Reconciler,
    RetryEngine,
    Slots,
    State,
    StatusReport,
    TrackedSet,
    TrackerHealth
  }

  alias Aiur.RunTelemetry, as: RunTelemetry
  alias Aiur.RunTelemetry.Lifecycle, as: TelemetryLifecycle

  @ci_readiness_timeout_ms 5_000
  @ci_readiness_retry_ms 60_000

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
    CycleFetchCache.start_cycle()

    try do
      maybe_dispatch(state, &do_maybe_dispatch/1)
    after
      CycleFetchCache.end_cycle()
    end
  end

  @doc false
  @spec maybe_dispatch(State.t(), (State.t() -> State.t())) :: State.t()
  def maybe_dispatch(%State{} = state, dispatch_fun) when is_function(dispatch_fun, 1) do
    maybe_dispatch(state, dispatch_fun, &TrackerHealth.ensure_tracker_preflight/1)
  end

  @doc false
  @spec maybe_dispatch(
          State.t(),
          (State.t() -> State.t()),
          (State.t() -> {:ok, State.t()} | {:error, term(), State.t()})
        ) :: State.t()
  def maybe_dispatch(%State{} = state, dispatch_fun, preflight_fun)
      when is_function(dispatch_fun, 1) and is_function(preflight_fun, 1) do
    state = Reconciler.reconcile_running_lifecycle(state)

    case preflight_fun.(state) do
      {:ok, state} ->
        state
        |> clear_tracker_preflight_alert()
        |> dispatch_fun.()

      {:error, reason, state} ->
        TrackerHealth.log_tracker_preflight_error(reason)
        emit_tracker_preflight_alert(state, reason)
    end
  end

  defp do_maybe_dispatch(%State{} = state) do
    state = maybe_warn_ci_readiness(state)
    state = TrackedSet.refresh(state)
    state = CommentPolling.poll_github_firehose(state)
    state = CommentPolling.poll_github_comments(state)
    state = CiLifecycle.poll_github_ci(state)
    state = Reconciler.refresh_running_issue_states(state)
    state = CommandScan.scan_pr_commands(state)
    state = PrAnchored.maybe_stop_closed_pr_anchored_agents(state)

    case fetch_candidate_issues(state) do
      {:ok, issues, state} ->
        state =
          state
          |> IssueSync.sync_polled_issue_state(issues)
          |> IssueSync.sync_todo_capacity_alert(issues)

        # The poll just refreshed `last_polled_issues`, so this generation can
        # replace a retained snapshot from a prior same-name orchestrator.
        state = %{state | snapshot_ready?: true}

        # The poll just refreshed `last_polled_issues`, so push a fresh
        # summary out to any open agent-list pane immediately.
        StatusReport.notify_dashboard(state)

        # Re-dispatch tickets parked on a transient pause/error whose backoff
        # has elapsed (#1453). Runs before normal dispatch so a restored ticket
        # is claimed and won't double-dispatch below.
        state = AutoResume.maybe_resume(state, System.monotonic_time(:millisecond))

        state =
          state
          |> dispatch_or_hold(issues)
          |> IssueSync.sync_capacity_starvation_alert(issues)
          |> IssueSync.sync_fleet_capacity_starved_alert(issues)

        %{state | initial_dispatch_cycle: false}

      {:error, reason, state} ->
        TrackerHealth.log_tracker_fetch_error(reason)
        state
    end
  end

  # Readiness is advisory at dispatch: the operator may be deliberately
  # setting up a repository mid-run, so this must never hold otherwise-valid
  # tickets. A transient inspection failure retries on subsequent polls, but
  # only emits its needs-attention alert once.
  @doc false
  @spec maybe_warn_ci_readiness(State.t()) :: State.t()
  def maybe_warn_ci_readiness(state) do
    state = reset_ci_readiness_for_config_change(state)
    do_maybe_warn_ci_readiness(state)
  end

  defp do_maybe_warn_ci_readiness(%State{ci_readiness_checked: true} = state) do
    if Config.tracker_kind() == "github" do
      reconcile_completed_ci_readiness(state)
    else
      state
    end
  end

  defp do_maybe_warn_ci_readiness(%State{ci_readiness_retry_at_ms: retry_at_ms} = state) when is_integer(retry_at_ms) do
    if retry_at_ms > System.monotonic_time(:millisecond) do
      state
    else
      start_initial_ci_readiness_check(state, Config.tracker_kind(), Config.base_branch(), CiReadiness.check_fun())
    end
  end

  defp do_maybe_warn_ci_readiness(%State{initial_dispatch_cycle: true} = state) do
    start_initial_ci_readiness_check(state, Config.tracker_kind(), Config.base_branch(), CiReadiness.check_fun())
  end

  defp do_maybe_warn_ci_readiness(state), do: state

  defp reset_ci_readiness_for_config_change(state) do
    scope = CiReadiness.readiness_scope(base_branch: Config.base_branch())

    if state.ci_readiness_scope == scope do
      state
    else
      if is_pid(state.ci_readiness_check_pid) and Process.alive?(state.ci_readiness_check_pid) do
        Process.exit(state.ci_readiness_check_pid, :kill)
      end

      %{
        state
        | ci_readiness_checked: false,
          ci_readiness_unavailable_alerted: false,
          ci_readiness_check_pid: nil,
          ci_readiness_check_token: nil,
          ci_readiness_retry_at_ms: System.monotonic_time(:millisecond),
          ci_readiness_scope: scope,
          ci_readiness_result: nil
      }
    end
  end

  defp reconcile_completed_ci_readiness(state) do
    case CiReadiness.cached_result(base_branch: Config.base_branch()) do
      :unavailable ->
        state = %{state | ci_readiness_checked: false, ci_readiness_result: nil}
        start_initial_ci_readiness_check(state, Config.tracker_kind(), Config.base_branch(), CiReadiness.check_fun())

      result when result == state.ci_readiness_result ->
        state

      result ->
        accept_cached_ci_readiness_result(state, result, &Alerts.emit_system/2)
    end
  end

  @doc false
  @spec start_initial_ci_readiness_check(State.t(), String.t() | nil, String.t(), function()) :: State.t()
  def start_initial_ci_readiness_check(%State{ci_readiness_checked: true} = state, _kind, _base_branch, _check_fun), do: state

  def start_initial_ci_readiness_check(%State{ci_readiness_check_pid: pid} = state, _kind, _base_branch, _check_fun) when is_pid(pid),
    do: state

  def start_initial_ci_readiness_check(state, "github", base_branch, check_fun) do
    parent = self()
    token = make_ref()

    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
           send(parent, {:ci_readiness_result, token, check_fun.(base_branch: base_branch, timeout_ms: @ci_readiness_timeout_ms)})
         end) do
      {:ok, pid} ->
        Process.send_after(parent, {:ci_readiness_timeout, token}, @ci_readiness_timeout_ms)
        %{state | ci_readiness_check_pid: pid, ci_readiness_check_token: token, ci_readiness_retry_at_ms: nil}

      {:error, reason} ->
        record_ci_readiness_result(state, {:error, reason}, &Alerts.emit_system/2)
    end
  end

  def start_initial_ci_readiness_check(state, _kind, _base_branch, _check_fun), do: %{state | ci_readiness_checked: true}

  @doc false
  @spec handle_ci_readiness_result(State.t(), reference(), {:ok, CiReadiness.result()} | {:error, term()}) :: State.t()
  def handle_ci_readiness_result(%State{ci_readiness_check_token: token} = state, token, result) do
    state
    |> clear_ci_readiness_check()
    |> record_ci_readiness_result(result, &Alerts.emit_system/2)
  end

  def handle_ci_readiness_result(state, _token, _result), do: state

  @doc false
  @spec handle_ci_readiness_timeout(State.t(), reference()) :: State.t()
  def handle_ci_readiness_timeout(%State{ci_readiness_check_token: token, ci_readiness_check_pid: pid} = state, token) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)

    state
    |> clear_ci_readiness_check()
    |> record_ci_readiness_result({:error, :timeout}, &Alerts.emit_system/2)
  end

  def handle_ci_readiness_timeout(state, _token), do: state

  defp clear_ci_readiness_check(state), do: %{state | ci_readiness_check_pid: nil, ci_readiness_check_token: nil}

  @doc false
  @spec check_initial_ci_readiness(State.t(), String.t() | nil, String.t(), function(), function()) :: State.t()
  def check_initial_ci_readiness(%State{ci_readiness_checked: true} = state, _kind, _base_branch, _check_fun, _emit_fun), do: state

  def check_initial_ci_readiness(state, "github", base_branch, check_fun, emit_fun) do
    record_ci_readiness_result(state, check_fun.(base_branch: base_branch), emit_fun)
  end

  def check_initial_ci_readiness(state, _kind, _base_branch, _check_fun, _emit_fun), do: %{state | ci_readiness_checked: true}

  defp record_ci_readiness_result(state, {:ok, %{ready?: true} = readiness}, _emit_fun) do
    CiReadiness.cache_result(readiness)
    %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
  end

  defp record_ci_readiness_result(state, {:ok, readiness}, emit_fun) do
    CiReadiness.cache_result(readiness)

    emit_fun.("system.ci_readiness.not_ready",
      message: "Repository CI readiness is incomplete",
      reason: CiReadiness.format(readiness),
      needs_attention: true,
      severity: "warning"
    )

    %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
  end

  defp record_ci_readiness_result(state, {:error, reason}, emit_fun) do
    if retryable_ci_readiness_error?(reason) do
      maybe_emit_ci_readiness_unavailable(state, reason, emit_fun)

      %{
        state
        | ci_readiness_unavailable_alerted: true,
          ci_readiness_retry_at_ms: System.monotonic_time(:millisecond) + ci_readiness_retry_delay_ms(reason),
          ci_readiness_result: nil
      }
    else
      readiness = CiReadiness.unavailable(Config.base_branch(), reason)
      CiReadiness.cache_result(readiness)
      maybe_emit_ci_readiness_unavailable(state, reason, emit_fun)
      %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
    end
  end

  defp accept_cached_ci_readiness_result(state, %{ready?: true} = readiness, _emit_fun) do
    %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
  end

  defp accept_cached_ci_readiness_result(state, readiness, emit_fun) do
    emit_fun.("system.ci_readiness.not_ready",
      message: "Repository CI readiness is incomplete",
      reason: CiReadiness.format(readiness),
      needs_attention: true,
      severity: "warning"
    )

    %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
  end

  defp retryable_ci_readiness_error?(:timeout), do: true
  defp retryable_ci_readiness_error?(reason), do: Errors.retryable_github_error?(reason)

  defp ci_readiness_retry_delay_ms({:github, :rate_limited, detail}) when is_map(detail) do
    case Map.get(detail, :retry_after) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1_000
      _ -> retry_delay_from_reset(Map.get(detail, :reset_at)) || @ci_readiness_retry_ms
    end
  end

  defp ci_readiness_retry_delay_ms(_reason), do: @ci_readiness_retry_ms

  defp retry_delay_from_reset(reset_at) when is_binary(reset_at) do
    case DateTime.from_iso8601(reset_at) do
      {:ok, reset_at, _offset} -> max(DateTime.diff(reset_at, DateTime.utc_now(), :millisecond), 0)
      _ -> nil
    end
  end

  defp retry_delay_from_reset(_reset_at), do: nil

  defp maybe_emit_ci_readiness_unavailable(%State{ci_readiness_unavailable_alerted: true}, _reason, _emit_fun), do: :ok

  defp maybe_emit_ci_readiness_unavailable(_state, reason, emit_fun) do
    emit_fun.("system.ci_readiness.unavailable",
      message: "Repository CI readiness could not be inspected",
      reason: "CI readiness inspection failed: #{inspect(reason)}",
      needs_attention: true,
      severity: "warning"
    )
  end

  # The prewarm gate holds the whole fleet while the warm base builds/clones.
  # That can persist across many poll cycles, so the hold is logged at most once
  # per this many consecutive hold ticks instead of every tick (which would bury
  # the signal in a wall of identical lines) — but still often enough that a
  # slow or permanently-stuck base build stays visible in the daemon log.
  @prewarm_hold_log_interval_ticks 30

  defp fetch_candidate_issues(%State{} = state) do
    if Config.tracker_kind() == "github" do
      case GitHubTracker.fetch_issues_by_states_conditional(
             Config.active_states(),
             issue_list_cache(state)
           ) do
        {:ok, issues, cache} -> {:ok, issues, put_issue_list_cache(state, cache)}
        {:error, reason} -> {:error, reason, state}
      end
    else
      case Tracker.fetch_candidate_issues() do
        {:ok, issues} -> {:ok, issues, state}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp issue_list_cache(%State{ci_lifecycle: ci_lifecycle}) do
    ci_lifecycle |> Map.get(:poll_cache, %{}) |> Map.get(:issue_list_cache, %{})
  end

  defp put_issue_list_cache(%State{} = state, cache) do
    update_in(state.ci_lifecycle.poll_cache, &Map.put(&1 || %{}, :issue_list_cache, cache))
  end

  # The base is readied before CPU admission so per-issue workspaces can use it
  # instead of cold-cloning. A failed build deliberately falls back to dispatch,
  # while an in-progress build holds this tick. The hold is made observable (see
  # log_prewarm_hold/2) so a gated fleet is distinguishable from an idle one.
  @spec dispatch_or_hold(State.t(), [Issue.t()]) :: State.t()
  def dispatch_or_hold(%State{} = state, issues) when is_list(issues) do
    dispatch_or_hold(state, issues, &trigger_and_status/0)
  end

  @doc false
  # Testable variant with an injected phase reader; the production path passes
  # `&RepoBase.refresh_for_dispatch/0` via `trigger_and_status/0`.
  @spec dispatch_or_hold(State.t(), [Issue.t()], (-> term())) :: State.t()
  def dispatch_or_hold(%State{} = state, issues, trigger_fun)
      when is_list(issues) and is_function(trigger_fun, 0) do
    dispatch_or_hold(state, issues, trigger_fun, [])
  end

  @doc false
  @spec dispatch_or_hold(State.t(), [Issue.t()], (-> term()), keyword()) :: State.t()
  def dispatch_or_hold(%State{} = state, issues, trigger_fun, opts)
      when is_list(issues) and is_function(trigger_fun, 0) and is_list(opts) do
    # Constraints are re-sampled every tick, so a stale gate never lingers in
    # `status` after the condition clears.
    state = %{state | dispatch_capacity_constraints: []}

    enabled? = Config.prewarm_enabled?()
    phase = if enabled?, do: trigger_fun.(), else: :ready
    log_fun = Keyword.get(opts, :log_fun, &Logger.info/1)
    admission_probes_fun = Keyword.get(opts, :admission_probes_fun, &admission_probes/0)

    case DispatchPolicy.prewarm_gate(enabled?, phase) do
      :dispatch ->
        maybe_log_base_error(phase)

        state
        |> clear_prewarm_blocked_alert()
        |> Map.put(:prewarm_hold_ticks, 0)
        |> maybe_choose_under_load(issues, &maybe_choose/2, admission_probes_fun: admission_probes_fun)

      :hold ->
        state
        |> maybe_sample_host_pressure_under_prewarm_hold(issues, admission_probes_fun)
        |> log_prewarm_hold(phase, log_fun)
        |> emit_prewarm_blocked_alert(phase)
    end
  end

  # Sample host pressure even though prewarm already decided the hold.
  # Otherwise a prewarm phase that flickers ready/:building across ticks drops
  # `load`/`memory`/`fd` from the constraint set, and IssueSync restarts the age
  # of a gate that never actually cleared — suppressing the starvation alert for
  # as long as prewarm keeps oscillating. Only probe when ready work exists,
  # since that is the sole condition the starvation alert reports on.
  defp maybe_sample_host_pressure_under_prewarm_hold(%State{} = state, [], _admission_probes_fun), do: state

  defp maybe_sample_host_pressure_under_prewarm_hold(%State{} = state, issues, admission_probes_fun)
       when is_list(issues) and is_function(admission_probes_fun, 0) do
    probes = admission_probes_fun.()
    state |> record_capacity_sample(probes) |> record_capacity_constraints(probes)
  end

  @doc false
  @spec emit_prewarm_blocked_alert(State.t(), atom()) :: State.t()
  def emit_prewarm_blocked_alert(%State{prewarm_blocked_alert_active: true} = state, phase),
    do: record_capacity_constraint(state, :build, "prewarm=#{phase}")

  def emit_prewarm_blocked_alert(%State{} = state, phase) do
    reason =
      "Prewarm is #{phase}; fleet dispatch is paused until the shared base becomes ready. " <>
        "This condition is expected to clear automatically."

    state = record_capacity_constraint(state, :build, "prewarm=#{phase}")

    case Alerts.emit_system("system.dispatch.prewarm_blocked",
           reason: reason,
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        %{state | prewarm_blocked_alert_active: true, prewarm_blocked_alert_resolution_emitted: false}

      {:error, _reason} ->
        state
    end
  end

  @doc false
  @spec clear_prewarm_blocked_alert(State.t()) :: State.t()
  def clear_prewarm_blocked_alert(%State{prewarm_blocked_alert_resolution_emitted: true} = state),
    do: %{state | prewarm_blocked_alert_active: false}

  def clear_prewarm_blocked_alert(%State{} = state) do
    active? =
      state.prewarm_blocked_alert_active or
        AlertFeed.active_system_attention?("system.dispatch.prewarm_blocked")

    if active? do
      case Alerts.emit_system("system.dispatch.prewarm_blocked.resolved",
             reason: "Shared prewarm is ready; fleet dispatch may resume.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok -> %{state | prewarm_blocked_alert_active: false, prewarm_blocked_alert_resolution_emitted: true}
        {:error, _reason} -> state
      end
    else
      %{state | prewarm_blocked_alert_active: false, prewarm_blocked_alert_resolution_emitted: true}
    end
  end

  @doc false
  @spec emit_tracker_preflight_alert(State.t(), term()) :: State.t()
  def emit_tracker_preflight_alert(%State{} = state, reason) do
    case tracker_preflight_alert_context(reason) do
      {:ok, signature, formatted_reason} ->
        emit_tracker_preflight_alert(state, signature, formatted_reason)

      :ignore ->
        state
    end
  end

  defp emit_tracker_preflight_alert(
         %State{tracker_preflight_alert_signature: previous_signature} = state,
         signature,
         formatted_reason
       ) do
    if previous_signature == signature do
      state
    else
      message =
        "GitHub tracker authentication preflight failed; fleet dispatch is paused. Cause: " <>
          "#{formatted_reason} This condition is expected to clear automatically once tracker authentication succeeds."

      case Alerts.emit_system("system.tracker.auth_preflight_failed",
             reason: message,
             needs_attention: true,
             severity: "warning"
           ) do
        :ok ->
          %{state | tracker_preflight_alert_signature: signature, tracker_preflight_alert_resolution_emitted: false}

        {:error, _reason} ->
          state
      end
    end
  end

  @doc false
  @spec clear_tracker_preflight_alert(State.t()) :: State.t()
  def clear_tracker_preflight_alert(%State{tracker_preflight_alert_resolution_emitted: true} = state),
    do: %{state | tracker_preflight_alert_signature: nil}

  def clear_tracker_preflight_alert(%State{} = state) do
    active? =
      not is_nil(state.tracker_preflight_alert_signature) or
        AlertFeed.active_system_attention?("system.tracker.auth_preflight_failed")

    if active? do
      case Alerts.emit_system("system.tracker.auth_preflight_failed.resolved",
             reason: "GitHub tracker authentication preflight recovered; fleet dispatch may resume.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok -> %{state | tracker_preflight_alert_signature: nil, tracker_preflight_alert_resolution_emitted: true}
        {:error, _reason} -> state
      end
    else
      %{state | tracker_preflight_alert_signature: nil, tracker_preflight_alert_resolution_emitted: true}
    end
  end

  defp tracker_preflight_alert_context({:github_auth_preflight_failed, diagnostic} = reason)
       when is_map(diagnostic) do
    formatted_reason = AuthPreflight.format_auth_preflight_error(reason)
    classification = Map.get(diagnostic, :reason) || Map.get(diagnostic, "reason") || :unknown
    repo = Map.get(diagnostic, :repo) || Map.get(diagnostic, "repo") || "unknown"

    {:ok, "github-auth:#{classification}:#{repo}", "#{formatted_reason} (classification=#{classification})"}
  end

  defp tracker_preflight_alert_context(:missing_github_token) do
    {:ok, "github-auth:missing_github_token", ":missing_github_token (classification=missing_github_token)"}
  end

  defp tracker_preflight_alert_context(_reason), do: :ignore

  # CPU load admission applies to NEW work only. Retries and reactivations bypass
  # this function so a capacity wait never burns their retry budget.
  @spec maybe_choose_under_load(State.t(), [Issue.t()]) :: State.t()
  def maybe_choose_under_load(%State{} = state, issues) when is_list(issues) do
    maybe_choose_under_load(state, issues, &maybe_choose/2, [])
  end

  @doc false
  @spec maybe_choose_under_load(State.t(), [Issue.t()], (State.t(), [Issue.t()] -> State.t())) :: State.t()
  def maybe_choose_under_load(%State{} = state, issues, choose_fun)
      when is_list(issues) and is_function(choose_fun, 2) do
    maybe_choose_under_load(state, issues, choose_fun, [])
  end

  @doc false
  @spec maybe_choose_under_load(State.t(), [Issue.t()], (State.t(), [Issue.t()] -> State.t()), keyword()) :: State.t()
  def maybe_choose_under_load(%State{} = state, issues, choose_fun, opts)
      when is_list(issues) and is_function(choose_fun, 2) and is_list(opts) do
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
    admission_probes_fun = Keyword.get(opts, :admission_probes_fun, &admission_probes/0)
    probes = admission_probes_fun.()
    queued_demand? = DispatchPolicy.queued_dispatch_demand?(issues, state)

    state =
      DispatchPolicy.update_load_envelope(
        state,
        probes.load,
        probes.target,
        probes.schedulers,
        now_ms,
        probes.cpu_snapshot,
        queued_demand?
      )
      |> maybe_record_load_envelope_constraint()

    # Sample every failing gate before applying admission priority. A memory or
    # FD hold must not erase the age of an independently persistent load hold;
    # IssueSync tracks each recorded gate identity across poll cycles, so the
    # constraint list is deliberately broader than the single binding signal
    # `admission_gate/1` returns below.
    state = record_capacity_constraints(state, probes)
    state = record_capacity_sample(state, probes)

    case DispatchPolicy.admission_gate(Map.put(probes, :queued_demand?, queued_demand?)) do
      {:hold, reason} ->
        # Every admission signal is sampled independently above, so the binding
        # signal is normally already recorded and re-recording it would add a
        # duplicate identity. Fall back to it only when nothing was sampled, so
        # a held fleet always carries at least one constraint and
        # `capacity_starved` can never read an empty list and silently clear.
        state
        |> record_fallback_binding_constraint(reason)
        |> reconcile_capacity_hold({:hold, reason}, now_ms, opts)

      :dispatch ->
        state =
          reconcile_capacity_hold(
            state,
            envelope_hold(state, probes.load, probes.target, probes.schedulers, queued_demand?),
            now_ms,
            opts
          )

        choose_fun.(state, issues)
    end
  end

  # Shared host-pressure probe reads for the normal dispatch path
  # (`maybe_choose_under_load/4`) and the auto-resume admission mirror
  # (`auto_resume_admission/1`). Every signal fails open when disabled or
  # unavailable, so an explicit-disable config never touches a Linux-specific
  # probe. `queued_demand?` is caller-specific (the normal path derives it from
  # the whole board; the auto-resume mirror treats the pending ticket itself as
  # the demand) and is injected at the gate.
  defp admission_probes do
    hard_threshold = Config.max_load_average()
    target = Config.target_load_average()
    run_queue_threshold = Config.run_queue_threshold()
    memory_threshold_mb = Config.min_free_memory_mb()
    schedulers = System.schedulers_online()
    load = DispatchPolicy.read_load(hard_threshold, target)
    cpu_snapshot = DispatchPolicy.read_cpu(target, run_queue_threshold)

    %{
      memory_mb: DispatchPolicy.read_memory(memory_threshold_mb),
      memory_threshold_mb: memory_threshold_mb,
      fd_sample: DispatchPolicy.read_file_descriptors(),
      runnable: runnable_from(cpu_snapshot),
      run_queue_threshold: run_queue_threshold,
      schedulers: schedulers,
      load: load,
      load_threshold: hard_threshold,
      build_status: DispatchPolicy.read_build_status(),
      provider_backends: DispatchPolicy.read_provider_backends(),
      cpu_snapshot: cpu_snapshot,
      target: target
    }
  end

  @doc false
  # Auto-resume admission mirror (#1453 review P1). The normal dispatch path
  # gates new work on the global pause switch, concurrent-agent capacity, the
  # prewarm hold, and the host-pressure admission signals; the transient
  # auto-resume path used to bypass all of them and spawn directly via
  # `dispatch_issue/2`. This runs the same gates so an automatic resume can
  # never spawn during an operator halt or an over-capacity / gated fleet.
  # Returns `:dispatch` or `{:hold, reason}` (an atom naming the binding
  # signal). Runs inside the orchestrator GenServer process, so no concurrent
  # dispatch can interleave between this check and the subsequent spawn.
  @spec auto_resume_admission(State.t()) :: :dispatch | {:hold, atom()}
  def auto_resume_admission(%State{globally_paused: true}),
    do: {:hold, :global_pause}

  def auto_resume_admission(%State{} = state) do
    cond do
      Slots.available_slots(state) == 0 ->
        {:hold, :max_concurrent_agents}

      prewarm_hold?() ->
        {:hold, :prewarm}

      true ->
        probes = admission_probes()

        case DispatchPolicy.admission_gate(Map.put(probes, :queued_demand?, true)) do
          :dispatch -> :dispatch
          {:hold, reason} -> {:hold, reason.signal}
        end
    end
  end

  defp prewarm_hold? do
    enabled? = Config.prewarm_enabled?()
    phase = if enabled?, do: trigger_and_status(), else: :ready
    DispatchPolicy.prewarm_gate(enabled?, phase) == :hold
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

        dispatch_after_workspace_wait_or_thrash_check(state, selected_issue, attempt, preferred_worker_host, opts)
    end
  end

  defp dispatch_after_workspace_wait_or_thrash_check(state, selected_issue, attempt, preferred_worker_host, opts) do
    workspace_ownership = state.dispatch_recovery.workspace_ownership

    case Map.pop(workspace_ownership.ready, selected_issue.id) do
      {nil, _ready} ->
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

      {envelope, ready} ->
        workspace_ownership = %{
          workspace_ownership
          | ready: ready
        }

        state = put_in(state.dispatch_recovery.workspace_ownership, workspace_ownership)
        envelope_attempt = Map.get(envelope, :retry_attempt, attempt) || attempt
        envelope_host = Map.get(envelope, :worker_host, preferred_worker_host) || preferred_worker_host

        envelope_opts =
          Keyword.put(
            opts,
            :prior_work,
            Map.get(envelope, :prior_work, Keyword.get(opts, :prior_work, false))
          )

        dispatch_to_worker(state, selected_issue, envelope_attempt, envelope_host, envelope_opts)
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
         :ok <- redispatch_worker_slot(state, selected_issue, preferred_worker_host) do
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
         :ok <- redispatch_worker_slot(state, selected_issue, preferred_worker_host) do
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
    previous = Map.get(thrash_budget(state), issue_id)
    entry = next_thrash_budget_entry(state, issue_id, now_ms)

    if active_trip?(previous, now_ms) or not is_nil(budget_trip_reason(entry)),
      do: {:error, :thrash_circuit_open},
      else: :ok
  end

  defp admit_redispatch_thrash_budget(state, issue, now_ms, opts) do
    previous = Map.get(thrash_budget(state), issue.id)
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
          state = put_thrash_budget(state, Map.put(thrash_budget(state), issue.id, tripped))
          {:error, :thrash_circuit_open, trip.(state, issue)}
      end
    end
  end

  # A backend swap replaces the issue's existing host slot. Exclude that entry
  # from the capacity sample, but require an exact preferred-host match so the
  # workspace and on-disk rollout never migrate during the swap.
  defp redispatch_worker_slot(state, issue, preferred_worker_host) do
    capacity_state = %{state | running: Map.delete(state.running, issue.id)}

    case select_worker_host(capacity_state, issue, preferred_worker_host) do
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
  #
  # The window counter is the loop-frequency guard and counts every dispatch
  # attempt. The lifetime counter is the structural-stuck latch and counts
  # only dispatches that actually survived provisioning (see
  # `record_dispatch_committed/2`) — a preflight / prewarm / tracker-auth
  # failure never reaches the runner's commit point, so it never bills the
  # ticket a lifetime unit. The gate checks both but increments neither
  # persistable lifetime: a latched ticket trips before paying workspace
  # clone cost.
  @spec check_thrash_budget(State.t(), String.t(), integer()) ::
          {:ok, State.t()} | {:trip, State.t()}
  def check_thrash_budget(%State{} = state, issue_id, now_ms) do
    previous = Map.get(thrash_budget(state), issue_id)

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
        state = put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, entry))
        {:ok, state}

      reason ->
        tripped = trip_budget_entry(previous, entry, reason)
        state = put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, tripped))
        {:trip, state}
    end
  end

  @doc false
  # Commits a lifetime dispatch unit for a ticket whose runner has survived
  # provisioning (workspace created, session about to start). This is the
  # ONLY place the lifetime counter grows: preflight, prewarm-gate, and
  # tracker-auth failures never reach it, so infrastructure faults no longer
  # walk a ticket to the latch without it ever doing agent work (#1453).
  # Returns `state` unchanged when the latch is disabled (`0`).
  @spec record_dispatch_committed(State.t(), String.t()) :: State.t()
  def record_dispatch_committed(%State{} = state, issue_id) when is_binary(issue_id) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 ->
        lifetime = max(lifetime_of(Map.get(thrash_budget(state), issue_id)), persisted_lifetime(issue_id)) + 1
        entry = Map.get(thrash_budget(state), issue_id, %{})

        # The in-memory count is updated even when the durable write fails so
        # the latch still bounds a stuck ticket within this daemon generation
        # while the store is broken (the fail-open `persisted_lifetime/1` keeps
        # it from latching every ticket fleet-wide).
        case DispatchBudgetStore.put_lifetime(issue_id, lifetime) do
          :ok ->
            put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, Map.put(entry, :lifetime, lifetime)))

          {:error, reason} ->
            Logger.error("Dispatch budget commit failed (in-memory count retained): issue_id=#{issue_id} reason=#{inspect(reason)}")
            put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, Map.put(entry, :lifetime, lifetime)))
        end

      _ ->
        state
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
          lifetime: candidate.lifetime
        }

    spent
    |> Map.put(:tripped, reason)
    |> Map.put(:alert_emitted, false)
  end

  # The window counter resets on every lapsed window, so a ticket that churns
  # slowly (a dispatch every few minutes) never trips it — that is how a single
  # ticket accumulated 85 cold dispatches. `lifetime` counts only dispatches
  # that committed real work (see `record_dispatch_committed/2`) and survives
  # `reset_thrash_budget/2`, so a structurally-stuck ticket latches instead of
  # burning quota forever. `0` (the default) disables the latch, matching the
  # repo's existing "0 disables it" idiom.
  defp lifetime_exhausted?(%{lifetime: lifetime}) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 -> lifetime >= max
      _ -> false
    end
  end

  defp next_thrash_budget_entry(state, issue_id, now_ms) do
    window_ms = Config.codex_thrash_window_seconds() * 1_000
    previous = Map.get(thrash_budget(state), issue_id)
    lifetime = max(lifetime_of(previous), persisted_lifetime(issue_id))

    case previous do
      %{window_start_ms: start, count: count} when now_ms - start < window_ms ->
        %{window_start_ms: start, count: count + 1, lifetime: lifetime}

      _ ->
        %{window_start_ms: now_ms, count: 1, lifetime: lifetime}
    end
  end

  defp lifetime_of(%{lifetime: lifetime}) when is_integer(lifetime), do: lifetime
  defp lifetime_of(_entry), do: 0

  # Fails open: an unreadable/corrupt budget store logs loudly but returns 0
  # so a single bad JSON file cannot latch every ticket in the repo at once
  # (the pre-#1453 behaviour). The window thrash guard still bounds rapid
  # respawn loops; the lifetime latch simply degrades to disabled until the
  # store is repaired, which is the safe direction for a data-integrity fault.
  defp persisted_lifetime(issue_id) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 ->
        case DispatchBudgetStore.lifetime(issue_id) do
          {:ok, lifetime} ->
            lifetime

          {:error, reason} ->
            Logger.error("Dispatch budget store read failed; treating lifetime as 0 (latch disabled): issue_id=#{issue_id} reason=#{inspect(reason)}")
            0
        end

      _ ->
        0
    end
  end

  # Single-store-read batch form for `dispatch_latch_statuses/2`; returns a
  # plain map of issue_id => lifetime (missing entries are 0) or `%{}` on an
  # unreadable store (fail-open, matching `persisted_lifetime/1`).
  defp read_lifetimes_once do
    case DispatchBudgetStore.lifetimes() do
      {:ok, lifetimes} when is_map(lifetimes) ->
        lifetimes

      {:error, reason} ->
        Logger.error("Dispatch budget store read failed; treating lifetime as 0 (latch disabled): reason=#{inspect(reason)}")
        %{}
    end
  end

  # Clears the window so an operator resume can move the ticket again, but
  # deliberately preserves `lifetime`: the dispatches that committed real work
  # were really spent, and refunding them would let a resume loop bypass the
  # latch forever. Only `reset_lifetime_budget/2` (the documented
  # `aiurdev reset-budget` exit) clears lifetime.
  @spec reset_thrash_budget(State.t(), String.t()) :: State.t()
  def reset_thrash_budget(%State{} = state, issue_id) do
    case Map.get(thrash_budget(state), issue_id) do
      %{lifetime: lifetime} when is_integer(lifetime) and lifetime > 0 ->
        entry = %{lifetime: lifetime}
        put_thrash_budget(state, Map.put(thrash_budget(state), issue_id, entry))

      _ ->
        put_thrash_budget(state, Map.delete(thrash_budget(state), issue_id))
    end
  end

  @doc """
  The supported exit from the lifetime dispatch latch: clears both the
  in-memory thrash entry and the durable `dispatch-budgets.json` entry so a
  latched ticket returns to dispatchable without hand-editing the store.

  Returns `{state, :ok}` when the durable clear succeeded, or
  `{state, {:error, reason}}` when the in-memory entry was cleared but the
  durable store write failed — the ticket is dispatchable this generation but
  would re-latch on restart, and the caller must surface the error rather than
  report success (#1453 review P2b).
  """
  @spec reset_lifetime_budget(State.t(), String.t()) :: {State.t(), :ok | {:error, term()}}
  def reset_lifetime_budget(%State{} = state, issue_id) when is_binary(issue_id) do
    # Fully delete the in-memory entry (unlike `reset_thrash_budget/2`, which
    # deliberately preserves lifetime so an operator resume cannot refund it) —
    # this is the documented operator exit, and it must clear both copies.
    state = put_thrash_budget(state, Map.delete(thrash_budget(state), issue_id))

    case DispatchBudgetStore.reset(issue_id) do
      :ok -> {state, :ok}
      {:error, reason} -> {state, {:error, reason}}
    end
  end

  @doc """
  Reports whether a ticket is currently held by the lifetime dispatch latch.
  Used by the resume path (so `aiurdev resume` names the latch instead of
  silently no-opping) and by the idle-reason classification surfaced for
  #1457. Returns `:none` when the latch is disabled, the ticket is under the
  cap, or no durable spend is recorded.
  """
  @spec dispatch_latch_status(State.t(), String.t()) ::
          :none | {:lifetime, non_neg_integer(), pos_integer()}
  def dispatch_latch_status(%State{} = state, issue_id) when is_binary(issue_id) do
    case Config.agent_max_dispatches_per_ticket() do
      max when is_integer(max) and max > 0 ->
        lifetime = max(lifetime_of(Map.get(thrash_budget(state), issue_id)), persisted_lifetime(issue_id))

        if lifetime >= max do
          {:lifetime, lifetime, max}
        else
          :none
        end

      _ ->
        :none
    end
  end

  @doc false
  # Batch variant for the dashboard idle snapshot: the durable budget store is
  # read once for the whole board instead of once per idle ticket, so a fleet
  # of N idle rows costs one file read per snapshot rather than N.
  @spec dispatch_latch_statuses(State.t(), [String.t()]) ::
          %{String.t() => :none | {:lifetime, non_neg_integer(), pos_integer()}}
  def dispatch_latch_statuses(%State{} = state, issue_ids) when is_list(issue_ids) do
    max = Config.agent_max_dispatches_per_ticket()

    persisted =
      if max > 0 do
        read_lifetimes_once()
      else
        %{}
      end

    Map.new(issue_ids, fn issue_id ->
      lifetime = max(lifetime_of(Map.get(thrash_budget(state), issue_id)), Map.get(persisted, issue_id, 0))

      status =
        if max > 0 and lifetime >= max do
          {:lifetime, lifetime, max}
        else
          :none
        end

      {issue_id, status}
    end)
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

  # The active limiting reason for a poll that dispatches: the AIMD envelope
  # counts as capacity backoff when load still exceeds the target (the envelope
  # is holding effective capacity below the static ceiling) while dispatchable
  # work remains. Hard gates above already hold outright; this only names the
  # envelope as the binding constraint. Below-target recovery ramps are not a
  # hold — dispatch is already resuming.
  defp envelope_hold(state, load, target, schedulers, queued_demand?) do
    if queued_demand? and is_number(target) and target > 0 and is_number(load) and
         load > target * schedulers and envelope_backed_off?(state) do
      {:hold,
       %{
         signal: :envelope,
         measured: state.effective_concurrent_agents,
         threshold: Slots.max_concurrent_agent_limit(state)
       }}
    else
      :dispatch
    end
  end

  defp envelope_backed_off?(state) do
    case {state.effective_concurrent_agents, Slots.max_concurrent_agent_limit(state)} do
      {effective, static} when is_integer(effective) and effective > 0 and is_integer(static) and static > 0 ->
        effective < static

      _ ->
        false
    end
  end

  defp runnable_from(%{runnable: runnable}) when is_integer(runnable) and runnable >= 0, do: runnable
  defp runnable_from(_snapshot), do: :unavailable

  @capacity_backoff_alert_ms 30_000

  # Reconciles the persisted `capacity_hold` with this poll's decision so status
  # always reflects the active binding constraint. A `:dispatch` clears any
  # prior hold (emitting a recovery signal); a `{:hold, reason}` starts or
  # extends the hold, emitting a backoff alert once the same signal has
  # persisted past the debounce window.
  defp reconcile_capacity_hold(state, :dispatch, _now_ms, opts) do
    clear_capacity_hold(state, opts)
  end

  defp reconcile_capacity_hold(state, {:hold, reason}, now_ms, opts) do
    log_admission_hold(reason)
    update_capacity_hold(state, reason, now_ms, opts)
  end

  defp clear_capacity_hold(state, opts) do
    case state.capacity_hold do
      nil ->
        state

      %{signal: signal} ->
        emit_fun = Keyword.get(opts, :emit_fun, &default_capacity_alert/2)
        telemetry_fun = Keyword.get(opts, :telemetry_fun, &RunTelemetry.record/2)
        reason = %{signal: signal, measured: nil, threshold: nil}
        emit_fun.("system.fleet.capacity.resumed", reason)
        telemetry_fun.(:capacity_resumed, Aiur.JSONSafe.normalize(reason))
        %{state | capacity_hold: nil}
    end
  end

  defp update_capacity_hold(state, reason, now_ms, opts) do
    emit_fun = Keyword.get(opts, :emit_fun, &default_capacity_alert/2)
    telemetry_fun = Keyword.get(opts, :telemetry_fun, &RunTelemetry.record/2)
    debounce_ms = Keyword.get(opts, :alert_debounce_ms, @capacity_backoff_alert_ms)
    signal = Map.fetch!(reason, :signal)

    case state.capacity_hold do
      %{signal: ^signal, alerted?: true} = hold ->
        %{state | capacity_hold: Map.merge(hold, Map.take(reason, [:measured, :threshold]))}

      %{signal: ^signal, alerted?: false} = hold ->
        hold = Map.merge(hold, Map.take(reason, [:measured, :threshold]))

        if now_ms - hold.held_since_ms < debounce_ms do
          %{state | capacity_hold: hold}
        else
          emit_fun.("system.fleet.capacity.backoff", reason)
          %{state | capacity_hold: Map.put(hold, :alerted?, true)}
        end

      _other ->
        telemetry_fun.(:capacity_hold, Aiur.JSONSafe.normalize(reason))
        %{state | capacity_hold: Map.merge(reason, %{held_since_ms: now_ms, alerted?: false})}
    end
  end

  defp default_capacity_alert(name, reason) do
    Alerts.emit_system(name,
      reason:
        "Fleet admission is being limited by #{capacity_signal_label(reason)} " <>
          "(measured=#{inspect(Map.get(reason, :measured))} threshold=#{inspect(Map.get(reason, :threshold))}).",
      needs_attention: false,
      severity: "info"
    )
  end

  defp capacity_signal_label(%{signal: signal}) when is_atom(signal),
    do: String.replace(Atom.to_string(signal), "_", " ")

  defp capacity_signal_label(_reason), do: "host pressure"

  defp log_admission_hold(%{signal: :memory, measured: available_mb, threshold: threshold_mb}) do
    Logger.info(
      "aiur_perf memory_hold surface=dispatch available_mb=#{available_mb} " <>
        "threshold_mb=#{threshold_mb}"
    )
  end

  defp log_admission_hold(%{signal: :file_descriptors, measured: sample}) do
    log_fd_hold(sample)
  end

  defp log_admission_hold(%{signal: :load, measured: load, threshold: limit}) do
    Logger.info("aiur_perf load_hold load=#{load} limit=#{limit}")
  end

  defp log_admission_hold(%{signal: :run_queue, measured: runnable, threshold: limit}) do
    Logger.info("aiur_perf run_queue_hold runnable=#{runnable} limit=#{limit}")
  end

  defp log_admission_hold(%{signal: :build, measured: measured, threshold: capacity}) do
    Logger.info(
      "aiur_perf build_hold surface=dispatch active=#{inspect(Map.get(measured, :active))} " <>
        "queued=#{inspect(Map.get(measured, :queued))} capacity=#{inspect(capacity)}"
    )
  end

  defp log_admission_hold(%{signal: :envelope, measured: effective, threshold: static}) do
    Logger.info("aiur_perf envelope_hold effective=#{effective} static=#{static}")
  end

  defp log_admission_hold(%{signal: :provider, measured: backends, threshold: _}) do
    Logger.info("aiur_perf provider_hold surface=dispatch backends=#{inspect(backends)} status=all_usage_limited")
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

  # Records every currently-failing host-pressure gate so `status` can explain a
  # non-dispatching fleet and IssueSync can age each gate independently.
  defp record_capacity_constraints(%State{} = state, probes) do
    state
    |> maybe_record_memory_constraint(
      DispatchPolicy.memory_gate(probes.memory_mb, probes.memory_threshold_mb),
      probes.memory_mb,
      probes.memory_threshold_mb
    )
    |> maybe_record_fd_constraint(DispatchPolicy.fd_gate(probes.fd_sample), probes.fd_sample)
    |> maybe_record_load_constraint(
      DispatchPolicy.load_gate(probes.load, probes.load_threshold, probes.schedulers),
      probes.load,
      probes.load_threshold,
      probes.schedulers
    )
    |> maybe_record_run_queue_constraint(
      DispatchPolicy.run_queue_gate(probes.runnable, probes.schedulers, probes.run_queue_threshold),
      probes
    )
    |> maybe_record_build_constraint(
      DispatchPolicy.build_gate(probes.build_status),
      probes.build_status
    )
    |> maybe_record_provider_constraint(
      DispatchPolicy.provider_gate(probes.provider_backends),
      probes.provider_backends
    )
  end

  defp record_capacity_sample(%State{} = state, probes) do
    %{
      state
      | dispatch_capacity_sample: %{
          load: probes.load,
          target: probes.target,
          schedulers: probes.schedulers
        }
    }
  end

  defp maybe_record_run_queue_constraint(state, :hold, probes) do
    record_capacity_constraint(
      state,
      :run_queue,
      "runnable=#{inspect(probes.runnable)} threshold=#{inspect(probes.run_queue_threshold)} " <>
        "schedulers=#{probes.schedulers}"
    )
  end

  defp maybe_record_run_queue_constraint(state, _gate, _probes), do: state

  defp maybe_record_build_constraint(state, :hold, status),
    do: record_capacity_constraint(state, :build_queue, "build=#{inspect(status)}")

  defp maybe_record_build_constraint(state, _gate, _status), do: state

  defp maybe_record_provider_constraint(state, :hold, backends),
    do: record_capacity_constraint(state, :provider, "backends=#{inspect(backends)}")

  defp maybe_record_provider_constraint(state, _gate, _backends), do: state

  defp record_fallback_binding_constraint(%State{dispatch_capacity_constraints: []} = state, %{signal: signal} = reason)
       when is_atom(signal) do
    record_capacity_constraint(
      state,
      binding_constraint_kind(signal),
      "measured=#{inspect(Map.get(reason, :measured))} threshold=#{inspect(Map.get(reason, :threshold))}"
    )
  end

  defp record_fallback_binding_constraint(%State{} = state, _reason), do: state

  # `admission_gate/1`'s `:build` signal is build-queue saturation, which is a
  # different condition from the prewarm hold that records the `:build`
  # constraint kind; keep them distinct so an alert never misattributes one.
  defp binding_constraint_kind(:build), do: :build_queue
  defp binding_constraint_kind(signal), do: signal

  defp maybe_record_memory_constraint(state, :hold, available_memory_mb, threshold_mb) do
    record_capacity_constraint(
      state,
      :memory,
      "available_mb=#{available_memory_mb} threshold_mb=#{threshold_mb}"
    )
  end

  defp maybe_record_memory_constraint(state, _gate, _available_memory_mb, _threshold_mb), do: state

  defp maybe_record_fd_constraint(state, :hold, sample),
    do: record_capacity_constraint(state, :fd, fd_constraint_detail(sample))

  defp maybe_record_fd_constraint(state, _gate, _sample), do: state

  defp maybe_record_load_constraint(state, :hold, load, threshold, schedulers) do
    record_capacity_constraint(
      state,
      :load,
      "load=#{inspect(load)} threshold=#{threshold} schedulers=#{schedulers}"
    )
  end

  defp maybe_record_load_constraint(state, _gate, _load, _threshold, _schedulers), do: state

  defp trigger_and_status do
    RepoBase.refresh_for_dispatch()
  end

  defp maybe_choose(state, issues) do
    if Slots.available_slots(state) > 0, do: choose_issues(state, issues), else: state
  end

  defp maybe_record_load_envelope_constraint(%State{} = state) do
    configured = Slots.max_concurrent_agent_limit(state)
    effective = Slots.effective_concurrent_agent_limit(state)

    if effective < configured do
      record_capacity_constraint(state, :load_envelope, "effective_cap=#{effective} configured_cap=#{configured}")
    else
      state
    end
  end

  defp record_capacity_constraint(%State{} = state, kind, detail) when is_atom(kind) and is_binary(detail) do
    constraint = %{kind: kind, detail: detail}

    if constraint in state.dispatch_capacity_constraints do
      state
    else
      %{state | dispatch_capacity_constraints: [constraint | state.dispatch_capacity_constraints]}
    end
  end

  defp fd_constraint_detail(:exhausted), do: "available=0 limit=unknown"

  defp fd_constraint_detail(%{available: available, limit: limit}) do
    "available=#{available} limit=#{limit}"
  end

  defp fd_constraint_detail(_sample), do: "sample=unknown"

  defp maybe_log_base_error({:error, reason}),
    do: Logger.warning("prewarm base unavailable (#{inspect(reason)}); dispatching via cold clone")

  defp maybe_log_base_error(_phase), do: :ok

  # A silent indefinite hold is the core defect behind #1404: with the warm base
  # warming (or failing to rebuild), every poll tick held dispatch and nothing
  # was logged, so an operator saw an idle fleet instead of a gated one. Count
  # consecutive hold ticks and emit one `aiur_perf prewarm_hold` line at most
  # once per `@prewarm_hold_log_interval_ticks`; the counter resets as soon as
  # the gate lets a tick through, so the interval measures back-to-back holds.
  @doc false
  @spec log_prewarm_hold(State.t(), term()) :: State.t()
  def log_prewarm_hold(%State{} = state, phase), do: log_prewarm_hold(state, phase, &Logger.info/1)

  @doc false
  @spec log_prewarm_hold(State.t(), term(), (String.t() -> term())) :: State.t()
  def log_prewarm_hold(%State{prewarm_hold_ticks: ticks} = state, phase, log_fun)
      when is_function(log_fun, 1) do
    next_ticks = ticks + 1
    state = %{state | prewarm_hold_ticks: next_ticks}

    if rem(next_ticks, @prewarm_hold_log_interval_ticks) == 1 do
      log_fun.("aiur_perf prewarm_hold surface=dispatch phase=#{inspect(phase)}")
    end

    state
  end

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

    case select_worker_host(state, issue, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{State.issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      :preferred_worker_unavailable ->
        Logger.warning("Backend cannot use the preferred SSH worker for #{State.issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, opts)
    end
  end

  defp select_worker_host(state, issue, preferred_worker_host) do
    if CodingAgent.remote_worker?(CodingAgent.backend_for(issue)) do
      Slots.select_worker_host(state, preferred_worker_host)
    else
      if is_nil(preferred_worker_host), do: nil, else: :preferred_worker_unavailable
    end
  end

  defp trip_thrash_breaker(%State{} = state, issue) do
    state = persist_lifetime_trip(state, issue, &Tracker.update_issue_state/2)
    entry = Map.get(thrash_budget(state), issue.id, %{})

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

      alert_body =
        if reason == :lifetime do
          "Ticket is latched by the lifetime dispatch budget (#{lifetime}/#{lifetime_max}). This is terminal, not a transient circuit: `resume` cannot clear it. Run `aiurdev reset-budget #{issue.identifier}` to restore dispatchability (or move the ticket through a documented reset path)."
        else
          "Codex dispatch circuit opened (#{reason}); window restarts=#{count}, lifetime dispatches=#{lifetime}/#{lifetime_max}."
        end

      Alerts.emit_system("ticket.#{issue.identifier}.agent.thrash_circuit_open",
        issue: issue.identifier,
        reason: alert_body,
        needs_attention: true,
        severity: "warning"
      )

      updated_entry = Map.put(entry, :alert_emitted, true)
      put_thrash_budget(state, Map.put(thrash_budget(state), issue.id, updated_entry))
    end
  end

  @doc false
  @spec persist_lifetime_trip(State.t(), Issue.t(), (String.t(), String.t() -> :ok | {:error, term()})) ::
          State.t()
  def persist_lifetime_trip(%State{} = state, %Issue{} = issue, update_state_fun)
      when is_function(update_state_fun, 2) do
    entry = Map.get(thrash_budget(state), issue.id, %{})

    if entry[:tripped] == :lifetime and entry[:durable_latch_applied] != true and
         is_binary(issue.identifier) do
      case update_state_fun.(issue.identifier, "error") do
        :ok ->
          lifetime = Map.get(entry, :lifetime, 0)
          maximum = Config.agent_max_dispatches_per_ticket()

          Alerts.emit_custom(
            "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch",
            "Agent entered error because its lifetime dispatch latch is #{lifetime}/#{maximum}; this will not clear on its own.",
            issue: issue.identifier,
            reason: "Agent entered error because its lifetime dispatch latch is #{lifetime}/#{maximum}; this will not clear on its own.",
            needs_attention: true,
            severity: "warning",
            # IssueSync reconstructs the persisted error cause after a restart
            # from the central feed only, so this attention must land there or
            # it can never be resolved or rearmed.
            central: true
          )

          updated_entry = Map.put(entry, :durable_latch_applied, true)
          state = put_thrash_budget(state, Map.put(thrash_budget(state), issue.id, updated_entry))

          %{
            state
            | claimed: MapSet.delete(state.claimed, issue.id),
              observed_error_alerts: MapSet.put(state.observed_error_alerts, issue.id),
              observed_error_alert_causes: Map.put(state.observed_error_alert_causes, issue.id, :lifetime_latch)
          }

        {:error, reason} ->
          Logger.error("Unable to persist lifetime dispatch latch: issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")

          state
      end
    else
      state
    end
  end

  defp thrash_budget(state), do: state.dispatch_recovery.codex_thrash_budget

  defp put_thrash_budget(state, budget), do: put_in(state.dispatch_recovery.codex_thrash_budget, budget)

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, opts) do
    runner = Keyword.get(opts, :runner, &AgentRunner.run/3)
    worker_generation = System.unique_integer([:positive, :monotonic])
    lifecycle_attempt_id = TelemetryLifecycle.new_attempt_id(dispatch_attempt_ticket(issue))

    if TelemetryLifecycle.enabled?() do
      TelemetryLifecycle.record(issue.identifier, lifecycle_attempt_id, :dispatch, :point, %{
        outcome: :requested,
        complexity: CodingAgent.complexity_level(issue),
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
             orchestrator: recipient,
             worker_generation: worker_generation
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
            session_execution: nil,
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
            control: default_running_control(issue, worker_generation),
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

  defp default_running_control(%Issue{} = issue, worker_generation) when is_integer(worker_generation) do
    backend = CodingAgent.backend_for(issue)

    %{
      can_interrupt: CodingAgent.can_interrupt?(backend),
      safe_checkpoints: CodingAgent.safe_checkpoints(backend),
      immediate_delivery: CodingAgent.immediate_delivery?(backend),
      application_confirmation: CodingAgent.control_application_confirmation(backend),
      generation: worker_generation,
      version: 0,
      status: :working
    }
  end
end
