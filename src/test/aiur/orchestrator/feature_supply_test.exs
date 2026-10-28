defmodule Aiur.Orchestrator.FeatureSupplyTest do
  use Aiur.DispatcherTestSupport
  alias Aiur.Orchestrator.{FeatureSupply, FeatureSupplySnapshot}
  alias Aiur.StartTrigger.ProgressStore
  @hold 30 * 60_000
  @clear 10 * 60_000

  test "three free slots and one ready feature opens once after thirty minutes; three ready does not" do
    low = observe(state(), [feature("1")], 0) |> observe([feature("1")], @hold - 1)
    assert low.feature_supply.sample.free == 3
    assert low.feature_supply.sample.feature_ready == 1
    refute low.feature_supply.active
    refute_received {:supply_alert, _, _}
    low = observe(low, [feature("1")], @hold)
    assert low.feature_supply.active
    assert_received {:supply_alert, "system.feature_supply_low", opts}
    assert opts[:needs_attention]
    assert opts[:exchange_payload].free == 3
    assert opts[:exchange_payload].feature_ready == 1
    observe(low, [feature("1")], @hold * 2)
    refute_received {:supply_alert, _, _}
    enough = observe(state(), features(), 0) |> observe(features(), @hold * 2)
    assert enough.feature_supply.sample.feature_ready == 3
    refute enough.feature_supply.active
    refute_received {:supply_alert, _, _}
  end

  test "low and clear holds must be continuous and a resolved episode can reopen" do
    low = observe(state(), [], 0) |> observe(features(), @hold - 1) |> observe([], @hold) |> observe([], @hold * 2 - 1)
    refute low.feature_supply.active
    low = observe(low, [], @hold * 2)
    assert_received {:supply_alert, "system.feature_supply_low", _}
    low = observe(low, features(), @hold * 2 + 1) |> observe([], @hold * 2 + @clear)
    low = observe(low, features(), @hold * 2 + @clear + 1) |> observe(features(), @hold * 2 + @clear * 2)
    refute_received {:supply_alert, "system.feature_supply_low.resolved", _}
    low = observe(low, features(), @hold * 2 + @clear * 2 + 1)
    refute low.feature_supply.active
    assert_received {:supply_alert, "system.feature_supply_low.resolved", _}
    low = observe(low, [], @hold * 3) |> observe([], @hold * 4)
    assert low.feature_supply.active
    assert_received {:supply_alert, "system.feature_supply_low", _}
  end

  test "unknown and paused passes break timing and telemetry coverage" do
    low = observe(state(), [], 0) |> FeatureSupply.unavailable() |> observe([], @hold)
    refute low.feature_supply.active
    refute_received {:supply_record, :feature_supply, %{event: "interval"}}
    paused = observe(%{low | globally_paused: true}, [], @hold * 2)
    resumed = observe(%{paused | globally_paused: false}, [], @hold * 3)
    refute resumed.feature_supply.active
    refute_received {:supply_alert, _, _}
  end

  test "interval telemetry integrates deficit and counts non-feature overlap once" do
    running = %{"maintenance" => %{issue: issue("maintenance"), pid: self(), started_at: DateTime.utc_now()}}
    start = %{state() | max_concurrent_agents: 4, effective_concurrent_agents: 4, running: running}
    observed = observe(start, [feature("1")], 0) |> observe([feature("1")], 90_000)
    assert observed.feature_supply.sample.free == 3
    assert_received {:supply_record, :feature_supply, interval}
    assert interval.event == "interval"
    assert interval.feature_starved_slot_minutes == 3.0
    assert interval.non_feature_during_starvation_minutes == 1.5
    assert interval.observed_minutes == 1.5
    assert interval.interval_end_ms - interval.interval_start_ms == 90_000
    observed |> observe(features(), 120_000) |> observe(features(), 180_000)
    assert_received {:supply_record, :feature_supply, %{feature_starved_slot_minutes: starved, non_feature_during_starvation_minutes: overlap}}
    assert starved == 0
    assert overlap == 0
  end

  test "todo declines rank only holding dependencies with cached PR evidence" do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, ProgressStore)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, ProgressStore) end)
    start_supervised!({ProgressStore, seed: fn -> %{passed_heads: %{}} end})
    ProgressStore.record("blocker-1", %{pr_number: 42, stage: :pr_opened})
    :sys.get_state(ProgressStore)
    held = for n <- 1..7, do: %{feature("held-#{n}") | blocked_by: [%{id: "blocker-#{n}", identifier: "repo##{n}", state: "human-review"}]}
    extra = %{feature("extra") | blocked_by: [%{id: "blocker-1", identifier: "repo#1", state: "human-review"}, %{id: "closed", state: "done"}]}
    paused = %{feature("paused") | labels: ["feature:test", "agent:paused"], paused: true}
    sample = FeatureSupplySnapshot.build(state(), [feature("ready"), issue("not-feature"), paused, extra | held])
    assert sample.feature_ready == 1
    assert sample.declines == %{"dependency" => 8, "paused" => 1}
    assert length(sample.blockers) == 5
    assert hd(sample.blockers) == %{id: "blocker-1", identifier: "repo#1", state: "human-review", feature_tickets: 2, pr_number: 42, pr_state: "open", pr_stage: :pr_opened}
    assert Enum.at(sample.blockers, 1).pr_state == "unknown"
    assert Enum.at(sample.blockers, 1).pr_number == nil
    refute Enum.any?(sample.blockers, &(&1.id == "closed"))
  end

  test "real alert publishes evidence and is bound to wake the Executor" do
    :ok = Exchange.subscribe("system.feature_supply_low")
    low = FeatureSupply.observe(state(), [feature("1")], now_ms: 0) |> FeatureSupply.observe([feature("1")], now_ms: @hold)
    assert low.feature_supply.active
    assert_received {:event, %{"topic" => "system.feature_supply_low", "reason" => reason} = event}
    assert event[:free] == 3
    assert event[:feature_ready] == 1
    assert reason =~ "free=3, feature_ready=1"
    assert {"system.feature_supply_low", "dispatch:auto"} in Aiur.ExecutorBindings.defaults()
    assert {"system.feature_supply_low.resolved", "dispatch:auto"} in Aiur.ExecutorBindings.defaults()
  end

  test "successful dispatch polls observe supply and failed polls invalidate it" do
    observed =
      Dispatcher.dispatch_candidate_poll(state(),
        fetch_candidate_issues_fun: fn state -> {:ok, [], state} end,
        startup_claim_opts: [read_boot_marker_fun: fn -> {:ok, Aiur.Boot.run_id()} end],
        scan_commands_fun: &Function.identity/1,
        stop_closed_pr_agents_fun: &Function.identity/1,
        stranded_reconciliation_fun: fn state, _ -> state end
      )

    assert observed.feature_supply.sample.feature_ready == 0
    assert observed.feature_supply.sample.free == 3
    assert is_integer(observed.feature_supply.since)

    failed =
      Dispatcher.dispatch_candidate_poll(observed,
        fetch_candidate_issues_fun: fn state -> {:error, :offline, state} end,
        monitor_without_candidates_fun: &Function.identity/1
      )

    refute Map.has_key?(failed.feature_supply, :at)
    refute Map.has_key?(failed.feature_supply, :since)
  end

  test "publication failures retry without losing the hold or emitting success telemetry" do
    owner = self()
    failed = fn _, _ -> {:error, :unavailable} end

    record = fn kind, attrs ->
      send(owner, {:supply_record, kind, attrs})
      :ok
    end

    low = observe(state(), [], 0)
    low = FeatureSupply.observe(low, [], now_ms: @hold, emit: failed, record: record)
    refute low.feature_supply.active
    refute_received {:supply_record, _, %{event: "opened"}}
    low = observe(low, [], @hold + 1)
    assert low.feature_supply.active
    assert_received {:supply_record, _, %{event: "opened"}}
    low = observe(low, features(), @hold + 2)
    low = FeatureSupply.observe(low, features(), now_ms: @hold + @clear + 2, emit: failed, record: record)
    assert low.feature_supply.active
    refute_received {:supply_record, _, %{event: "resolved"}}
    low = observe(low, features(), @hold + @clear + 3)
    refute low.feature_supply.active
    assert_received {:supply_record, _, %{event: "resolved"}}
  end

  test "production paused poll resets the observation before asynchronous tracker work" do
    low = observe(state(), [], 0)
    paused = Dispatcher.start_candidate_poll(%{low | globally_paused: true}, fn _ -> {:ok, [], %{}} end)
    refute Map.has_key?(paused.feature_supply, :at)
    refute Map.has_key?(paused.feature_supply, :since)
    resumed = observe(%{paused | globally_paused: false}, [], @hold)
    refute resumed.feature_supply.active
    refute_received {:supply_record, _, %{event: "interval"}}

    for {ref, job} <- paused.tracker_tasks do
      Task.shutdown(job.task, :brutal_kill)
      if is_reference(job.timer), do: Process.cancel_timer(job.timer)
      Process.demonitor(ref, [:flush])
    end
  end

  test "actual alert ledger failure keeps the latch retryable" do
    root = Aiur.TestSupport.tmp_root!("feature-supply-ledger")
    File.mkdir_p!(root)
    bad_root = Path.join(root, "not-a-directory")
    File.write!(bad_root, "blocked")
    previous = Application.get_env(:aiur, :runtime_state_dir)
    on_exit(fn -> restore_app_env(:runtime_state_dir, previous) end)
    Application.put_env(:aiur, :runtime_state_dir, bad_root)
    low = FeatureSupply.observe(state(), [], now_ms: 0)
    low = FeatureSupply.observe(low, [], now_ms: @hold)
    refute low.feature_supply.active
    Application.put_env(:aiur, :runtime_state_dir, Path.join(root, "ledger"))
    low = FeatureSupply.observe(low, [], now_ms: @hold + 1)
    assert low.feature_supply.active
    low = FeatureSupply.observe(low, features(), now_ms: @hold + 2)
    Application.put_env(:aiur, :runtime_state_dir, bad_root)
    low = FeatureSupply.observe(low, features(), now_ms: @hold + @clear + 2)
    assert low.feature_supply.active
    Application.put_env(:aiur, :runtime_state_dir, Path.join(root, "ledger"))
    low = FeatureSupply.observe(low, features(), now_ms: @hold + @clear + 3)
    refute low.feature_supply.active
  end

  defp state, do: %State{max_concurrent_agents: 3, effective_concurrent_agents: 3}
  defp feature(id), do: %{issue(id) | labels: ["feature:test"]}
  defp features, do: Enum.map(1..3, &feature(to_string(&1)))

  defp observe(state, issues, now) do
    owner = self()

    FeatureSupply.observe(state, issues,
      now_ms: now,
      timestamp_ms: 1_793_059_200_000 + now,
      emit: fn topic, opts ->
        send(owner, {:supply_alert, topic, opts})
        :ok
      end,
      record: fn kind, attrs ->
        send(owner, {:supply_record, kind, attrs})
        :ok
      end
    )
  end
end
