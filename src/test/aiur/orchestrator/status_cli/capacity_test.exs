Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliCapacityTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy}

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.Orchestrator.StatusCLI, as: AgentControlCLI

  defp unconstrained_capacity(overrides) do
    Map.merge(
      %{
        occupied: 0,
        max: 2,
        effective: 2,
        configured: 2,
        available: 2,
        queued_demand?: false,
        session_override?: false,
        active: 0,
        reserved_paused: 0,
        capacity_hold: nil
      },
      overrides
    )
  end

  # The core #2138 status defect: `binding: ticket supply` was reported while
  # claimable tickets existed, because the daemon had not polled recently enough
  # to see them. While idle backoff is active (or the candidate snapshot is not
  # fresh), the line must say the fleet has not polled, never blame ticket
  # supply.
  test "status names the config cap and AIMD envelope binding constraints", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 2,
          running: %{
            "issue-44" => running_entry("issue-44", "repo#44", :working),
            "issue-45" => running_entry("issue-45", "repo#45", :working)
          },
          last_polled_issues: %{"issue-queued" => queued_issue()}
      }
    end)

    config_output = capture_io(fn -> AgentControlCLI.status() end)
    assert config_output =~ "AGENTS 2/2 (binding: config max_concurrent_agents)"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 2,
          effective_concurrent_agents: 1,
          running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)},
          last_polled_issues: %{"issue-queued" => queued_issue()}
      }
    end)

    envelope_output = capture_io(fn -> AgentControlCLI.status() end)
    assert envelope_output =~ "AGENTS 1/2 (binding: AIMD envelope, effective cap=1)"
  end

  test "status shows provider freshness detail for a provider capacity hold" do
    snapshot = %{
      statuses: [],
      global_pause: %{globally_paused: false, paused_at: nil, source: nil},
      capacity:
        unconstrained_capacity(%{
          capacity_hold: %{
            signal: :provider,
            measured: ["codex"],
            detail: "backends=codex=stale observed_at=2026-10-06T10:00:00Z next_probe=unknown",
            threshold: :all_usage_limited,
            held_since_ms: System.monotonic_time(:millisecond),
            measured_at: DateTime.utc_now()
          }
        }),
      polling: %{}
    }

    freshness = %{status: :current, reason: nil, age_seconds: 0}

    output =
      capture_io(fn ->
        AgentControlCLI.status(fleet_view: {:ok, snapshot, freshness})
      end)

    assert output =~
             "AGENTS 0/2 (binding: provider, backends=codex=stale observed_at=2026-10-06T10:00:00Z next_probe=unknown sampled=0s ago)"
  end

  test "status reports only the daemon's own admission hold as the binding constraint", %{orchestrator: pid} do
    local_schedulers = System.schedulers_online()
    local_load = local_schedulers * 2.0
    previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{local_load} 1.0 1.0 1/1 1"} end)

    on_exit(fn ->
      if previous_loadavg,
        do: Application.put_env(:aiur, :loadavg_source_override, previous_loadavg),
        else: Application.delete_env(:aiur, :loadavg_source_override)
    end)

    # The load gate holds only against a measured CPU window (#2089), so the
    # probes carry a `/proc/stat` sample and the sampled state carries the
    # baseline a polling daemon would already hold: 10 idle jiffies out of 200 is
    # 5% reclaimable.
    baseline_cpu = %{total: 1_000, idle: 700, nice: 100, runnable: 20}
    current_cpu = %{total: 1_200, idle: 710, nice: 100, runnable: 20}
    contention = %{idle_percent: 5.0, nice_percent: 0.0, reclaimable_percent: 5.0, runnable: 20}

    probes = %{
      memory_mb: :unavailable,
      memory_threshold_mb: nil,
      fd_sample: :unavailable,
      runnable: :unavailable,
      run_queue_threshold: nil,
      schedulers: local_schedulers,
      load: local_load,
      load_threshold: 1.5,
      build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
      provider_backends: [],
      github_quota: :available,
      cpu_snapshot: current_cpu,
      cpu_headroom: contention,
      target: nil
    }

    assert {:hold, %{signal: :load, measured: ^local_load, threshold: threshold}} =
             DispatchPolicy.admission_gate(Map.put(probes, :queued_demand?, true))

    assert threshold == local_schedulers * 1.5

    sampled =
      :sys.get_state(pid)
      |> Map.merge(%{
        max_concurrent_agents: 10,
        effective_concurrent_agents: 10,
        last_polled_issues: %{"queued" => queued_issue()},
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: baseline_cpu, bootstrap_complete?: true}
      })
      |> Dispatcher.maybe_choose_under_load(
        [queued_issue()],
        fn state, _issues ->
          send(self(), :dispatched)
          state
        end,
        admission_probes_fun: fn -> probes end
      )

    refute_received :dispatched

    assert %{signal: :load, measured: ^local_load, threshold: ^threshold, reclaimable_cpu_percent: 5.0} =
             sampled.capacity_hold

    # A persisted hold without corroboration fields still has to render (an older
    # daemon's state, or a signal that carries none).
    :sys.replace_state(pid, fn _state ->
      %{sampled | capacity_hold: Map.drop(sampled.capacity_hold, [:reclaimable_cpu_percent, :reclaimable_cpu_threshold])}
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    # Every admission measurement carries the age of the sample it came from, so
    # a figure minutes older than the `LOAD` line beside it cannot read as
    # current (#2527).
    assert output =~ "AGENTS 0/10 (binding: load, load=#{local_load} threshold=#{threshold} sampled="
    assert output =~ ~r/AGENTS 0\/10 \(binding: load, .* sampled=\d+s ago\)/

    assert output =~
             "LOAD (local fallback diagnostic) #{local_load} threshold=#{threshold} schedulers=#{local_schedulers} " <>
               "(local host sample; over fallback load threshold, PSI governs dispatch when available)"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | capacity_hold:
            Map.merge(state.capacity_hold, %{
              reclaimable_cpu_percent: 5.0,
              reclaimable_cpu_threshold: 60.0
            })
      }
    end)

    corroborated_output = capture_io(fn -> AgentControlCLI.status() end)

    assert corroborated_output =~
             "AGENTS 0/10 (binding: load+cpu contention, load=#{local_load} threshold=#{threshold} " <>
               "reclaimable_cpu=5.0% threshold=60.0% sampled="

    # The daemon still holds. A quiet LOCAL sample must not clear the daemon's
    # decision, and the local line must never claim to be the fleet's binding
    # constraint.
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 1.0 1.0 1/1 1"} end)

    persisted_hold_output = capture_io(fn -> AgentControlCLI.status() end)

    assert persisted_hold_output =~
             "AGENTS 0/10 (binding: load+cpu contention, load=#{local_load} threshold=#{threshold} " <>
               "reclaimable_cpu=5.0% threshold=60.0% sampled="

    assert persisted_hold_output =~ "LOAD (local fallback diagnostic) 0.0 threshold=#{threshold} schedulers=#{local_schedulers} (local host sample)"
    refute persisted_hold_output =~ "(binding: load)"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | capacity_hold:
            Map.merge(state.capacity_hold, %{
              signal: :run_queue,
              measured: 74,
              threshold: 24.0
            })
      }
    end)

    run_queue_output = capture_io(fn -> AgentControlCLI.status() end)

    assert run_queue_output =~
             "AGENTS 0/10 (binding: run_queue+cpu contention, runnable=74 threshold=24.0 " <>
               "reclaimable_cpu=5.0% threshold=60.0% sampled="

    # A sample the daemon has not refreshed for several poll cycles was taken on
    # a tick that never ran. It is still the last thing the daemon measured, so
    # it keeps its place on the line — but it may no longer read as current.
    :sys.replace_state(pid, fn state ->
      %{state | capacity_hold: Map.put(state.capacity_hold, :measured_at, DateTime.add(DateTime.utc_now(), -600, :second))}
    end)

    stale_output = capture_io(fn -> AgentControlCLI.status() end)

    assert stale_output =~ ~r/AGENTS 0\/10 \(binding: run_queue\+cpu contention, .* sampled=600s ago STALE\)/

    # The inverse, and the actual regression guard: the daemon is NOT holding,
    # but the CLI's own host is over the CLI's own threshold. A locally
    # re-derived gate used to print "binding: load" here — a fleet-level cause
    # the daemon never decided (#1610).
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{local_load} 1.0 1.0 1/1 1"} end)

    :sys.replace_state(pid, fn _state ->
      %{sampled | capacity_hold: nil, last_dispatch_poll_at_ms: System.monotonic_time(:millisecond)}
    end)

    fallback_output = capture_io(fn -> AgentControlCLI.status() end)

    assert fallback_output =~ "AGENTS 0/10 (binding: awaiting dispatch; ceiling: config max_concurrent_agents)"
    refute fallback_output =~ "AGENTS 0/10 (binding: load"

    assert fallback_output =~
             "LOAD (local fallback diagnostic) #{local_load} threshold=#{threshold} schedulers=#{local_schedulers} " <>
               "(local host sample; over fallback load threshold, PSI governs dispatch when available)"
  end

  test "status gives the GitHub quota measurement and its observation time", %{orchestrator: pid} do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_concurrent_agents: 16,
          effective_concurrent_agents: 16,
          capacity_hold: %{
            signal: :github_quota,
            measured: %{resource: "graphql", remaining: 143, limit: 5000, observed_at: observed_at},
            threshold: :ten_percent_remaining,
            held_since_ms: System.monotonic_time(:millisecond),
            alerted?: false
          },
          last_polled_issues: %{"queued" => queued_issue()}
      }
    end)

    output = capture_io(fn -> AgentControlCLI.status() end)

    assert output =~
             "AGENTS 0/16 (binding: github_quota, resource=graphql remaining=143/5000 measured_at=#{DateTime.to_iso8601(observed_at)})"

    :sys.replace_state(pid, fn state ->
      put_in(state.capacity_hold.measured.observed_at, DateTime.add(observed_at, -121, :second))
    end)

    stale_output = capture_io(fn -> AgentControlCLI.status() end)

    assert stale_output =~
             "AGENTS 0/16 (binding: github_quota stale, last_resource=graphql last_remaining=143/5000 last_measured_at="
  end
end
