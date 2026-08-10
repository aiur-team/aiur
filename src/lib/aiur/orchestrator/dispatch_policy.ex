defmodule Aiur.Orchestrator.DispatchPolicy do
  @moduledoc """
  Pure dispatch, load-gate, and issue-candidate policy for the orchestrator.
  """

  alias Aiur.{BuildGate, CodingAgent, Config, Issue, ModelAvailability, SystemCpu, SystemFileDescriptors, SystemLoad, SystemMemory}
  alias Aiur.GitHub.Quota
  alias Aiur.Orchestrator.{Slots, State}

  @cpu_headroom_ramp_max 3
  @fd_headroom_percent 10

  # States in which, by definition, there is no agent work: the PR is sitting in
  # GitHub's merge queue (`merging`) or CI is in flight (`ci-wait`). Dispatching
  # into them cannot produce progress, only cost — and every committed dispatch
  # bills a lifetime unit, so a ticket can burn the terminal (self-declared
  # unrecoverable) latch while waiting for the merge queue, *after* its work was
  # finished and approved (#1759: 48 dispatches in ~50 minutes on a ticket in
  # `merging` with an approved, queued PR).
  #
  # This is a code-level refusal rather than an `active_states` edit because
  # `merging` must stay an active state for comment polling
  # (`CommentPolling.TargetSelection`), the paused-agent sweep, and terminal-fence
  # bookkeeping. `ci-wait` is already excluded from the Executor's paused-agent
  # sweep as legitimate waiting; refusing it here makes the two beliefs
  # consistent regardless of how an operator configures `active_states`.
  #
  # Neither state strands a ticket: leaving `ci-wait` (the CI result delivery and
  # the `ci_wait_rewake` fallback) and leaving `merging` (a trusted comment
  # promoting the ticket to `rework`) both transition the tracker label *first*,
  # so dispatch is re-evaluated against the new state.
  @no_agent_work_states ["merging", "ci-wait"]

  @doc false
  # Reads the host 1-min load only when the hard gate or adaptive target is
  # enabled, so explicit-disable configs never touch /proc. Exposed for
  # unit-testing the short-circuit; the pure hold/dispatch decision is
  # load_gate/3.
  @spec read_load(number() | nil) :: float() | :unavailable
  def read_load(threshold), do: read_load(threshold, nil)

  @spec read_load(number() | nil, number() | nil) :: float() | :unavailable
  def read_load(hard_threshold, target)
      when (is_number(hard_threshold) and hard_threshold > 0) or
             (is_number(target) and target > 0),
      do: SystemLoad.avg1()

  def read_load(_hard_threshold, _target), do: :unavailable

  @doc false
  # Reads the host CPU snapshot when the adaptive envelope or the run-queue gate
  # is enabled, so explicit-disable configs never touch /proc/stat.
  @spec read_cpu(number() | nil, number() | nil) :: SystemCpu.snapshot() | :unavailable
  def read_cpu(target, run_queue_threshold \\ nil)

  def read_cpu(target, run_queue_threshold)
      when (is_number(target) and target > 0) or
             (is_number(run_queue_threshold) and run_queue_threshold > 0),
      do: SystemCpu.snapshot()

  def read_cpu(_target, _run_queue_threshold), do: :unavailable

  @doc false
  # Reads MemAvailable only while memory admission is enabled. Keeping this
  # short-circuit beside read_load/2 prevents disabled configs from touching
  # Linux-specific /proc files.
  @spec read_memory(integer() | nil) :: non_neg_integer() | :unavailable
  def read_memory(threshold) when is_integer(threshold) and threshold > 0,
    do: SystemMemory.available_mb()

  def read_memory(_threshold), do: :unavailable

  @doc false
  @spec read_file_descriptors() :: SystemFileDescriptors.sample_result()
  def read_file_descriptors, do: SystemFileDescriptors.sample()

  @doc false
  # Reads the shared build-gate status. The status call is the authoritative
  # agent-launched Mix concurrency signal (the shell hook owns lock acquisition),
  # so this reads the real gate unless a test seam overrides it. A disabled or
  # unreadable gate yields a `build_gate/1` fail-open.
  @spec read_build_status() :: map()
  def read_build_status do
    case Application.get_env(:aiur, :build_gate_status_override) do
      fun when is_function(fun, 0) -> fun.()
      _other -> BuildGate.status()
    end
  end

  @doc false
  # Dispatchable backends whose configured provider usage limits participate in
  # fleet admission. When every one of them is usage-limited, `provider_gate/1`
  # holds new admissions (a fleet-wide provider-limit signal).
  @spec read_provider_backends() :: [String.t()]
  def read_provider_backends do
    Config.agent_backend_configs() |> CodingAgent.dispatchable_backends()
  end

  @doc false
  @spec read_github_quota() :: :available | {:hold, map()}
  def read_github_quota do
    case Application.get_env(:aiur, :github_quota_status_override) do
      :available -> :available
      {:hold, %{} = hold} -> {:hold, hold}
      fun when is_function(fun, 0) -> fun.()
      _other -> Quota.dispatch_status()
    end
  end

  @spec initial_load_envelope_limit(map()) :: pos_integer() | nil
  def initial_load_envelope_limit(%{target_load_average: nil}), do: nil
  def initial_load_envelope_limit(_agent), do: 1

  @doc false
  # Pure dispatch decision for the eager pre-warm gate, kept separate so it can be
  # unit-tested without the orchestrator GenServer.
  @spec prewarm_gate(boolean(), atom() | {:error, term()}) :: :dispatch | :hold
  def prewarm_gate(false, _phase), do: :dispatch
  def prewarm_gate(true, :ready), do: :dispatch
  def prewarm_gate(true, {:error, _reason}), do: :dispatch
  def prewarm_gate(true, _warming), do: :hold

  @doc false
  # Pure CPU load gate (#465), kept separate so it can be unit-tested without the
  # orchestrator GenServer. Holds new dispatch only when the 1-min load average
  # strictly exceeds `threshold` per scheduler; fails open (dispatch) when the
  # gate is disabled (nil/<=0 threshold) or the load is unavailable (non-Linux).
  @spec load_gate(number() | :unavailable, number() | nil, pos_integer()) :: :dispatch | :hold
  def load_gate(_load, nil, _schedulers), do: :dispatch
  def load_gate(_load, threshold, _schedulers) when threshold <= 0, do: :dispatch
  def load_gate(:unavailable, _threshold, _schedulers), do: :dispatch
  def load_gate(load, threshold, schedulers) when load > threshold * schedulers, do: :hold
  def load_gate(_load, _threshold, _schedulers), do: :dispatch

  @doc false
  # A configured floor holds normal new-work dispatch only when the host sample
  # is strictly below it. Missing samples fail open for non-Linux hosts.
  @spec memory_gate(non_neg_integer() | :unavailable, integer() | nil) :: :dispatch | :hold
  def memory_gate(_available_mb, nil), do: :dispatch
  def memory_gate(_available_mb, threshold) when threshold <= 0, do: :dispatch
  def memory_gate(:unavailable, _threshold), do: :dispatch
  def memory_gate(available_mb, threshold) when available_mb < threshold, do: :hold
  def memory_gate(_available_mb, _threshold), do: :dispatch

  @doc false
  @spec fd_gate(SystemFileDescriptors.sample_result()) :: :dispatch | :hold
  def fd_gate(:exhausted), do: :hold
  def fd_gate(:unavailable), do: :dispatch

  def fd_gate(%{available: available, limit: limit} = sample)
      when is_integer(available) and available >= 0 and is_integer(limit) and limit > 0 do
    if available < fd_headroom_threshold(sample), do: :hold, else: :dispatch
  end

  def fd_gate(_sample), do: :dispatch

  @doc false
  @spec fd_headroom_threshold(map()) :: pos_integer() | :unavailable
  def fd_headroom_threshold(%{limit: limit}) when is_integer(limit) and limit > 0 do
    div(limit * @fd_headroom_percent + 99, 100)
  end

  def fd_headroom_threshold(_sample), do: :unavailable

  @doc false
  @spec fd_headroom_percent() :: 10
  def fd_headroom_percent, do: @fd_headroom_percent

  @doc false
  # Instantaneous run-queue gate: holds new dispatch while the number of runnable
  # processes (`procs_running`) strictly exceeds `threshold` per scheduler. This
  # is the fast complement to the 1-minute load average in `load_gate/3`: it
  # reacts to short CPU bursts the lagging load average smooths out. Fails open
  # (dispatch) when the gate is disabled (nil/<=0 threshold) or the sample is
  # unavailable (non-Linux / unreadable /proc/stat).
  @spec run_queue_gate(integer() | :unavailable, pos_integer(), number() | nil) :: :dispatch | :hold
  def run_queue_gate(_runnable, _schedulers, nil), do: :dispatch
  def run_queue_gate(_runnable, _schedulers, threshold) when not is_number(threshold) or threshold <= 0, do: :dispatch
  def run_queue_gate(:unavailable, _schedulers, _threshold), do: :dispatch
  def run_queue_gate(runnable, schedulers, threshold) when runnable > threshold * schedulers, do: :hold
  def run_queue_gate(_runnable, _schedulers, _threshold), do: :dispatch

  @doc false
  # Concurrent-build-pressure gate: holds new dispatch while every agent-launched
  # Mix build slot is busy or a build is queued behind them. This is the
  # "concurrent build pressure" admission signal — it complements the CPU load
  # gate, which sees external build load through the load average. Fails open
  # when the build gate is disabled (`max_concurrent_builds: 0`) or its status
  # is unavailable/degraded.
  @spec build_gate(map()) :: :dispatch | :hold
  def build_gate(%{enabled?: true, capacity: capacity, active: active, queued: queued})
      when is_integer(capacity) and capacity > 0 and is_integer(active) and is_integer(queued) do
    if active >= capacity or queued > 0, do: :hold, else: :dispatch
  end

  def build_gate(_status), do: :dispatch

  @doc false
  # Configured-provider-limit gate: holds new dispatch only when every
  # dispatchable backend reports usage-limited (the fleet-wide provider signal),
  # failing open when no limits are observed or there is nothing dispatchable.
  # Per-issue provider selection (`CodingAgent.select_for_dispatch/1`) still owns
  # the mixed-backend case; this gate only surfaces the fleet-wide saturation.
  @spec provider_gate([String.t()]) :: :dispatch | :hold
  def provider_gate(backends) when is_list(backends) and backends != [] do
    case ModelAvailability.first_available(backends) do
      nil -> :hold
      _backend -> :dispatch
    end
  end

  def provider_gate(_backends), do: :dispatch

  @doc false
  @spec github_quota_gate(:available | {:hold, map()} | term()) :: :dispatch | :hold
  def github_quota_gate({:hold, %{resource: resource}}) when resource in ["core", "graphql"], do: :hold
  def github_quota_gate(_status), do: :dispatch

  @type admission_reason :: %{
          signal: :memory | :file_descriptors | :github_quota | :run_queue | :load | :build | :provider,
          measured: term(),
          threshold: term()
        }

  @doc """
  One authoritative admission decision from every available host-pressure signal.

  Returns `:dispatch` when no gate holds, or `{:hold, reason}` naming the first
  (highest-priority) binding signal with its measured value and threshold. The
  priority order is memory, file descriptors, GitHub quota, run queue, load,
  build, provider.
  Every signal fails open when disabled or unavailable, so an explicit-disable
  config never touches a Linux-specific probe.
  """
  @spec admission_gate(map()) :: :dispatch | {:hold, admission_reason()}
  def admission_gate(%{} = probes) do
    github_quota = Map.get(probes, :github_quota, :available)

    case resource_admission_gate(probes, github_quota) do
      :dispatch -> workload_admission_gate(probes)
      hold -> hold
    end
  end

  defp resource_admission_gate(
         %{memory_mb: memory_mb, memory_threshold_mb: memory_threshold_mb, fd_sample: fd_sample},
         github_quota
       ) do
    cond do
      memory_gate(memory_mb, memory_threshold_mb) == :hold ->
        {:hold, %{signal: :memory, measured: memory_mb, threshold: memory_threshold_mb}}

      fd_gate(fd_sample) == :hold ->
        {:hold, %{signal: :file_descriptors, measured: fd_sample, threshold: fd_headroom_threshold(fd_sample)}}

      github_quota_gate(github_quota) == :hold ->
        {:hold, %{signal: :github_quota, measured: elem(github_quota, 1), threshold: :ten_percent_remaining}}

      true ->
        :dispatch
    end
  end

  defp workload_admission_gate(%{
         runnable: runnable,
         run_queue_threshold: run_queue_threshold,
         schedulers: schedulers,
         load: load,
         load_threshold: load_threshold,
         build_status: build_status,
         provider_backends: provider_backends,
         queued_demand?: queued_demand?
       }) do
    cond do
      run_queue_gate(runnable, schedulers, run_queue_threshold) == :hold ->
        {:hold, %{signal: :run_queue, measured: runnable, threshold: run_queue_threshold * schedulers}}

      load_gate(load, load_threshold, schedulers) == :hold ->
        {:hold, %{signal: :load, measured: load, threshold: load_threshold * schedulers}}

      build_gate(build_status) == :hold ->
        {:hold,
         %{
           signal: :build,
           measured: %{active: Map.get(build_status, :active), queued: Map.get(build_status, :queued)},
           threshold: Map.get(build_status, :capacity)
         }}

      queued_demand? and provider_gate(provider_backends) == :hold ->
        {:hold, %{signal: :provider, measured: provider_backends, threshold: :all_usage_limited}}

      true ->
        :dispatch
    end
  end

  @type envelope_options :: %{
          optional(:bootstrap_complete?) => boolean(),
          target: number() | nil,
          schedulers: pos_integer(),
          static_limit: pos_integer(),
          ramp_step: pos_integer(),
          cooldown_ms: non_neg_integer(),
          now_ms: integer(),
          cpu_headroom: SystemCpu.headroom() | :unavailable,
          queued_work?: boolean(),
          used_slots: non_neg_integer()
        }

  @spec load_envelope(
          integer() | nil,
          integer() | nil,
          number() | :unavailable,
          envelope_options()
        ) ::
          {pos_integer(), integer() | nil}
  def load_envelope(effective, last_decrease_ms, load, options) do
    {next, next_decrease_ms, _bootstrap_complete?} =
      load_envelope_state(
        effective,
        last_decrease_ms,
        load,
        Map.put_new(options, :bootstrap_complete?, true)
      )

    {next, next_decrease_ms}
  end

  defp load_envelope_state(_effective, _last_decrease_ms, _load, %{
         target: nil,
         static_limit: static_limit,
         bootstrap_complete?: bootstrap_complete?
       }),
       do: {static_limit, nil, bootstrap_complete?}

  defp load_envelope_state(effective, last_decrease_ms, :unavailable, options) do
    next = normalize_load_envelope_limit(effective, options.static_limit)
    {next, last_decrease_ms, options.bootstrap_complete?}
  end

  defp load_envelope_state(effective, last_decrease_ms, load, %{static_limit: static_limit} = options)
       when is_number(load) do
    effective = normalize_load_envelope_limit(effective, static_limit)
    adjust_load_envelope(effective, last_decrease_ms, load, options)
  end

  @spec update_load_envelope(
          State.t(),
          number() | :unavailable,
          number() | nil,
          pos_integer(),
          integer(),
          SystemCpu.snapshot() | :unavailable,
          boolean()
        ) :: State.t()
  def update_load_envelope(
        %State{} = state,
        load,
        target,
        schedulers,
        now_ms,
        cpu_snapshot,
        queued_work?
      ) do
    envelope_state = state.load_envelope_state
    cpu_headroom = SystemCpu.headroom(envelope_state.cpu_snapshot, cpu_snapshot)

    {effective, last_decrease_ms, bootstrap_complete?} =
      load_envelope_state(
        state.effective_concurrent_agents,
        envelope_state.last_decrease_ms,
        load,
        %{
          target: target,
          schedulers: schedulers,
          static_limit: Slots.max_concurrent_agent_limit(state),
          ramp_step: Config.load_ramp_step(),
          cooldown_ms: Config.load_cooldown_seconds() * 1_000,
          now_ms: now_ms,
          cpu_headroom: cpu_headroom,
          queued_work?: queued_work?,
          used_slots: Slots.used_slots(state),
          bootstrap_complete?: Map.get(envelope_state, :bootstrap_complete?, false)
        }
      )

    %{
      state
      | effective_concurrent_agents: effective,
        load_envelope_state: %{
          last_decrease_ms: last_decrease_ms,
          cpu_snapshot: next_cpu_snapshot(envelope_state.cpu_snapshot, cpu_snapshot),
          bootstrap_complete?: bootstrap_complete?
        }
    }
  end

  defp adjust_load_envelope(
         effective,
         last_decrease_ms,
         load,
         %{schedulers: schedulers} = options
       ) do
    cond do
      cold_start_seed?(last_decrease_ms, load, schedulers, options) ->
        next =
          seed_cold_start(
            effective,
            options.cpu_headroom,
            schedulers,
            options.used_slots,
            options.static_limit
          )

        {next, last_decrease_ms, true}

      fast_recovery?(last_decrease_ms, schedulers, options) ->
        {next, next_decrease_ms} = fast_ramp(effective, last_decrease_ms, options.static_limit)
        {next, next_decrease_ms, options.bootstrap_complete?}

      true ->
        {next, next_decrease_ms} =
          adjust_load_envelope_without_headroom(effective, last_decrease_ms, load, options)

        {next, next_decrease_ms, options.bootstrap_complete?}
    end
  end

  defp cold_start_seed?(last_decrease_ms, load, schedulers, options) do
    not options.bootstrap_complete? and is_nil(last_decrease_ms) and
      load <= options.target * schedulers and options.queued_work? and
      clear_cpu_headroom?(options.cpu_headroom, schedulers)
  end

  defp fast_recovery?(last_decrease_ms, schedulers, options) do
    is_integer(last_decrease_ms) and options.queued_work? and
      clear_cpu_headroom?(options.cpu_headroom, schedulers)
  end

  defp adjust_load_envelope_without_headroom(
         effective,
         last_decrease_ms,
         load,
         %{target: target, schedulers: schedulers} = options
       )
       when load <= target * schedulers do
    {min(effective + options.ramp_step, options.static_limit), last_decrease_ms}
  end

  defp adjust_load_envelope_without_headroom(effective, last_decrease_ms, _load, options) do
    decrease_load_envelope(effective, last_decrease_ms, options)
  end

  defp decrease_load_envelope(effective, last_decrease_ms, %{
         cooldown_ms: cooldown_ms,
         now_ms: now_ms
       }) do
    if cooldown_elapsed?(last_decrease_ms, cooldown_ms, now_ms) do
      reduced = max(div(effective + 1, 2), 1)
      {reduced, next_decrease_time(effective, reduced, last_decrease_ms, now_ms)}
    else
      {effective, last_decrease_ms}
    end
  end

  defp next_decrease_time(effective, reduced, _last_decrease_ms, now_ms) when reduced < effective,
    do: now_ms

  defp next_decrease_time(_effective, _reduced, last_decrease_ms, _now_ms), do: last_decrease_ms

  defp clear_cpu_headroom?(%{idle_percent: idle_percent, runnable: runnable}, schedulers)
       when idle_percent >= 60.0 and runnable < schedulers,
       do: true

  defp clear_cpu_headroom?(_headroom, _schedulers), do: false

  defp seed_cold_start(effective, %{idle_percent: idle_percent}, schedulers, used_slots, static_limit) do
    idle_slots = max(floor(idle_percent * schedulers / 100), 1)
    max(effective, min(used_slots + idle_slots, static_limit))
  end

  defp fast_ramp(effective, last_decrease_ms, static_limit) do
    next = min(static_limit, min(effective * 2, effective + @cpu_headroom_ramp_max))
    {next, if(next == static_limit, do: nil, else: last_decrease_ms)}
  end

  defp next_cpu_snapshot(_previous, %{total: _total, idle: _idle, runnable: _runnable} = current),
    do: current

  defp next_cpu_snapshot(_previous, _current), do: nil

  defp normalize_load_envelope_limit(effective, static_limit)
       when is_integer(effective) and effective > 0 and is_integer(static_limit) and
              static_limit > 0,
       do: min(effective, static_limit)

  defp normalize_load_envelope_limit(_effective, static_limit), do: static_limit

  defp cooldown_elapsed?(nil, _cooldown_ms, _now_ms), do: true

  defp cooldown_elapsed?(last_decrease_ms, cooldown_ms, now_ms),
    do: now_ms - last_decrease_ms >= cooldown_ms

  @spec sort_issues_for_dispatch([term()]) :: [term()]
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  @spec priority_rank(term()) :: 1..5
  def priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  def priority_rank(_priority), do: 5

  @spec issue_created_at_sort_key(term()) :: integer()
  def issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  def issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  def issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  @spec should_dispatch_issue?(Issue.t(), State.t()) :: boolean()
  def should_dispatch_issue?(%Issue{} = issue, %State{} = state) do
    dispatch_decision(issue, state) == :dispatch
  end

  @spec should_dispatch_issue?(Issue.t(), State.t(), MapSet.t(), MapSet.t()) :: boolean()
  def should_dispatch_issue?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    dispatch_decision(issue, state, active_states, terminal_states) == :dispatch
  end

  def should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  @type dispatch_decline_reason ::
          :invalid_issue
          | :contradictory_state_labels
          | :not_routable
          | :unauthorized
          | :paused
          | :inactive_state
          | :no_agent_work_state
          | :terminal_state
          | :dependency
          | :already_running
          | :retry_backoff
          | :model_fallback_waiting
          | :workspace_ownership_waiting
          | :claimed_without_runtime
          | :state_capacity
          | :worker_capacity
          | :fleet_capacity

  @spec dispatch_decision(term(), State.t()) :: :dispatch | {:skip, dispatch_decline_reason()}
  def dispatch_decision(issue, %State{} = state) do
    dispatch_decision(issue, state, active_state_set(), terminal_state_set())
  end

  @spec dispatch_decision(term(), State.t(), MapSet.t(), MapSet.t()) ::
          :dispatch | {:skip, dispatch_decline_reason()}
  def dispatch_decision(issue, %State{} = state, active_states, terminal_states) do
    case dispatch_candidate_decision(issue, state, active_states, terminal_states) do
      :dispatch -> if(Slots.available_slots(state) > 0, do: :dispatch, else: {:skip, :fleet_capacity})
      {:skip, _reason} = declined -> declined
    end
  end

  # All dispatch preconditions except the global active+paused slot reservation.
  # Polling layers `available_slots > 0` on top of this to honor paused-agent
  # slot holds; manual start paths (e.g., space on a queued ticket) instead
  # gate on `active < max` so the Executor can claim a free slot even when a
  # parallel paused agent is parked in the running map.
  @spec dispatch_candidate?(Issue.t(), State.t()) :: boolean()
  def dispatch_candidate?(%Issue{} = issue, %State{} = state) do
    dispatch_candidate_decision(issue, state, active_state_set(), terminal_state_set()) == :dispatch
  end

  @spec dispatch_candidate?(Issue.t(), State.t(), MapSet.t(), MapSet.t()) :: boolean()
  def dispatch_candidate?(
        %Issue{} = issue,
        %State{} = state,
        active_states,
        terminal_states
      ) do
    dispatch_candidate_decision(issue, state, active_states, terminal_states) == :dispatch
  end

  defp dispatch_candidate_decision(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    case issue_eligibility_decision(issue, active_states, terminal_states) do
      :dispatch -> dispatch_state_decision(issue, state, terminal_states)
      {:skip, _reason} = declined -> declined
    end
  end

  defp dispatch_candidate_decision(_issue, _state, _active_states, _terminal_states), do: {:skip, :invalid_issue}

  defp valid_issue_shape?(%Issue{id: id, identifier: identifier, title: title, state: state}) do
    is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state)
  end

  defp issue_eligibility_decision(%Issue{} = issue, active_states, terminal_states) do
    case issue_identity_decision(issue) do
      :dispatch -> issue_state_decision(issue, active_states, terminal_states)
      {:skip, _reason} = declined -> declined
    end
  end

  defp issue_identity_decision(%Issue{} = issue) do
    cond do
      match?([_, _ | _], issue.state_labels) -> {:skip, :contradictory_state_labels}
      not valid_issue_shape?(issue) -> {:skip, :invalid_issue}
      not issue_routable_to_worker?(issue) -> {:skip, :not_routable}
      not issue_dispatch_authorized?(issue) -> {:skip, :unauthorized}
      not issue_not_paused?(issue) -> {:skip, :paused}
      true -> :dispatch
    end
  end

  defp issue_state_decision(%Issue{} = issue, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) -> {:skip, :terminal_state}
      no_agent_work_state?(issue.state) -> {:skip, :no_agent_work_state}
      not active_issue_state?(issue.state, active_states) -> {:skip, :inactive_state}
      true -> :dispatch
    end
  end

  defp dispatch_state_decision(%Issue{} = issue, %State{} = state, terminal_states) do
    cond do
      todo_issue_blocked_by_non_terminal?(issue, terminal_states) -> {:skip, :dependency}
      Map.has_key?(state.running, issue.id) -> {:skip, :already_running}
      MapSet.member?(state.claimed, issue.id) -> {:skip, claimed_decline_reason(state, issue.id)}
      not state_slots_available?(issue, state) -> {:skip, :state_capacity}
      not Slots.worker_slots_available?(state) -> {:skip, :worker_capacity}
      true -> :dispatch
    end
  end

  defp claimed_decline_reason(%State{} = state, issue_id) do
    cond do
      Map.has_key?(state.retry_attempts, issue_id) -> :retry_backoff
      MapSet.member?(state.model_fallback_waiting, issue_id) -> :model_fallback_waiting
      workspace_ownership_waiting?(state, issue_id) -> :workspace_ownership_waiting
      true -> :claimed_without_runtime
    end
  end

  defp workspace_ownership_waiting?(%State{} = state, issue_id) do
    state.dispatch_recovery.workspace_ownership.waits
    |> Map.values()
    |> Enum.any?(fn
      envelope when is_map(envelope) -> Map.get(envelope, :issue_id) == issue_id
      _other -> false
    end)
  end

  @spec queued_dispatch_demand?([Issue.t()], State.t()) :: boolean()
  def queued_dispatch_demand?(issues, %State{} = state) when is_list(issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    Enum.any?(issues, &dispatch_candidate?(&1, state, active_states, terminal_states))
  end

  @spec state_slots_available?(term(), term()) :: boolean()
  def state_slots_available?(%Issue{state: issue_state}, %State{} = state) do
    limit = effective_state_limit(issue_state, state)
    used = running_issue_count_for_state(state.running, issue_state)
    limit > used
  end

  def state_slots_available?(_issue, _state), do: false

  # Per-state cap honors explicit overrides in
  # `agent.max_concurrent_agents_by_state` first, then falls back to the
  # *session-aware* global limit. Without this, bumping the global cap at
  # runtime (←/→ in the agent list) had no effect on dispatch eligibility
  # because the per-state default was pinned to the workflow file value.
  @spec effective_state_limit(term(), State.t()) :: pos_integer()
  def effective_state_limit(issue_state, %State{} = state) do
    config = Config.settings!()
    normalized = normalize_issue_state(issue_state)

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      normalized,
      Slots.max_concurrent_agent_limit(state)
    )
  end

  @spec running_issue_count_for_state(term(), term()) :: non_neg_integer()
  def running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}} = entry} ->
        normalize_issue_state(state_name) == normalized_state and
          State.active_running_entry?(entry)

      _ ->
        false
    end)
  end

  @spec candidate_issue?(term(), MapSet.t(), MapSet.t()) :: boolean()
  def candidate_issue?(
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
    issue_eligibility_decision(issue, active_states, terminal_states) == :dispatch
  end

  def candidate_issue?(_issue, _active_states, _terminal_states), do: false

  @spec retry_candidate_issue?(Issue.t(), MapSet.t()) :: boolean()
  def retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      not todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  @spec issue_not_paused?(Issue.t()) :: boolean()
  def issue_not_paused?(%Issue{} = issue), do: not Issue.paused?(issue)

  @spec issue_routable_to_worker?(term()) :: boolean()
  def issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
      when is_boolean(assigned_to_worker),
      do: assigned_to_worker

  def issue_routable_to_worker?(_issue), do: true

  @spec issue_dispatch_authorized?(term()) :: boolean()
  def issue_dispatch_authorized?(%Issue{dispatch_authorized?: authorized?})
      when is_boolean(authorized?), do: authorized?

  def issue_dispatch_authorized?(_issue), do: false

  @spec todo_issue_blocked_by_non_terminal?(term(), MapSet.t()) :: boolean()
  def todo_issue_blocked_by_non_terminal?(
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

  def todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @spec terminal_issue_state?(term(), MapSet.t()) :: boolean()
  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @doc """
  True for a state where no agent work exists, so dispatch must be refused.

  See `@no_agent_work_states`. Independent of `active_states`: an operator can
  list `merging` as active (it is, for polling and fence purposes) without making
  it dispatchable.
  """
  @spec no_agent_work_state?(term()) :: boolean()
  def no_agent_work_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) in @no_agent_work_states
  end

  def no_agent_work_state?(_state_name), do: false

  @spec active_issue_state?(term(), MapSet.t()) :: boolean()
  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  # Nil / non-binary state happens when the GitHub poll returns an
  # issue with no `agent:*` label — extract_state returns nil. Treat
  # as 'not active' so the reconcile cond falls through to the
  # catch-all instead of crashing the orchestrator GenServer.
  def active_issue_state?(_state_name, _active_states), do: false

  @spec normalize_issue_state(term()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  # Same nil-safety reasoning as `active_issue_state?/2` above.
  # Direct callers (routable_todo_issues, state_slots_available?,
  # effective_state_limit, running_issue_count_for_state) all feed
  # `issue.state` here without a binary guard; without this clause
  # any unlabeled issue crashes the orchestrator.
  def normalize_issue_state(_state_name), do: ""

  @spec state_slug(term()) :: String.t() | nil
  def state_slug(state_name) when is_binary(state_name) do
    state_name
    |> normalize_issue_state()
    |> String.replace(~r/[\s_]+/, "-")
    |> case do
      "" -> nil
      slug -> slug
    end
  end

  def state_slug(_state_name), do: nil

  @spec terminal_state_set() :: MapSet.t()
  def terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec active_state_set() :: MapSet.t()
  def active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end
end
