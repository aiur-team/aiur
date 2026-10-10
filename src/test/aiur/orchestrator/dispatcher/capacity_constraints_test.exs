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

    # `admission_gate/1` can bind on gates that have no standalone probe. Without
    # recording the binding signal, a fleet held by one of them reports zero
    # constraints and `sync_capacity_starvation_alert/3` clears starvation
    # instead of alerting — the fleet is stuck and nothing says so.
    test "a build-queue hold still records a constraint and starves" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.capacity_starved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: 2)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      Application.put_env(:aiur, :build_gate_status_override, fn ->
        %{enabled?: true, capacity: 2, active: 2, queued: 1}
      end)

      ready = issue("build-queued")

      sample = fn state ->
        state
        |> Map.put(:dispatch_capacity_constraints, [])
        |> Dispatcher.maybe_choose_under_load([ready], fn sampled, _issues -> sampled end)
      end

      held =
        %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 1_000)

      assert Enum.any?(held.dispatch_capacity_constraints, &(&1.kind == :build_queue))

      alerted =
        held
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 61_000)

      assert alerted.capacity_starvation.alerted == ["build-queue"]
      assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
      assert event["reason"] =~ "build-queue gate"
    end

    test "keeps a persistent build-queue age while a higher-priority memory gate oscillates" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.capacity_starved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_builds: 2,
        min_free_memory_mb: 2_048
      )

      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      # The build queue stays saturated for the whole window; memory drops out
      # and recovers around it. Memory outranks build in `admission_gate/1`, so
      # before every failing gate was sampled independently the build-queue
      # identity vanished from the constraint set on the memory ticks and its
      # age restarted — suppressing the alert for as long as memory oscillated.
      Application.put_env(:aiur, :build_gate_status_override, fn ->
        %{enabled?: true, capacity: 2, active: 2, queued: 1}
      end)

      {:ok, memory_samples} =
        Agent.start_link(fn ->
          ["MemAvailable: 4096000 kB\n", "MemAvailable: 1048576 kB\n", "MemAvailable: 4096000 kB\n"]
        end)

      Application.put_env(:aiur, :meminfo_source_override, fn ->
        Agent.get_and_update(memory_samples, fn [sample | rest] -> {{:ok, sample}, rest} end)
      end)

      ready = issue("build-starved")

      sample = fn state ->
        state
        |> Map.put(:dispatch_capacity_constraints, [])
        |> Dispatcher.maybe_choose_under_load([ready], fn sampled, _issues -> sampled end)
      end

      held =
        %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 1_000)

      assert Enum.any?(held.dispatch_capacity_constraints, &(&1.kind == :build_queue))

      masked =
        held
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 30_000)

      # Memory is binding on this tick, but the build queue must still be
      # recorded so its age survives.
      assert Enum.any?(masked.dispatch_capacity_constraints, &(&1.kind == :memory))
      assert Enum.any?(masked.dispatch_capacity_constraints, &(&1.kind == :build_queue))
      assert masked.capacity_starvation.since_ms["build-queue"] == 1_000

      alerted =
        masked
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 61_000)

      assert "build-queue" in alerted.capacity_starvation.alerted
      assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
      assert event["reason"] =~ "build-queue gate"
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
