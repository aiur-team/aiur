defmodule Aiur.Orchestrator.Dispatcher.CapacityConstraintsTest do
  use Aiur.DispatcherTestSupport

  describe "capacity constraint sampling" do
    test "preserves a load gate age while memory and FD holds mask admission" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.capacity_starved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      {:ok, admission_samples} =
        Agent.start_link(fn ->
          [
            %{memory_mb: 4_000, fd_sample: :unavailable},
            %{memory_mb: 1_024, fd_sample: :unavailable},
            %{memory_mb: 4_000, fd_sample: :exhausted},
            %{memory_mb: 4_000, fd_sample: :unavailable}
          ]
        end)

      # Advancing /proc/stat counters that grow almost entirely in non-idle time,
      # so every cycle measures a real 5%-reclaimable window. The load gate needs
      # that measurement before it can hold at all (#2089).
      {:ok, cpu_cycles} = Agent.start_link(fn -> 0 end)

      admission_probes = fn ->
        cycle = Agent.get_and_update(cpu_cycles, &{&1 + 1, &1 + 1})

        Agent.get_and_update(admission_samples, fn [sample | rest] -> {sample, rest} end)
        |> Map.merge(%{
          memory_threshold_mb: 2_048,
          runnable: :unavailable,
          run_queue_threshold: nil,
          schedulers: 4,
          load: 10_000.0,
          load_threshold: 1.0,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          cpu_snapshot: %{total: 1_000 + 200 * cycle, idle: 700 + 10 * cycle, nice: 100, runnable: 20},
          target: nil
        })
      end

      cpu_baseline = %{total: 1_000, idle: 700, nice: 100, runnable: 20}

      ready = issue("persistent-load")

      sample = fn state ->
        state
        |> Map.put(:dispatch_capacity_constraints, [])
        |> Dispatcher.maybe_choose_under_load(
          [ready],
          fn sampled, _issues -> sampled end,
          admission_probes_fun: admission_probes
        )
      end

      waiting =
        %State{
          max_concurrent_agents: 1,
          effective_concurrent_agents: 1,
          load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: cpu_baseline, bootstrap_complete?: true}
        }
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 1_000)

      assert Enum.any?(waiting.dispatch_capacity_constraints, &(&1.kind == :load))

      memory_masked =
        waiting
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 30_000)

      assert Enum.any?(memory_masked.dispatch_capacity_constraints, &(&1.kind == :load))
      assert Enum.any?(memory_masked.dispatch_capacity_constraints, &(&1.kind == :memory))

      fd_masked =
        memory_masked
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 45_000)

      assert Enum.any?(fd_masked.dispatch_capacity_constraints, &(&1.kind == :load))
      assert Enum.any?(fd_masked.dispatch_capacity_constraints, &(&1.kind == :fd))

      alerted =
        fd_masked
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 61_000)

      assert alerted.capacity_starvation.alerted == ["load"]
      assert alerted.capacity_starvation.since_ms == %{"load" => 1_000}
      assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
      assert event["reason"] =~ "load gate"
    end

    # #2447: a daemon restart deliberately starts the dispatch envelope at one
    # slot and widens it per below-target sample. The below-target ramp must
    # never record a `:load_envelope` constraint or raise either capacity
    # starvation alert; the fleet filling to its widening envelope is the
    # intended behavior, not starvation.
    test "restart ramp produces no capacity-starvation alerts" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.capacity_starved")
      :ok = Exchange.subscribe("system.fleet.capacity.starved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      ready = for id <- 1..8, do: issue("ramp-restart-#{id}")

      admission_probes = fn ->
        %{
          memory_mb: 4_000,
          memory_threshold_mb: 2_048,
          fd_sample: :available,
          runnable: :unavailable,
          run_queue_threshold: nil,
          schedulers: 16,
          load: 0.7,
          load_threshold: 1.0,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          github_quota: :available,
          cpu_snapshot: %{total: 1_000, idle: 700, nice: 100, runnable: 20},
          target: 1.0
        }
      end

      cpu_baseline = %{total: 1_000, idle: 700, nice: 100, runnable: 20}

      sample = fn state ->
        state
        |> Map.put(:dispatch_capacity_constraints, [])
        |> Dispatcher.maybe_choose_under_load(
          ready,
          &consume_available_slots/2,
          admission_probes_fun: admission_probes
        )
      end

      starting = %State{
        max_concurrent_agents: 16,
        effective_concurrent_agents: 1,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: cpu_baseline, bootstrap_complete?: false}
      }

      first =
        starting
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert(ready, 1_000)
        |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)

      refute Enum.any?(first.dispatch_capacity_constraints, &(&1.kind == :load_envelope))

      second =
        %{first | effective_concurrent_agents: first.effective_concurrent_agents + 1}
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert(ready, 61_000)
        |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

      refute Enum.any?(second.dispatch_capacity_constraints, &(&1.kind == :load_envelope))

      third =
        %{second | effective_concurrent_agents: second.effective_concurrent_agents + 1}
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert(ready, 121_000)
        |> IssueSync.sync_fleet_capacity_starved_alert(ready, 121_000)

      refute Enum.any?(third.dispatch_capacity_constraints, &(&1.kind == :load_envelope))
      refute third.capacity_starvation.alert_active
      refute third.fleet_capacity_starvation.alert_active

      refute_received {:event, %{topic: "system.dispatch.capacity_starved"}}
      refute_received {:event, %{topic: "system.fleet.capacity.starved"}}
    end
  end
end
