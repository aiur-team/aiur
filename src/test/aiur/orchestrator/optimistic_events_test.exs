defmodule Aiur.Orchestrator.OptimisticEventsTest do
  use Aiur.TestSupport
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Events.Exchange
  alias Aiur.Issue
  alias Aiur.Orchestrator.{EventTopics, OptimisticEvents, OptimisticGuard, OptimisticLedger, RestackScheduler, State, TrackerTasks}
  alias Aiur.TestCleanup

  @sha String.duplicate("a", 40)

  setup do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OptimisticLedger)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OptimisticLedger) end)
    path = Path.join(System.tmp_dir!(), "optimistic-events-#{System.unique_integer([:positive])}/starts.json")
    on_exit(fn -> TestCleanup.rm_rf!(Path.dirname(path)) end)
    parent = self()
    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn :lifecycle, attrs, _ -> send(parent, {:lifecycle, attrs}) end)
    on_exit(fn -> Application.delete_env(:aiur, :run_telemetry_lifecycle_recorder) end)
    start_supervised!({OptimisticLedger, path: path})
    :ok = OptimisticLedger.record_start("10", %{attempt_id: "attempt", started_at_ms: 100, start_trigger: :pr_opened, blockers: [%{"id" => "12"}]})
    :ok
  end

  test "agent integration is self scoped, routed once and increments conflict and non fast forward counters" do
    Exchange.subscribe("ticket.10.optimistic.integrated")
    executor = ToolExecutor.build(%Issue{identifier: "10"}, nil, nil)
    arguments = %{"name" => "optimistic.integrated", "message" => "integrated blocker", "payload" => %{"blocker" => "12", "sha" => @sha, "conflict" => true, "non_ff" => true}}
    assert executor.("emit_event", arguments)["success"]
    receive_barrier({:event, %{topic: "ticket.10.optimistic.integrated"} = event})
    state = %State{}
    assert EventTopics.route(state, event) == state
    assert EventTopics.route(state, event) == state
    assert {:ok, row} = OptimisticLedger.get("10")
    assert row["counters"]["integrations_conflict"] == 1
    assert row["counters"]["integrations_clean"] == 0
    assert row["counters"]["non_ff_pushes"] == 1
    assert_received {:lifecycle, %{event: "blocker_integrate", outcome: "conflict", non_ff: true}}
    refute_received {:lifecycle, %{event: "blocker_integrate"}}
    assert executor.("emit_event", %{arguments | "name" => "ticket.11.optimistic.integrated"})["success"] == false
  end

  test "invalid, foreign emitter and unrelated blocker reports do not count" do
    base = %{"issue" => "10", "blocker" => "12", "sha" => @sha, "conflict" => false, "non_ff" => false, topic: "ticket.10.optimistic.integrated", source: :agent}

    for event <- [
          Map.put(base, "issue", "11"),
          Map.put(base, :source, :github),
          Map.put(base, "blocker", "13"),
          Map.put(base, "sha", "bad"),
          Map.put(base, "conflict", "false"),
          Map.put(base, :payload, "invalid")
        ] do
      EventTopics.route(%State{}, event)
    end

    assert {:ok, row} = OptimisticLedger.get("10")
    assert row["counters"]["integrations_clean"] == 0
    assert row["counters"]["integrations_conflict"] == 0
  end

  test "only authoritative blocker merge time determines dependent head start" do
    state = %State{}
    OptimisticEvents.merged(state, "12", %{pr: %{"merged_at" => "1970-01-01T00:00:01Z"}})
    OptimisticEvents.merged(state, "12", %{pr: %{"merged_at" => nil}})
    assert :ok = OptimisticLedger.close("10", :merged, 2_000)
    assert {:ok, row} = OptimisticLedger.get("10")
    assert hd(row["blockers"])["merged_at_ms"] == 1_000
    assert_received {:lifecycle, %{event: "optimistic_outcome", head_start_ms: 900}}
  end

  test "a just-merged blocker is reported as recovered instead of conflicting churn" do
    OptimisticLedger.record_start("11", %{attempt_id: "dependent", started_at_ms: 100, start_trigger: :pr_opened, blockers: [%{"id" => "12"}]})
    OptimisticLedger.record_integration("11", "12", @sha, true, true)
    OptimisticEvents.merged(%State{}, "12", %{pr: %{"merged_at" => "1970-01-01T00:16:40Z"}})
    assert {:ok, row} = OptimisticLedger.get("11")
    assert hd(row["blockers"])["merged_at_ms"] == 1_000_000
    assert [{:merged_notice, "11", "12"}] = OptimisticGuard.decide([row], %{}, 1_000_000, grace_ms: 0)
  end

  test "a current merged observation is enough to request a rebase notice" do
    row = %{"ticket" => "11", "status" => "running", "blockers" => [%{"id" => "12"}], "counters" => %{"integrations_conflict" => 3}}
    observation = %{confirmed?: true, observed_at_ms: 1_000_000, edge_present?: true, issue_open?: true, pr_state: :merged, pr_merged: true}
    actions = OptimisticGuard.decide([row], %{"12" => observation}, 1_000_000, grace_ms: 0)
    assert {:merged_notice, "11", "12"} in actions
    refute Enum.any?(actions, &match?({:attention, :optimistic_blocker_failed, _, _}, &1))
  end

  test "idle restack conflict records one integration through supervised task completion" do
    owner = self()
    issue = %Issue{id: "10", identifier: "10", state: "ci-wait", blocked_by: [%{id: "12"}]}

    opts = [
      enabled: true,
      read_pr: fn "10" -> {:ok, %{state: :open, head_ref: "dependent"}} end,
      blockers: fn "10" -> [%{id: "12", pr: %{merged?: true, number: 42, merge_commit_sha: @sha}}] end,
      run: fn ^issue, "dependent", %{number: 42, sha: @sha}, _base -> {:conflict, ["shared.ex"]} end,
      report: fn ^issue, 42, ["shared.ex"] ->
        send(owner, :report_started)
        {:ok, :conflict_reported}
      end
    ]

    pending = RestackScheduler.reconcile(%State{}, [issue], opts)
    [ref] = Map.keys(pending.tracker_tasks)
    receive_barrier({^ref, result})
    assert {:handled, reporting} = TrackerTasks.result(pending, ref, result)
    receive_barrier(:report_started)
    [report_ref] = Map.keys(reporting.tracker_tasks)
    receive_barrier({^report_ref, report_result})
    assert {:handled, _complete} = TrackerTasks.result(reporting, report_ref, report_result)
    assert {:ok, row} = OptimisticLedger.get("10")
    assert row["counters"]["integrations_conflict"] == 1
    assert row["counters"]["integrations_clean"] == 0
    assert_received {:lifecycle, %{event: "blocker_integrate", outcome: "conflict"}}
    refute_received {:lifecycle, %{event: "blocker_integrate"}}
  end

  test "blocker branch pushes count observations once even without an agent report" do
    event = %{topic: "ticket.12.branch.push", ref: "refs/heads/aiur/12-blocker", sha: @sha}
    state = %State{}
    EventTopics.route(state, event)
    EventTopics.route(state, event)
    assert {:ok, row} = OptimisticLedger.get("10")
    assert row["counters"]["pushes_absorbed"] == 1
    assert row["counters"]["integrations_clean"] == 0
    assert row["counters"]["integrations_conflict"] == 0
  end
end
