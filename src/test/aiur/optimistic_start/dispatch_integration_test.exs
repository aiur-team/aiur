defmodule Aiur.OptimisticStart.DispatchIntegrationTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.Hints
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator.{AutoSubscriptions, Dispatcher, State}
  alias Aiur.StartTrigger.ProgressStore

  @sha String.duplicate("a", 40)

  setup do
    :ets.new(Hints.table_name(), [:named_table, :set])
    :ok = Aiur.TestSupport.ensure_subscription_store_supervisor_running()
    blocker = to_string(System.unique_integer([:positive]))
    dependent = to_string(System.unique_integer([:positive]))
    issue = %Issue{id: dependent, identifier: dependent, title: "Dependent", state: "todo", blocked_by: [%{id: blocker, identifier: blocker, state: "ci-wait"}]}
    :ets.insert(Hints.table_name(), {dependent, {0, 0}, false, :pr_opened})
    ProgressStore.record(blocker, %{stage: :pr_opened, pr_number: 99, head_sha: @sha, source: :webhook})
    :sys.get_state(ProgressStore)
    parent = self()
    previous = Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)
    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn :lifecycle, event, _ -> send(parent, {:lifecycle, event}) end)

    on_exit(fn ->
      SubscriptionStore.stop(dependent)
      SubscriptionStore.stop(blocker)
      if previous, do: Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, previous), else: Application.delete_env(:aiur, :run_telemetry_lifecycle_recorder)
    end)

    %{issue: issue, blocker: blocker}
  end

  test "runner observes the binding before starting, with evaluated SHA in running entry and telemetry", ctx do
    parent = self()

    runner = fn issue, _, _ ->
      topics = SubscriptionStore.snapshot(issue.identifier).subscribed_to
      bound? = Enum.any?(topics, &(&1["topic"] == "ticket.#{ctx.blocker}.branch.push" and &1["reason"] == "blocker:auto"))
      send(parent, {:started, bound?, issue.optimistic_start})
      receive do: (:stop -> :ok)
    end

    # A later branch push must not replace the SHA evaluated by G1.
    state = dispatch(ctx, runner: runner, blocker_ref_lookup: fn _ -> %{ref: "refs/heads/aiur/#{ctx.blocker}-work", sha: String.duplicate("b", 40)} end)
    assert_receive {:started, true, record}, 1_000
    assert record.primary == ctx.blocker
    assert [%{identifier: blocker, pr_number: 99, ref: ref, sha: @sha}] = record.blockers
    assert blocker == ctx.blocker
    assert ref == "refs/heads/aiur/#{ctx.blocker}-work"
    assert state.running[ctx.issue.id].optimistic_start == record
    assert state.running[ctx.issue.id].issue.optimistic_start == record
    assert AutoSubscriptions.direct_blockers_for(%State{}, ctx.issue.identifier) == [ctx.blocker]
    assert_received {:lifecycle, %{event: "dispatch", optimistic_start: telemetry}}
    assert telemetry.blockers == record.blockers
    assert telemetry.primary == record.primary
    assert telemetry.pr_base == record.pr_base
    assert telemetry.started_at == DateTime.to_iso8601(record.started_at)
    send(state.running[ctx.issue.id].pid, :stop)
  end

  test "start mode retains evaluated optimism when the blocker merges during binding", ctx do
    subscriber = fn dependent, blocker ->
      :ok = AutoSubscriptions.subscribe_for_declared_blocker(dependent, blocker)
      ProgressStore.record(ctx.blocker, %{stage: :pr_merged, source: :webhook})
      :sys.get_state(ProgressStore)
      :ok
    end

    state = dispatch(ctx, blocker_subscriber: subscriber, blocker_ref_lookup: fn _ -> %{ref: "refs/heads/aiur/#{ctx.blocker}-work", sha: @sha} end)
    assert_receive :spawned, 1_000
    assert state.running[ctx.issue.id].start_mode == :optimistic
    assert [%{identifier: blocker, sha: @sha}] = state.running[ctx.issue.id].optimistic_start.blockers
    assert blocker == ctx.blocker
    assert_received {:lifecycle, %{event: "dispatch", start_mode: "optimistic", optimistic_blockers: [^blocker]}}
    send(state.running[ctx.issue.id].pid, :stop)
  end

  test "optimistic binder failure declines without spawning or claiming", ctx do
    state = dispatch(ctx, blocker_subscriber: fn _, _ -> {:error, :unavailable} end)
    assert state.dispatch_declines[ctx.issue.id] == :optimistic_subscription_failed
    refute Map.has_key?(state.running, ctx.issue.id)
    refute MapSet.member?(state.claimed, ctx.issue.id)
    refute_received :spawned
  end

  test "missing blocker ref declines without spawning or claiming", ctx do
    state = dispatch(ctx, blocker_ref_lookup: fn _ -> nil end)
    assert state.dispatch_declines[ctx.issue.id] == :optimistic_ref_unavailable
    refute Map.has_key?(state.running, ctx.issue.id)
    refute MapSet.member?(state.claimed, ctx.issue.id)
    refute_received :spawned
  end

  test "missing blocker SHA declines without spawning or claiming", ctx do
    ProgressStore.record(ctx.blocker, %{stage: :pr_opened, pr_number: 100, source: :webhook})
    :sys.get_state(ProgressStore)
    state = dispatch(ctx, blocker_ref_lookup: fn _ -> %{ref: "refs/heads/aiur/#{ctx.blocker}-work"} end)
    assert state.dispatch_declines[ctx.issue.id] == :optimistic_ref_unavailable
    refute Map.has_key?(state.running, ctx.issue.id)
    refute MapSet.member?(state.claimed, ctx.issue.id)
    refute_received :spawned
  end

  test "ordinary dispatch tolerates binder failure for a merged but still open blocker", ctx do
    ProgressStore.record(ctx.blocker, %{stage: :pr_merged, source: :webhook})
    :sys.get_state(ProgressStore)
    state = dispatch(ctx, blocker_subscriber: fn _, _ -> {:error, :unavailable} end)
    assert_receive :spawned, 1_000
    assert state.running[ctx.issue.id].optimistic_start == nil
    send(state.running[ctx.issue.id].pid, :stop)
  end

  defp dispatch(ctx, opts) do
    parent = self()

    defaults = [
      issue_fetcher: fn _ -> {:ok, [ctx.issue]} end,
      blocked_by_hydrator: fn issue -> {:ok, issue} end,
      blocker_ref_lookup: fn _ -> %{ref: "refs/heads/aiur/#{ctx.blocker}-work", sha: @sha} end,
      runner: fn _, _, _ ->
        send(parent, :spawned)
        receive do: (:stop -> :ok)
      end
    ]

    Dispatcher.dispatch_issue(%State{max_concurrent_agents: 1, effective_concurrent_agents: 1}, ctx.issue, nil, nil, Keyword.merge(defaults, opts))
  end
end
