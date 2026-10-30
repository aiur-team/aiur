defmodule Aiur.Orchestrator.PollAttentionSnapshotTest do
  use Aiur.DispatcherTestSupport

  alias Aiur.AlertLedger
  alias Aiur.Orchestrator.FeatureSupplySnapshot
  alias Aiur.Orchestrator.IssueSync.AttentionSnapshot

  test "candidate polls project the alert ledger once for many synced issues and refresh next poll" do
    issues = for n <- 1..50, do: %{issue("attention-#{n}") | paused: true}
    topic = "system.poll-snapshot-test"
    assert :ok = AlertLedger.append(%{"topic" => topic, "needs_attention" => true})

    {state, reads} = measured_calls({Aiur.AlertFeed, :list, 1}, fn -> poll(%State{}, issues) end)
    assert MapSet.member?(state.active_attention_topics, topic)
    assert map_size(state.last_polled_issues) == 50
    assert reads == 1

    assert :ok = AlertLedger.append(%{"topic" => "#{topic}.resolved", "needs_attention" => false})
    {state, reads} = measured_calls({Aiur.AlertFeed, :list, 1}, fn -> poll(state, issues) end)
    refute MapSet.member?(state.active_attention_topics, topic)
    assert reads == 1
  end

  test "standalone reads stay fresh and nested failures do not leak the poll snapshot" do
    topic = "system.snapshot-lifetime-test"

    AttentionSnapshot.run(fn ->
      refute AttentionSnapshot.active_system_attention?(topic)
      assert :ok = AlertLedger.append(%{"topic" => topic, "needs_attention" => true})
      assert_raise RuntimeError, "nested", fn -> AttentionSnapshot.run(fn -> raise "nested" end) end
      refute AttentionSnapshot.active_system_attention?(topic)
    end)

    assert AttentionSnapshot.active_system_attention?(topic)

    assert_raise RuntimeError, "outer", fn ->
      AttentionSnapshot.run(fn ->
        assert AttentionSnapshot.active_system_attention?(topic)
        raise "outer"
      end)
    end

    assert :ok = AlertLedger.append(%{"topic" => "#{topic}.resolved", "needs_attention" => false})
    refute AttentionSnapshot.active_system_attention?(topic)
  end

  test "feature supply constructs active states once for fifty candidates" do
    features = for n <- 1..50, do: %{issue("feature-#{n}") | labels: ["feature:test"]}
    {sample, reads} = measured_calls({DispatchPolicy, :active_state_set, 0}, fn -> FeatureSupplySnapshot.build(%State{}, features) end)
    assert sample.feature_ready == 50
    assert sample.declines == %{}
    assert reads == 1
  end

  defp poll(state, issues) do
    Dispatcher.dispatch_candidate_poll(state,
      fetch_candidate_issues_fun: fn state -> {:ok, issues, state} end,
      startup_claim_opts: [read_boot_marker_fun: fn -> {:ok, Aiur.Boot.run_id()} end],
      scan_commands_fun: &Function.identity/1,
      stop_closed_pr_agents_fun: &Function.identity/1,
      stranded_reconciliation_fun: fn state, _ -> state end
    )
  end

  defp measured_calls(mfa, fun) do
    parent = self()

    worker =
      spawn_link(fn ->
        receive do
          :run -> send(parent, {:result, self(), fun.()})
        end

        receive do: (:stop -> :ok)
      end)

    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(worker, true, [:call, {:tracer, parent}])

    try do
      send(worker, :run)
      result = receive do: ({:result, ^worker, result} -> result)
      delivery = :erlang.trace_delivered(worker)
      receive do: ({:trace_delivered, ^worker, ^delivery} -> :ok)
      {result, count_calls(worker, mfa, 0)}
    after
      :erlang.trace(worker, false, [:call])
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
