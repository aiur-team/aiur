defmodule Aiur.Orchestrator.ResourceDispatchTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO
  import Phoenix.LiveViewTest

  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher.Capacity
  alias Aiur.Orchestrator.{ResourceEnvelope, ResourceReadings, Slots, State, StatusCLI}
  alias AiurWeb.OperatorControlCenter.Analytics.RuntimeCaps
  alias AiurWeb.OperatorControlCenter.Overview
  alias AiurWeb.Presenter.Entries

  test "dispatch applies resource backoff without a priority bypass and reports the same binding across surfaces" do
    now = System.monotonic_time(:millisecond)
    state = ResourceEnvelope.configure(%State{max_concurrent_agents: 8, session_max_concurrent_agents: 10}, %{resource_concurrency: true})
    assert Slots.effective_concurrent_agent_limit(state) == 1
    state = %{state | effective_concurrent_agents: 8}
    issue = %Issue{id: "priority", identifier: "repo#1", title: "Urgent", priority: 1, state: "todo"}

    probes = %{
      cpu_pressure: %{avg10: 40.0, avg60: 30.0},
      pressure_target: 10.0,
      pressure_threshold: 20.0,
      load: 0.2,
      load_threshold: nil,
      target: nil,
      schedulers: 4,
      fd_sample: :unavailable,
      memory_mb: :unavailable,
      memory_threshold_mb: nil,
      provider_backends: [],
      resource_sampled_at_ms: now,
      resource_readings: [ResourceEnvelope.binding(:cpu_psi, :pressure, now - 12_000)]
    }

    result =
      Capacity.maybe_choose_under_load(state, [issue], fn _state, _issues -> flunk("priority bypassed the resource ceiling") end,
        admission_probes_fun: fn -> probes end,
        now_ms: now
      )

    assert %{effective: 4, max: 8, resource_binding: %{signal: :cpu_psi, observed_at_ms: observed_at}} = capacity = Slots.max_concurrent_agent_status(result)
    assert observed_at == now - 12_000

    lowered = ResourceEnvelope.enforce_limit(%{result | session_max_concurrent_agents: 2})
    assert Slots.effective_concurrent_agent_limit(%{lowered | session_max_concurrent_agents: 10}) == 2

    snapshot = %{capacity: capacity, running: []}

    assert capture_io(fn -> StatusCLI.Capacity.print_capacity_status(capacity, %{}) end) =~ "DISPATCH CEILING 4 binding=cpu_psi (pressure, sample age "
    assert capture_io(fn -> StatusCLI.agents(fleet_view: {:ok, snapshot, %{state: :current}}) end) =~ "DISPATCH CEILING 4 binding=cpu_psi (pressure, sample age "

    html = render_component(&Overview.dispatch_ceiling/1, capacity: Entries.capacity_payload(capacity))
    assert html =~ "<strong>Dispatch ceiling 4</strong>"
    assert html =~ "cpu_psi (pressure, sample age "

    opts = RuntimeCaps.runtime_opts(dashboard_snapshot_fun: fn _, _ -> {:current, snapshot, %{}} end)
    assert RuntimeCaps.cap_label(Map.new(opts)) =~ ~r/^4 cap \(binding: cpu_psi \(pressure, sample age \d+s ago\)/
  end

  test "healthy samples at the widened tracker cadence still ramp one slot" do
    now = System.monotonic_time(:millisecond)
    config = %{resource_concurrency: true}
    initial = ResourceEnvelope.configure(%State{max_concurrent_agents: 6, poll_interval_ms: 10_000, effective_poll_interval_ms: 60_000}, config)

    samples =
      Enum.scan([now, now + 60_001], initial, fn stamp, state ->
        probe = %{resource_sampled_at_ms: stamp, resource_readings: [ResourceEnvelope.binding(:cpu_psi, :healthy, stamp)]}
        ResourceEnvelope.update(state, probe, true, stamp)
      end)

    assert Enum.map(samples, &Slots.effective_concurrent_agent_limit/1) == [1, 2]
  end

  test "raw host readings use avg10 and build saturation survives an unavailable provider" do
    agent = %{target_cpu_pressure: 10.0, min_free_memory_mb: 2048, cgroup_memory_threshold: 0.8}
    host = %{cpu: %{avg10: 11.0, avg60: 1.0}, memory: %{avg10: 0.1, avg60: 9.0}, available_mb: 1024, cgroup: :healthy}
    build = fn -> %{active: 2, capacity: 2} end
    unavailable = fn -> exit(:shutdown) end

    assert %{resource_readings: readings} = ResourceReadings.sample(agent, host: host, build_status: build, provider_energy: unavailable)

    assert Map.new(readings, &{&1.signal, &1.condition}) == %{
             cpu_psi: :pressure,
             memory_psi: :healthy,
             available_memory: :pressure,
             cgroup_headroom: :healthy,
             build_gate: :pressure,
             provider_budget: :unknown
           }

    low_budget = fn -> %{freshness: "fresh", level: 0.09, age_ms: 3_000} end
    sample = ResourceReadings.sample(agent, host: host, build_status: build, provider_energy: low_budget)
    assert %{condition: :pressure, observed_at_ms: observed} = Enum.find(sample.resource_readings, &(&1.signal == :provider_budget))
    assert System.monotonic_time(:millisecond) - observed >= 3_000
  end
end
