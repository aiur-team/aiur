defmodule Aiur.Orchestrator.Dispatcher.CapacityConstraints do
  @moduledoc """
  Capacity sampling: records which constraint bound each admission decision.
  """

  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusObservation

  # Records every currently-failing host-pressure gate so `status` can explain a
  # non-dispatching fleet and IssueSync can age each gate independently.
  @doc false
  @spec record_capacity_constraints(State.t(), map()) :: State.t()
  def record_capacity_constraints(%State{} = state, probes) do
    state
    |> maybe_record_memory_constraint(
      DispatchPolicy.memory_gate(probes.memory_mb, probes.memory_threshold_mb),
      probes.memory_mb,
      probes.memory_threshold_mb
    )
    |> maybe_record_fd_constraint(DispatchPolicy.fd_gate(probes.fd_sample), probes.fd_sample)
    |> maybe_record_load_constraint(
      DispatchPolicy.load_admission_reason(
        probes.load,
        probes.load_threshold,
        probes.schedulers,
        Map.get(probes, :cpu_headroom, :unavailable)
      ),
      probes
    )
    |> maybe_record_run_queue_constraint(
      DispatchPolicy.run_queue_admission_reason(
        probes.runnable,
        probes.schedulers,
        probes.run_queue_threshold,
        Map.get(probes, :cpu_headroom, :unavailable)
      ),
      probes
    )
    |> maybe_record_build_constraint(
      DispatchPolicy.build_gate(probes.build_status),
      probes.build_status
    )
    |> maybe_record_provider_constraint(
      DispatchPolicy.provider_gate(probes.provider_backends, Map.get(probes, :provider_gate_opts, [])),
      probes.provider_backends
    )
    |> maybe_record_github_quota_constraint(Map.get(probes, :github_quota, :available))
  end

  @doc false
  @spec record_capacity_sample(State.t(), map()) :: State.t()
  def record_capacity_sample(%State{} = state, probes) do
    %{
      state
      | dispatch_capacity_sample: %{
          load: probes.load,
          load_discount_reason: Aiur.SystemLoad.discount_reason(Map.get(probes, :cpu_headroom, :unavailable)),
          load_daemon_nice: Aiur.SystemLoad.daemon_nice(Map.get(probes, :cpu_headroom, :unavailable)),
          gate_signal: Aiur.SystemLoad.gate_signal(probes.load, Map.get(probes, :cpu_headroom, :unavailable), probes.schedulers),
          load_sampled_at_ms: Map.get(probes, :sampled_at_ms),
          load_threshold: probes.load_threshold,
          target: probes.target,
          schedulers: probes.schedulers,
          observed_at: StatusObservation.sample_observed_at(probes)
        }
    }
  end

  defp maybe_record_run_queue_constraint(state, {:hold, reason}, probes) do
    record_capacity_constraint(
      state,
      :run_queue,
      "runnable=#{inspect(probes.runnable)} threshold=#{inspect(probes.run_queue_threshold)} " <>
        "schedulers=#{probes.schedulers} " <>
        "reclaimable_cpu_percent=#{inspect(Map.get(reason, :reclaimable_cpu_percent))}"
    )
  end

  defp maybe_record_run_queue_constraint(state, _gate, _probes), do: state

  defp maybe_record_build_constraint(state, :hold, status),
    do: record_capacity_constraint(state, :build_queue, "build=#{inspect(status)}")

  defp maybe_record_build_constraint(state, _gate, _status), do: state

  defp maybe_record_provider_constraint(state, :hold, backends),
    do: record_capacity_constraint(state, :provider, ModelAvailability.provider_freshness_detail(backends))

  defp maybe_record_provider_constraint(state, _gate, _backends), do: state

  defp maybe_record_github_quota_constraint(state, {:hold, quota}) do
    record_capacity_constraint(
      state,
      :github_quota,
      "resource=#{quota.resource} remaining=#{quota.remaining} limit=#{quota.limit} reset_at=#{DateTime.to_iso8601(quota.reset_at)}"
    )
  end

  defp maybe_record_github_quota_constraint(state, _status), do: state

  @doc false
  @spec record_fallback_binding_constraint(State.t(), term()) :: State.t()
  def record_fallback_binding_constraint(%State{dispatch_capacity_constraints: []} = state, %{signal: signal} = reason)
      when is_atom(signal) do
    record_capacity_constraint(
      state,
      binding_constraint_kind(signal),
      "measured=#{inspect(Map.get(reason, :measured))} threshold=#{inspect(Map.get(reason, :threshold))}"
    )
  end

  def record_fallback_binding_constraint(%State{} = state, _reason), do: state

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

  defp maybe_record_load_constraint(state, {:hold, reason}, probes) do
    record_capacity_constraint(
      state,
      :load,
      "load=#{inspect(probes.load)} threshold=#{probes.load_threshold} schedulers=#{probes.schedulers} " <>
        "reclaimable_cpu_percent=#{inspect(Map.get(reason, :reclaimable_cpu_percent))}"
    )
  end

  defp maybe_record_load_constraint(state, _gate, _probes), do: state

  # Records the load envelope as a capacity constraint only when it is a genuine
  # hold: load above target with effective capacity backed off below the ceiling.
  # The below-target ramp — the envelope deliberately starting small on daemon
  # start and widening per below-target sample — is the intended ramp, not
  # starvation, so it must never surface a `:load_envelope` constraint that the
  # capacity-starvation alerts would report (#2447).
  @doc false
  @spec maybe_record_load_envelope_constraint(State.t(), term(), term(), term()) :: State.t()
  def maybe_record_load_envelope_constraint(%State{} = state, load, target, schedulers) do
    configured = Slots.max_concurrent_agent_limit(state)
    effective = Slots.effective_concurrent_agent_limit(state)

    if effective < configured and load_above_target?(load, target, schedulers) do
      record_capacity_constraint(state, :load_envelope, "effective_cap=#{effective} configured_cap=#{configured}")
    else
      state
    end
  end

  defp load_above_target?(_load, target, _schedulers) when not is_number(target), do: false

  defp load_above_target?(load, target, schedulers)
       when is_number(load) and is_number(target) and target > 0 and is_integer(schedulers) and schedulers > 0 do
    load > target * schedulers
  end

  defp load_above_target?(_load, _target, _schedulers), do: false

  @doc false
  @spec record_capacity_constraint(State.t(), atom(), String.t()) :: State.t()
  def record_capacity_constraint(%State{} = state, kind, detail) when is_atom(kind) and is_binary(detail) do
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
end
