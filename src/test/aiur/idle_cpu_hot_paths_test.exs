defmodule Aiur.IdleCpuHotPathsTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.History
  alias Aiur.BuildOrder.History.Row
  alias Aiur.Config
  alias Aiur.Config.SettingsSnapshot
  alias Aiur.Issue
  alias Aiur.Orchestrator.{Dispatcher, IssueSync, State}
  alias Aiur.Orchestrator.StatusReport.{AgentStatuses, SnapshotPayload}

  @store __MODULE__.History
  @workflow_read {Aiur.Workflow, :current_with_cache_identity, 0}
  @row_encode {Row, :to_json, 1}

  test "settings snapshot expires after the batch, including nested failures" do
    original = Config.settings!()

    SettingsSnapshot.run(fn ->
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_terminal_states: ["snapshot-test"])
      Aiur.WorkflowStore.force_reload()
      assert Config.settings!() == original
      assert_raise RuntimeError, "nested", fn -> SettingsSnapshot.run(fn -> raise "nested" end) end
      assert Config.settings!() == original
    end)

    assert Config.settings!().tracker.terminal_states == ["snapshot-test"]
    assert_raise RuntimeError, "outer", fn -> SettingsSnapshot.run(fn -> raise "outer" end) end
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_terminal_states: ["next-batch"])
    Aiur.WorkflowStore.force_reload()
    assert Config.settings!().tracker.terminal_states == ["next-batch"]
  end

  test "candidate poll does not sample settings for each stranded ticket" do
    issues = Map.values(idle_state(530).last_polled_issues)

    {state, reads, reductions} =
      measured_calls(@workflow_read, fn ->
        Dispatcher.dispatch_candidate_poll(%State{},
          fetch_candidate_issues_fun: fn state -> {:paused, state} end,
          monitor_without_candidates_fun: fn state ->
            IssueSync.sync_stranded_ticket_reconciliation(state, issues, fn _, _ -> flunk("todo cannot be stranded") end)
          end
        )
      end)

    assert %State{} = state
    IO.puts("idle_cpu candidate_poll tickets=530 settings_reads=#{reads} reductions=#{reductions}")
    assert reads == 1
  end

  test "status rows and snapshot each sample settings once for 530 tickets" do
    state = idle_state(530)

    for {name, fun} <- [statuses: fn -> AgentStatuses.agent_statuses(state, fn _ -> {:unavailable, nil} end) end, snapshot: fn -> SnapshotPayload.snapshot_payload(state) end] do
      {result, reads, reductions} = measured_calls(@workflow_read, fun)
      assert length(if is_list(result), do: result, else: result.idle) == 530
      IO.puts("idle_cpu #{name} tickets=530 settings_reads=#{reads} reductions=#{reductions}")
      assert reads == 1
    end
  end

  test "history checkpoint flush reuses all rows and a changed row alone is re-encoded" do
    dir = Aiur.TestSupport.tmp_root!("idle-cpu-history")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    start_history(dir)
    opts = [server: @store]
    now = DateTime.utc_now()
    events = for n <- 1..2000, do: %{number: n, observed_at: now, source: :poll, fields: %{title: "Ticket #{n}"}}
    assert {:ok, _} = History.apply(events, opts)
    assert :ok = History.flush(opts)

    assert {:ok, _} = History.apply([], opts ++ [checkpoint: {:closed_since, %{"cursor" => "next"}}])
    {result, encoded, reductions} = measured_calls(@row_encode, fn -> History.flush(opts) end, Process.whereis(@store))
    assert result == :ok
    IO.puts("idle_cpu history_checkpoint rows=2000 encoded=#{encoded} reductions=#{reductions}")
    checkpoint_encoded = encoded

    assert {:ok, %{changed: [1]}} = History.apply([%{hd(events) | fields: %{title: "changed"}}], opts)
    {result, encoded, reductions} = measured_calls(@row_encode, fn -> History.flush(opts) end, Process.whereis(@store))
    assert result == :ok
    IO.puts("idle_cpu history_one_change rows=2000 encoded=#{encoded} reductions=#{reductions}")
    assert checkpoint_encoded == 0
    assert encoded == 1
    stop_supervised!(@store)
    start_history(dir)
    assert {:ok, [row], _} = History.rows([1], opts)
    assert row.title == "changed"
    assert {:ok, %{"cursor" => "next"}} = History.checkpoint(:closed_since, opts)
    assert {:ok, numbers, _} = History.numbers(opts)
    assert length(numbers) == 2000
  end

  defp start_history(dir), do: start_supervised!({History, name: @store, repository: "acme/widgets", state_dir: dir, flush_ms: 60_000})

  defp idle_state(count) do
    issues = Map.new(1..count, fn n -> {"#{n}", %Issue{id: "#{n}", identifier: "CPU-#{n}", state: "todo", labels: []}} end)
    %State{last_polled_issues: issues, candidate_snapshot_fresh?: true}
  end

  defp measured_calls(mfa, fun, target \\ nil) do
    parent = self()

    worker =
      spawn_link(fn ->
        receive do
          :run -> send(parent, {:measured_result, self(), fun.()})
        end

        receive do
          :stop -> :ok
        end
      end)

    target = target || worker
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(target, true, [:call, {:tracer, parent}])
    {:reductions, before} = Process.info(target, :reductions)

    try do
      send(worker, :run)
      result = receive do: ({:measured_result, ^worker, result} -> result)
      {:reductions, after_count} = Process.info(target, :reductions)
      delivery = :erlang.trace_delivered(target)
      receive do: ({:trace_delivered, ^target, ^delivery} -> :ok)
      {result, count_calls(target, mfa, 0), after_count - before}
    after
      :erlang.trace(target, false, [:call])
      :erlang.trace_pattern(mfa, false, [:local])
      send(worker, :stop)
    end
  end

  defp count_calls(pid, {module, function, arity} = mfa, count) do
    receive do
      {:trace, ^pid, :call, {^module, ^function, args}} when length(args) == arity -> count_calls(pid, mfa, count + 1)
    after
      0 -> count
    end
  end
end
