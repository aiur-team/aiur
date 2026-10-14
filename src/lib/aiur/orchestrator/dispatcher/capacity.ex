defmodule Aiur.Orchestrator.Dispatcher.Capacity do
  @moduledoc """
  Load admission: probes, the load envelope and the capacity hold.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.Dispatcher.CapacityConstraints
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.EnvelopeResume
  alias Aiur.Orchestrator.PressureAdmission
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.RunTelemetry
  alias Aiur.SystemCpu

  @capacity_backoff_alert_ms 30_000
  # Sample under a prewarm hold: flickering ready/:building across ticks drops
  # `load`/`memory`/`fd` from the constraint set, and IssueSync restarts the age
  # of a persistent gate. Probe only when ready work exists,
  # since that is the sole condition the starvation alert reports on.
  @doc false
  @spec maybe_sample_host_pressure_under_prewarm_hold(State.t(), [Issue.t()], (-> map()), keyword()) :: State.t()
  def maybe_sample_host_pressure_under_prewarm_hold(%State{} = state, [], _admission_probes_fun, _opts), do: state

  def maybe_sample_host_pressure_under_prewarm_hold(%State{} = state, issues, admission_probes_fun, opts)
      when is_list(issues) and is_function(admission_probes_fun, 0) do
    probes = admission_probes_fun.() |> put_cpu_headroom(state)
    queued_demand? = DispatchPolicy.queued_dispatch_demand?(issues, state)
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

    state
    |> remember_cpu_snapshot(probes)
    |> CapacityConstraints.record_capacity_sample(probes)
    |> CapacityConstraints.record_capacity_constraints(probes)
    # The prewarm branch is a dispatch path too: it just decided the hold for a
    # different reason. Reconciling `capacity_hold` against this tick's own
    # probes is what keeps the reported binding honest while prewarm holds —
    # otherwise the last host-pressure measurement taken before the base build
    # started stays latched for the build's whole duration, and `status` reports
    # a minutes-old `load=` beside a current `LOAD` line four times smaller
    # (#2527).
    |> reconcile_capacity_hold(
      DispatchPolicy.admission_gate(Map.put(probes, :queued_demand?, queued_demand?)),
      now_ms,
      opts
    )
  end

  # CPU load admission applies to NEW work only. Retries and reactivations bypass
  # this function so a capacity wait never burns their retry budget.
  @spec maybe_choose_under_load(State.t(), [Issue.t()]) :: State.t()
  def maybe_choose_under_load(%State{} = state, issues) when is_list(issues) do
    maybe_choose_under_load(state, issues, &Dispatcher.maybe_choose/2, [])
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
    admission_probes_fun = Keyword.get(opts, :admission_probes_fun, &admission_probes/0)
    probes = admission_probes_fun.() |> put_cpu_headroom(state)
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
    sampled_at_ms = Map.get(probes, :sampled_at_ms, now_ms)
    sample_id = Map.get(probes, :sample_id, sampled_at_ms)
    fresh? = fresh_load_sample?(state, sampled_at_ms, sample_id, now_ms)
    previous_signal = Map.get(state.load_envelope_state, :signal)
    overload_samples = Map.get(state.load_envelope_state, :overload_samples, 0)
    consumed_sample_id = if fresh?, do: sample_id, else: Map.get(state.load_envelope_state, :sample_id)
    consumed_at_ms = if fresh?, do: sampled_at_ms, else: Map.get(state.load_envelope_state, :sampled_at_ms)
    queued_demand? = DispatchPolicy.queued_dispatch_demand?(issues, state)
    {envelope_value, envelope_target, envelope_schedulers} = PressureAdmission.envelope_signal(probes)

    state =
      PressureAdmission.update(state, probes, now_ms, queued_demand?, fresh?)
      |> CapacityConstraints.maybe_record_load_envelope_constraint(envelope_value, envelope_target, envelope_schedulers)

    # Reusing a sample neither confirms nor interrupts sustained overload.
    state = if fresh? or previous_signal != state.load_envelope_state[:signal], do: state, else: put_in(state.load_envelope_state[:overload_samples], overload_samples)
    state = put_in(state.load_envelope_state[:sampled_at_ms], consumed_at_ms)
    state = put_in(state.load_envelope_state[:sample_id], consumed_sample_id)
    state = CapacityConstraints.record_capacity_constraints(state, probes)
    state = CapacityConstraints.record_capacity_sample(state, probes)
    state = EnvelopeResume.persist(state, fresh?, probes.schedulers, now_ms)

    case DispatchPolicy.admission_gate(Map.put(probes, :queued_demand?, queued_demand?)) do
      {:hold, reason} ->
        # Every admission signal is sampled independently above, so the binding
        # signal is normally already recorded and re-recording it would add a
        # duplicate identity. Fall back to it only when nothing was sampled, so
        # a held fleet always carries at least one constraint and
        # `capacity_starved` can never read an empty list and silently clear.
        state
        |> CapacityConstraints.record_fallback_binding_constraint(reason)
        |> reconcile_capacity_hold({:hold, reason}, now_ms, opts)

      :dispatch ->
        state =
          reconcile_capacity_hold(
            state,
            envelope_hold(state, envelope_value, envelope_target, envelope_schedulers, queued_demand?),
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
  @doc false
  @spec admission_probes() :: map()
  def admission_probes do
    memory_threshold_mb = Config.min_free_memory_mb()
    sample = Aiur.SystemLoad.sample(&PressureAdmission.sample/0)

    Map.merge(sample, %{
      memory_mb: DispatchPolicy.read_memory(memory_threshold_mb),
      memory_threshold_mb: memory_threshold_mb,
      fd_sample: DispatchPolicy.read_file_descriptors(),
      runnable: runnable_from(sample.cpu_snapshot),
      run_queue_threshold: Map.get(sample, :run_queue_threshold, Config.run_queue_threshold()),
      schedulers: System.schedulers_online(),
      load_threshold: Map.get(sample, :load_threshold, Config.max_load_average()),
      target: Map.get(sample, :target, Config.target_load_average()),
      provider_backends: DispatchPolicy.read_provider_backends(),
      github_quota: DispatchPolicy.read_github_quota()
    })
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
        probes = admission_probes() |> put_cpu_headroom(state)

        case DispatchPolicy.admission_gate(Map.put(probes, :queued_demand?, true)) do
          :dispatch -> :dispatch
          {:hold, reason} -> {:hold, reason.signal}
        end
    end
  end

  defp prewarm_hold? do
    enabled? = Config.prewarm_enabled?()
    phase = if enabled?, do: Dispatcher.trigger_and_status(), else: :ready
    DispatchPolicy.prewarm_gate(enabled?, phase) == :hold
  end

  defp fresh_load_sample?(state, sampled_at_ms, sample_id, now_ms) do
    is_integer(sampled_at_ms) and now_ms >= sampled_at_ms and
      now_ms - sampled_at_ms <= (state.poll_interval_ms || Aiur.PollCadence.base_interval_ms(class: :dispatch)) and
      sample_id != Map.get(state.load_envelope_state, :sample_id)
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

  defp put_cpu_headroom(probes, %State{} = state) do
    previous = state.load_envelope_state.cpu_snapshot
    Map.put(probes, :cpu_headroom, SystemCpu.headroom(previous, Map.get(probes, :cpu_snapshot, :unavailable)))
  end

  defp remember_cpu_snapshot(%State{} = state, %{cpu_snapshot: %{total: _, idle: _, runnable: _} = snapshot}) do
    put_in(state.load_envelope_state.cpu_snapshot, snapshot)
  end

  defp remember_cpu_snapshot(%State{} = state, _probes), do: state

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
    measured_at = Keyword.get(opts, :utc_now_fun, &DateTime.utc_now/0).()
    signal = Map.fetch!(reason, :signal)

    case state.capacity_hold do
      %{signal: ^signal, alerted?: true} = hold ->
        %{state | capacity_hold: merge_capacity_reason(hold, reason, measured_at)}

      %{signal: ^signal, alerted?: false} = hold ->
        hold = merge_capacity_reason(hold, reason, measured_at)

        if now_ms - hold.held_since_ms < debounce_ms do
          %{state | capacity_hold: hold}
        else
          emit_fun.("system.fleet.capacity.backoff", reason)
          %{state | capacity_hold: Map.put(hold, :alerted?, true)}
        end

      _other ->
        telemetry_fun.(:capacity_hold, Aiur.JSONSafe.normalize(reason))

        %{
          state
          | capacity_hold: Map.merge(reason, %{held_since_ms: now_ms, alerted?: false, measured_at: measured_at})
        }
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

  defp capacity_reason_measurements(reason) do
    Map.take(reason, [
      :measured,
      :detail,
      :threshold,
      :reclaimable_cpu_percent,
      :reclaimable_cpu_threshold
    ])
  end

  defp merge_capacity_reason(hold, reason, measured_at) do
    hold
    |> Map.drop([:reclaimable_cpu_percent, :reclaimable_cpu_threshold])
    |> Map.merge(capacity_reason_measurements(reason))
    |> Map.put(:measured_at, measured_at)
  end

  defp log_admission_hold(%{signal: :memory, measured: available_mb, threshold: threshold_mb}) do
    Logger.info(
      "aiur_perf memory_hold surface=dispatch available_mb=#{available_mb} " <>
        "threshold_mb=#{threshold_mb}"
    )
  end

  defp log_admission_hold(%{signal: :file_descriptors, measured: sample}) do
    log_fd_hold(sample)
  end

  defp log_admission_hold(%{signal: :load, measured: load, threshold: limit} = reason) do
    Logger.info(
      "aiur_perf load_hold load=#{load} limit=#{limit} " <>
        "reclaimable_cpu_percent=#{inspect(Map.get(reason, :reclaimable_cpu_percent))} " <>
        "reclaimable_cpu_threshold=#{inspect(Map.get(reason, :reclaimable_cpu_threshold))}"
    )
  end

  defp log_admission_hold(%{signal: :run_queue, measured: runnable, threshold: limit} = reason) do
    Logger.info(
      "aiur_perf run_queue_hold runnable=#{runnable} limit=#{limit} " <>
        "reclaimable_cpu_percent=#{inspect(Map.get(reason, :reclaimable_cpu_percent))} " <>
        "reclaimable_cpu_threshold=#{inspect(Map.get(reason, :reclaimable_cpu_threshold))}"
    )
  end

  defp log_admission_hold(%{signal: :cpu_pressure, measured: pressure, threshold: threshold}),
    do: Logger.info("aiur_perf cpu_pressure_hold avg60=#{pressure} threshold=#{threshold}")

  defp log_admission_hold(%{signal: :envelope, measured: effective, threshold: static}) do
    Logger.info("aiur_perf envelope_hold effective=#{effective} static=#{static}")
  end

  defp log_admission_hold(%{signal: :provider, measured: backends, threshold: _}) do
    Logger.info("aiur_perf provider_hold surface=dispatch backends=#{inspect(backends)} status=all_usage_limited")
  end

  defp log_admission_hold(%{signal: :github_quota, measured: quota, threshold: _}) do
    Logger.info(
      "aiur_perf github_quota_hold surface=dispatch resource=#{quota.resource} " <>
        "remaining=#{quota.remaining} limit=#{quota.limit} reset_at=#{DateTime.to_iso8601(quota.reset_at)}"
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
end
