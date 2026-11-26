defmodule Aiur.Orchestrator.ResourceReadings do
  @moduledoc false

  alias Aiur.{BuildGate, Config, SystemCgroup, SystemLoad, SystemMemory, SystemPressure}
  alias Aiur.Capacity.View
  alias Aiur.Orchestrator.ResourceEnvelope

  @memory_psi_threshold 1.0
  @available_memory_floor_mb 1_024
  @provider_headroom_floor 0.10

  @spec sample(map(), keyword()) :: map()
  def sample(agent, opts \\ []) do
    sampled_at = System.monotonic_time(:millisecond)
    cpu_target = agent.target_cpu_pressure || 10.0
    memory_floor = agent.min_free_memory_mb || @available_memory_floor_mb
    cgroup_threshold = agent.cgroup_memory_threshold || 0.8
    host = Keyword.get_lazy(opts, :host, fn -> host_readings(cpu_target, cgroup_threshold) end)
    build_status = Keyword.get(opts, :build_status, &BuildGate.status/0)
    provider_energy = Keyword.get(opts, :provider_energy, &provider_energy/0)

    readings = [
      reading(:cpu_psi, upper(avg10(host.cpu), cpu_target), sampled_at),
      reading(:memory_psi, upper(avg10(host.memory), @memory_psi_threshold), sampled_at),
      reading(:available_memory, lower(host.available_mb, memory_floor), sampled_at),
      reading(:cgroup_headroom, host.cgroup, sampled_at),
      external_reading(:build_gate, fn -> build_reading(build_status.()) end),
      external_reading(:provider_budget, fn -> provider_reading(provider_energy.()) end)
    ]

    %{resource_readings: readings, resource_sampled_at_ms: sampled_at}
  end

  defp host_readings(cpu_target, cgroup_threshold) do
    %{
      cpu: SystemPressure.cpu(),
      memory: SystemPressure.memory(),
      available_mb: SystemMemory.available_mb(),
      cgroup: SystemCgroup.dispatch_headroom(cpu_target, cgroup_threshold)
    }
  end

  # A timeout from one source must never erase known pressure from another.
  defp external_reading(signal, fun) do
    case SystemLoad.sample(fn -> %{reading: fun.()} end) do
      %{reading: reading} -> reading
      _unavailable -> reading(signal, :unknown, nil)
    end
  end

  defp build_reading(status), do: reading(:build_gate, build_condition(status), System.monotonic_time(:millisecond))

  defp build_condition(%{degraded?: true}), do: :unknown
  defp build_condition(%{enabled?: false}), do: :healthy

  defp build_condition(%{active: active, capacity: capacity}) when is_integer(active) and is_integer(capacity) and capacity > 0 and active >= capacity,
    do: :pressure

  defp build_condition(%{active: active}) when is_integer(active) and active > 0, do: :busy
  defp build_condition(%{active: 0}), do: :healthy
  defp build_condition(_status), do: :unknown

  defp provider_energy do
    routed = Config.agent_routing_candidates() |> Map.values() |> List.flatten()
    primary = if Config.agent_priority() == [], do: [Config.agent_kind()], else: []
    routes = Enum.uniq(primary ++ Config.switch_model_on_ratelimit() ++ routed)
    View.build(routes: Enum.filter(routes, &is_binary/1)).energy
  end

  defp provider_reading(%{freshness: "fresh", level: level, age_ms: age}) when is_number(level) and is_integer(age) do
    reading(:provider_budget, lower(level, @provider_headroom_floor), System.monotonic_time(:millisecond) - age)
  end

  defp provider_reading(_energy), do: reading(:provider_budget, :unknown, nil)

  defp avg10(%{avg10: value}), do: value
  defp avg10(_sample), do: :unavailable

  defp upper(value, threshold) when is_number(value), do: if(value > threshold, do: :pressure, else: :healthy)
  defp upper(_value, _threshold), do: :unknown

  defp lower(value, threshold) when is_number(value), do: if(value < threshold, do: :pressure, else: :healthy)
  defp lower(_value, _threshold), do: :unknown

  defp reading(signal, :unknown, _stamp), do: ResourceEnvelope.binding(signal, :unknown, nil)
  defp reading(signal, condition, stamp), do: ResourceEnvelope.binding(signal, condition, stamp)
end
