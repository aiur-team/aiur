defmodule Aiur.Orchestrator.DispatchPolicy.Gates do
  @moduledoc """
  Host-pressure probes and the admission gates they feed. Public API stays on `Aiur.Orchestrator.DispatchPolicy`.
  """

  alias Aiur.{BuildGate, CodingAgent, Config, ModelAvailability, SystemCpu, SystemFileDescriptors, SystemLoad, SystemMemory}
  alias Aiur.GitHub.Quota
  @reclaimable_cpu_threshold 60.0
  @fd_headroom_percent 10

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
  # Reads the host CPU snapshot when load admission, the adaptive envelope, or
  # the run-queue gate is enabled, so explicit-disable configs never touch
  # /proc/stat.
  @spec read_cpu(number() | nil, number() | nil) :: SystemCpu.snapshot() | :unavailable
  def read_cpu(target, run_queue_threshold \\ nil), do: read_cpu(target, run_queue_threshold, nil)

  @spec read_cpu(number() | nil, number() | nil, number() | nil) :: SystemCpu.snapshot() | :unavailable
  def read_cpu(target, run_queue_threshold, hard_threshold)
      when (is_number(target) and target > 0) or
             (is_number(run_queue_threshold) and run_queue_threshold > 0) or
             (is_number(hard_threshold) and hard_threshold > 0),
      do: SystemCpu.snapshot()

  def read_cpu(_target, _run_queue_threshold, _hard_threshold), do: :unavailable

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

  @doc false
  # Pure eager pre-warm decision.
  @spec prewarm_gate(boolean(), atom() | {:error, term()}) :: :dispatch | :hold
  def prewarm_gate(false, _phase), do: :dispatch
  def prewarm_gate(true, :ready), do: :dispatch
  def prewarm_gate(true, {:error, _reason}), do: :dispatch
  def prewarm_gate(true, _warming), do: :hold

  @doc false
  # The authoritative admission reason additionally corroborates an
  # exceeded threshold with short-window CPU headroom so low-priority runnable
  # processes cannot hold the fleet by themselves.
  @spec load_gate(number() | :unavailable, number() | nil, pos_integer()) :: :dispatch | :hold
  def load_gate(_load, nil, _schedulers), do: :dispatch
  def load_gate(_load, threshold, _schedulers) when threshold <= 0, do: :dispatch
  def load_gate(:unavailable, _threshold, _schedulers), do: :dispatch
  def load_gate(load, threshold, schedulers) when load > threshold * schedulers, do: :hold
  def load_gate(_load, _threshold, _schedulers), do: :dispatch

  @doc false
  # `cpu_headroom` is required rather than defaulted: an uncorroborated caller
  # can never produce a hold, so a defaulted arity would silently read as "the
  # load gate is off" (#2089).
  @spec load_admission_reason(
          number() | :unavailable,
          number() | nil,
          pos_integer(),
          SystemCpu.headroom() | :unavailable
        ) :: :dispatch | {:hold, admission_reason()}
  def load_admission_reason(load, threshold, schedulers, cpu_headroom) do
    load
    |> SystemLoad.gate_signal(cpu_headroom, schedulers)
    |> load_gate(threshold, schedulers)
    |> corroborated_admission_reason(:load, load, scaled_threshold(threshold, schedulers), cpu_headroom)
  end

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
  # Instantaneous run-queue check; admission corroborates it with CPU headroom.
  @spec run_queue_gate(number() | :unavailable, pos_integer(), number() | nil) :: :dispatch | :hold
  def run_queue_gate(_runnable, _schedulers, nil), do: :dispatch
  def run_queue_gate(_runnable, _schedulers, threshold) when not is_number(threshold) or threshold <= 0, do: :dispatch
  def run_queue_gate(:unavailable, _schedulers, _threshold), do: :dispatch
  def run_queue_gate(runnable, schedulers, threshold) when runnable > threshold * schedulers, do: :hold
  def run_queue_gate(_runnable, _schedulers, _threshold), do: :dispatch

  @doc false
  @spec run_queue_admission_reason(
          integer() | :unavailable,
          pos_integer(),
          number() | nil,
          SystemCpu.headroom() | :unavailable
        ) :: :dispatch | {:hold, admission_reason()}
  def run_queue_admission_reason(runnable, schedulers, threshold, cpu_headroom) do
    runnable
    |> SystemLoad.gate_signal(cpu_headroom, schedulers)
    |> run_queue_gate(schedulers, threshold)
    |> corroborated_admission_reason(:run_queue, runnable, scaled_threshold(threshold, schedulers), cpu_headroom)
  end

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
  # As a side effect, when we would hold due to all backends being limited,
  # trigger probes for any stale limits to refresh the cached readings.
  @spec provider_gate([String.t()], keyword()) :: :dispatch | :hold
  def provider_gate(backends, opts \\ [])

  def provider_gate(backends, opts) when is_list(backends) and backends != [] do
    case ModelAvailability.first_available(backends, opts) do
      nil ->
        # All backends are limited; trigger probes for any stale limits
        # This is a non-blocking side effect that happens in the background
        ModelAvailability.probe_stale_limits(backends, opts)
        :hold

      _backend ->
        :dispatch
    end
  end

  def provider_gate(_backends, _opts), do: :dispatch

  @doc false
  @spec github_quota_gate(:available | {:hold, map()} | term()) :: :dispatch | :hold
  def github_quota_gate({:hold, %{resource: resource}}) when resource in ["core", "graphql"], do: :hold
  def github_quota_gate(_status), do: :dispatch

  # The corroboration keys are optional but no longer incidental: a `load` or
  # `run_queue` hold cannot be produced without them (#2089), so the type has to
  # admit them or dialyzer intersects the inferred 5-key hold with a closed
  # 3-key spec, finds nothing, and declares every load/run-queue hold dead.
  @type admission_reason :: %{
          :signal => :memory | :file_descriptors | :github_quota | :run_queue | :load | :build | :provider,
          :measured => term(),
          :threshold => term(),
          optional(:reclaimable_cpu_percent) => number(),
          optional(:reclaimable_cpu_threshold) => number()
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

  defp workload_admission_gate(
         %{
           runnable: runnable,
           run_queue_threshold: run_queue_threshold,
           schedulers: schedulers,
           load: load,
           load_threshold: load_threshold,
           build_status: build_status,
           provider_backends: provider_backends,
           queued_demand?: queued_demand?
         } = probes
       ) do
    cpu_headroom = Map.get(probes, :cpu_headroom, :unavailable)
    run_queue_hold = run_queue_admission_reason(runnable, schedulers, run_queue_threshold, cpu_headroom)
    load_hold = load_admission_reason(load, load_threshold, schedulers, cpu_headroom)

    cond do
      run_queue_hold != :dispatch ->
        run_queue_hold

      load_hold != :dispatch ->
        load_hold

      build_gate(build_status) == :hold ->
        {:hold,
         %{
           signal: :build,
           measured: %{active: Map.get(build_status, :active), queued: Map.get(build_status, :queued)},
           threshold: Map.get(build_status, :capacity)
         }}

      queued_demand? and provider_gate(provider_backends, Map.get(probes, :provider_gate_opts, [])) == :hold ->
        provider_opts = Map.get(probes, :provider_gate_opts, [])

        {:hold,
         %{
           signal: :provider,
           measured: provider_backends,
           detail: ModelAvailability.provider_freshness_detail(provider_backends, provider_opts),
           threshold: :all_usage_limited
         }}

      true ->
        :dispatch
    end
  end

  defp reclaimable_cpu_percent(%{reclaimable_percent: percent}) when is_number(percent), do: percent
  defp reclaimable_cpu_percent(%{idle_percent: percent}) when is_number(percent), do: percent
  defp reclaimable_cpu_percent(_headroom), do: :unavailable

  defp corroborated_admission_reason(:dispatch, _signal, _measured, _threshold, _cpu_headroom),
    do: :dispatch

  defp corroborated_admission_reason(:hold, signal, measured, threshold, cpu_headroom) do
    case reclaimable_cpu_percent(cpu_headroom) do
      reclaimable when is_number(reclaimable) and reclaimable >= @reclaimable_cpu_threshold ->
        :dispatch

      reclaimable when is_number(reclaimable) ->
        {:hold,
         %{
           signal: signal,
           measured: measured,
           threshold: threshold,
           reclaimable_cpu_percent: reclaimable,
           reclaimable_cpu_threshold: @reclaimable_cpu_threshold
         }}

      # An unmeasured corroboration is not a measurement of contention (#2089).
      # `SystemCpu.headroom/2` needs two `/proc/stat` reads, so the first
      # admission decision of a `State`'s life — the ramp-from-zero decision —
      # has no window to compare against and returns `:unavailable`. Holding on
      # that used to reinstate exactly the false positive this corroboration was
      # added to remove (#1610): the raw 1-minute load average, which this fleet
      # routinely inflates with niced `mix` builds and I/O wait, withheld new
      # dispatch with no CPU evidence behind it. Every neighbouring probe
      # (`SystemLoad`, `SystemCpu`, `memory_gate/2`, `build_gate/1`) degrades
      # open when its sample is missing; this one now agrees. A hold therefore
      # always carries a measured `reclaimable_cpu_percent`, and the next poll
      # cycle — which does have a window — is what holds a genuinely saturated
      # host.
      :unavailable ->
        :dispatch
    end
  end

  defp scaled_threshold(threshold, schedulers) when is_number(threshold),
    do: threshold * schedulers

  defp scaled_threshold(_threshold, _schedulers), do: nil
end
