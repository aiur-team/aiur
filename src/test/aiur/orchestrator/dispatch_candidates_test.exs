defmodule Aiur.Orchestrator.DispatchCandidatesTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.{Hints, Model, Sets}
  alias Aiur.GitHub.{BoundedBlockedBy, OpenIssueSnapshot, ResourceStore}
  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchCandidates, Dispatcher, DispatchPolicy, State, StatusCLI, StatusReport, TrackerTasks}

  setup do
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "sym", max_concurrent_agents: 3)
    ResourceStore.reset()
    OpenIssueSnapshot.reset()
    on_exit(fn -> File.write!(path, original) end)
    :ok
  end

  test "three eligible tickets dispatch before validating any of sixty cached dependency holds" do
    parent = self()
    held = Enum.map(1..60, &candidate(&1, 1))
    ready = [candidate(63, 4), candidate(61, 2), candidate(62, 3)]
    cache_holds(held)

    pending =
      Dispatcher.choose_issues(%State{snapshot_key: self(), max_concurrent_agents: 3, effective_concurrent_agents: 3}, held ++ ready,
        issue_fetcher: fn [id] ->
          send(parent, {:validated, id})
          {:ok, [Enum.find(ready, &(&1.id == id))]}
        end,
        blocked_by_hydrator: fn issue ->
          send(parent, {:hydrated, issue.id})
          assert issue.id in ["3691061", "3691062", "3691063"]
          {:ok, issue}
        end,
        runner: fn issue, _, _ ->
          send(parent, {:started, issue.id})
          :ok
        end
      )

    assert TrackerTasks.running?(pending, {:dispatch, "3691061"})
    final = Enum.reduce(1..3, pending, fn _, state -> apply_result(state) end)
    assert Map.keys(final.running) |> Enum.sort() == ["3691061", "3691062", "3691063"]
    assert final.tracker_tasks == %{}

    assert Enum.map(1..3, fn _ ->
             receive_barrier({:validated, id})
             id
           end) == ["3691061", "3691062", "3691063"]

    for id <- ["3691061", "3691062", "3691063"], do: receive_barrier({:started, ^id})
    refute_received {:validated, _}

    for id <- ["3691061", "3691062", "3691063"] do
      assert_received {:hydrated, ^id}
      assert_received {:hydrated, ^id}
    end

    refute_received {:hydrated, _}
  end

  test "missing or stale evidence keeps priority order and performs no HTTP reads" do
    held = candidate(1, 1)
    ready = candidate(2, 2)
    assert BoundedBlockedBy.fetch(held.id, cache_only: true, request_fun: fn _ -> flunk("cache misses must not fetch") end) == {:error, :cache_miss}
    assert order([ready, held]) == [held, ready]
    cache_holds([held])
    assert order([ready, held]) == [ready, held]

    key = ResourceStore.key(:issue_blocked_by, "owner", "repo", held.id)
    [{^key, entry}] = :ets.lookup(ResourceStore.Table, key)
    :ets.insert(ResourceStore.Table, {key, %{entry | fetched_at_ms: 0}})
    assert order([ready, held]) == [held, ready]
  end

  test "future regression guard: ready p1 without a queue hint precedes p3 and unprioritized tickets" do
    p1 = candidate(701, 1)
    p3 = candidate(702, 3)
    unprioritized = candidate(703, nil)

    assert Enum.map(DispatchCandidates.order([p3, unprioritized, p1], DispatchPolicy.terminal_state_set()), & &1.id) ==
             [p1.id, p3.id, unprioritized.id]
  end

  test "priority precedes work kind while an equal-priority main fixer remains first" do
    configure_ordering()
    fixer = %{candidate(711, 1) | labels: ["main-fix"]}
    feature = %{candidate(712, 2) | labels: ["feature:dispatch"]}
    bug = %{candidate(713, 1) | labels: ["bug"]}
    flake = %{candidate(714, 3) | labels: ["flake"]}
    tooling = %{candidate(715, nil) | title: "Update tooling"}

    assert order([flake, tooling, bug, feature, fixer]) == [fixer, bug, feature, flake, tooling]
    assert order([tooling, flake, bug]) == [bug, flake, tooling]
  end

  test "queue membership, rank and position break priority ties" do
    configure_ordering()
    fixer = %{candidate(721, 4) | labels: ["main-fix"]}
    maintenance = %{candidate(722, 2) | labels: ["bug"]}
    first_feature = %{candidate(723, 2) | labels: ["feature:dispatch"]}
    later_feature = %{candidate(724, 2) | labels: ["build-order"]}
    unqueued_feature = %{candidate(725, 2) | labels: ["build-lane:dispatch"]}
    publish_queue_sets([[maintenance, first_feature], [later_feature]])

    assert order([unqueued_feature, maintenance, later_feature, first_feature, fixer]) ==
             [maintenance, first_feature, later_feature, unqueued_feature, fixer]
  end

  test "each freed slot goes to the priority-one todo ahead of ranked unprioritized work" do
    configure_ordering()
    urgent = %{candidate(731, 1) | labels: ["priority:1", "bug"]}
    normal = for number <- 732..734, do: %{candidate(number, nil) | labels: ["feature:dispatch"]}
    publish_queue_sets([normal])

    for waiting <- [normal, Enum.reverse(normal)] do
      final = dispatch_candidates([hd(waiting), urgent | tl(waiting)], 1)
      assert Map.keys(final.running) == [urgent.id]
    end
  end

  test "a transient priority decline is recorded and retried before the next lower-priority start" do
    urgent = %{candidate(741, 1) | labels: ["priority:1"]}
    [first, second] = normal = [candidate(742, nil), candidate(743, nil)]

    final =
      dispatch_candidates(normal ++ [urgent], 2, capacity_admit_fun: decline_once(urgent.id))

    assert Enum.sort(Map.keys(final.running)) == Enum.sort([first.id, urgent.id])
    refute Map.has_key?(final.running, second.id)

    snapshot = final |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()
    selection = snapshot.capacity[:dispatch_selections]
    urgent_identifier = urgent.identifier
    first_identifier = first.identifier

    assert [
             %{chosen: ^urgent_identifier, skipped: []},
             %{chosen: ^first_identifier, skipped: [%{ticket: ^urgent_identifier, reason: "{:capacity_denied, :temporarily_unavailable}"}]}
           ] = selection

    output = ExUnit.CaptureIO.capture_io(fn -> StatusCLI.agents(fleet_view: {:ok, snapshot, %{status: :current}}) end)
    assert output =~ "chose #{first.identifier} | skipped #{urgent.identifier} ({:capacity_denied, :temporarily_unavailable})"
  end

  test "a transient skip survives an equal-priority start" do
    urgent = candidate(750, 1)
    peer = candidate(751, 1)
    normal = candidate(752, nil)

    final = dispatch_candidates([normal, peer, urgent], 2, capacity_admit_fun: decline_once(urgent.id))

    assert Enum.sort(Map.keys(final.running)) == Enum.sort([urgent.id, peer.id])
  end

  test "a persistent priority-one lease refusal gives every available slot to lower-priority work" do
    urgent = %{candidate(771, 1) | labels: ["priority:1"]}
    normal = Enum.map(772..774, &candidate(&1, nil))
    parent = self()

    final =
      dispatch_candidates(Enum.reverse(normal) ++ [urgent], 3,
        lease_claim_fun: fn issue ->
          send(parent, {:lease_attempt, issue.id})
          if issue.id == urgent.id, do: :held, else: :acquired
        end,
        lease_release_fun: fn _ -> :ok end
      )

    attempts =
      for _ <- 1..6 do
        assert_receive {:lease_attempt, id}, 100
        id
      end

    assert attempts == Enum.flat_map(normal, &[urgent.id, &1.id])
    refute_received {:lease_attempt, _id}
    assert Enum.sort(Map.keys(final.running)) == Enum.map(normal, & &1.id)
    assert final.tracker_tasks == %{}

    assert Enum.map(Enum.reverse(final.dispatch_selections), &{&1.chosen, &1.skipped}) ==
             Enum.map(normal, &{&1.identifier, [%{ticket: urgent.identifier, reason: "shared_lease_held"}]})
  end

  test "a lower-priority automatic recovery cannot overtake an in-flight priority-one todo" do
    urgent = candidate(751, 1)
    recovery = candidate(752, nil)
    state = %State{snapshot_key: self(), max_concurrent_agents: 1, effective_concurrent_agents: 1, last_polled_issues: %{urgent.id => urgent}}

    opts = [
      issue_fetcher: fn [id] -> {:ok, [if(id == urgent.id, do: urgent, else: recovery)]} end,
      blocked_by_hydrator: fn issue -> {:ok, issue} end,
      runner: fn _, _, _ -> :ok end,
      todo_dispatch_tracker: Aiur.Memory.Tracker
    ]

    pending =
      state
      |> Dispatcher.dispatch_issue(recovery, 1, nil, Keyword.put(opts, :automatic_recovery, true))
      |> Dispatcher.choose_issues([urgent], opts)

    after_recovery = apply_result(pending, {:dispatch, recovery.id})
    assert after_recovery.running == %{}
    assert after_recovery.dispatch_declines[recovery.id] == :higher_priority_pending

    final = apply_result(after_recovery, {:dispatch, urgent.id})
    assert Map.keys(final.running) == [urgent.id]
    wait_for_runners(final)
  end

  test "a normal start waits for higher-priority recovery before or during validation" do
    urgent = candidate(761, 1)
    normal = candidate(762, nil)
    state = %State{snapshot_key: self(), max_concurrent_agents: 1, effective_concurrent_agents: 1, last_polled_issues: %{urgent.id => urgent}}

    opts = [
      issue_fetcher: fn [id] -> {:ok, [if(id == urgent.id, do: urgent, else: normal)]} end,
      blocked_by_hydrator: fn issue -> {:ok, issue} end,
      runner: fn _, _, _ -> :ok end,
      todo_dispatch_tracker: Aiur.Memory.Tracker
    ]

    recovery_opts = Keyword.put(opts, :automatic_recovery, true)

    recovery_first =
      state
      |> Dispatcher.dispatch_issue(urgent, 1, nil, recovery_opts)
      |> Dispatcher.choose_issues([normal], opts)

    refute TrackerTasks.running?(recovery_first, {:dispatch, normal.id})
    final = drain(recovery_first)
    assert Map.keys(final.running) == [urgent.id]
    wait_for_runners(final)

    normal_first =
      state
      |> Dispatcher.choose_issues([normal], opts)
      |> Dispatcher.dispatch_issue(urgent, 1, nil, recovery_opts)

    after_normal_validation = apply_result(normal_first, {:dispatch, normal.id})
    assert after_normal_validation.running == %{}

    final = drain(after_normal_validation)
    assert Map.keys(final.running) == [urgent.id]
    wait_for_runners(final)
  end

  test "a priority-one validation timeout unblocks waiting normal dispatch and automatic recovery" do
    urgent = candidate(781, 1)
    normal = candidate(782, nil)
    recovery = candidate(783, nil)
    issues = Map.new([urgent, normal, recovery], &{&1.id, &1})
    urgent_id = urgent.id
    parent = self()
    state = %State{snapshot_key: self(), max_concurrent_agents: 2, effective_concurrent_agents: 2, last_polled_issues: issues}

    opts = [
      issue_fetcher: fn
        [^urgent_id] ->
          send(parent, :urgent_validation_started)

          receive do
            :release_validation -> {:ok, [urgent]}
          after
            10_000 -> {:error, :test_validation_timeout}
          end

        [id] ->
          {:ok, [Map.fetch!(issues, id)]}
      end,
      blocked_by_hydrator: &{:ok, &1},
      runner: fn _, _, _ -> :ok end,
      todo_dispatch_tracker: Aiur.Memory.Tracker
    ]

    recovery_opts = Keyword.put(opts, :automatic_recovery, true)

    pending =
      state
      |> Dispatcher.dispatch_issue(urgent, 1, nil, recovery_opts)
      |> Dispatcher.dispatch_issue(recovery, 1, nil, recovery_opts)

    assert_receive :urgent_validation_started, 1_000
    yielded = apply_result(pending, {:dispatch, recovery.id})
    assert yielded.dispatch_declines[recovery.id] == :higher_priority_pending
    assert yielded.running == %{}

    waiting = Dispatcher.choose_issues(yielded, [normal], opts)
    refute TrackerTasks.running?(waiting, {:dispatch, normal.id})
    assert [{ref, %{key: {:dispatch, ^urgent_id}, timer: timer}}] = Map.to_list(waiting.tracker_tasks)
    remaining_ms = Process.read_timer(timer)
    assert is_integer(remaining_ms) and remaining_ms > 0

    # Deliver the deadline directly so the test exercises the production handler without sleeping.
    assert {:noreply, timed_out} = Aiur.Orchestrator.handle_info({:tracker_task_timeout, ref}, waiting)
    assert timed_out.dispatch_declines[urgent_id] == :tracker_revalidation_failed
    assert TrackerTasks.running?(timed_out, {:dispatch, normal.id})
    resumed = apply_result(timed_out, {:dispatch, normal.id})
    assert Map.keys(resumed.running) == [normal.id]

    # Starting the normal ticket gives the urgent ticket one attempt at the remaining slot.
    assert_receive :urgent_validation_started, 1_000
    assert [{retry_ref, %{key: {:dispatch, ^urgent_id}}}] = Map.to_list(resumed.tracker_tasks)
    assert {:noreply, retry_timed_out} = Aiur.Orchestrator.handle_info({:tracker_task_timeout, retry_ref}, resumed)
    assert retry_timed_out.tracker_tasks == %{}

    final = retry_timed_out |> Dispatcher.dispatch_issue(recovery, 1, nil, recovery_opts) |> apply_result({:dispatch, recovery.id})
    assert Enum.sort(Map.keys(final.running)) == [normal.id, recovery.id]
    assert final.tracker_tasks == %{}
    wait_for_runners(final)
  end

  defp decline_once(urgent_id) do
    fn
      %{id: ^urgent_id} ->
        if Process.get(:priority_attempted) do
          :admit
        else
          Process.put(:priority_attempted, true)
          {:deny, :temporarily_unavailable}
        end

      _ ->
        :admit
    end
  end

  defp dispatch_candidates(issues, slots, opts \\ []) do
    defaults = [
      issue_fetcher: fn [id] -> {:ok, [Enum.find(issues, &(&1.id == id))]} end,
      blocked_by_hydrator: fn issue -> {:ok, issue} end,
      runner: fn _, _, _ -> :ok end,
      todo_dispatch_tracker: Aiur.Memory.Tracker
    ]

    pending =
      Dispatcher.choose_issues(%State{snapshot_key: self(), max_concurrent_agents: slots, effective_concurrent_agents: slots}, issues, Keyword.merge(defaults, opts))

    final = drain(pending)

    wait_for_runners(final)
    final
  end

  defp drain(%State{tracker_tasks: tasks} = state) when map_size(tasks) == 0, do: state
  defp drain(state), do: state |> apply_result() |> drain()

  test "a blocker closed in the current store stops lowering its dependent's priority" do
    held = candidate(1, 1)
    ready = candidate(2, 2)
    cache_holds([held])
    assert order([ready, held]) == [ready, held]
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "100"), %{"number" => 100, "state" => "closed", "labels" => []})
    assert order([ready, held]) == [held, ready]
  end

  defp order(issues) do
    {chain, held, _deferred} = DispatchCandidates.partition(issues, DispatchPolicy.terminal_state_set())
    Enum.map(chain ++ held, & &1.id) |> Enum.map(fn id -> Enum.find(issues, &(&1.id == id)) end)
  end

  defp cache_holds(issues) do
    blocker = %{"number" => 100, "state" => "open", "labels" => [%{"name" => "sym:todo"}]}
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "100"), blocker)
    for issue <- issues, do: ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", issue.id), [blocker])
  end

  defp candidate(number, priority), do: %Issue{id: to_string(3_691_000 + number), identifier: "repo##{3_691_000 + number}", title: "ticket #{number}", state: "todo", priority: priority}

  defp configure_ordering do
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nmerge_policy:\n  main_watch:\n    on_red: dispatch_fixer\nbuild_queue:\n  set_order: ranked\n")
    :ok = Aiur.WorkflowStore.force_reload()
  end

  defp publish_queue_sets(groups) do
    now = DateTime.utc_now()

    queues =
      for {_group, rank} <- Enum.with_index(groups), do: %Model.Queue{id: "dispatch-#{rank}", name: "set #{rank}", rank: rank, kind: :list, root: nil, held: false, generation: 0, created_at: now}

    items =
      for {group, rank} <- Enum.with_index(groups),
          {issue, position} <- Enum.with_index(group),
          do: %Model.Item{issue_id: issue.id, queue_id: "dispatch-#{rank}", position: position, hold: nil, override: nil, promoted_at: now, added_at: now}

    projections = for item <- items, do: %{issue_id: item.issue_id, state: :promoted}
    Hints.publish_sets(Sets.snapshot(%{queues: queues, items: items}, projections, Config.settings!(), nil))
  end

  defp wait_for_runners(state) do
    for {_id, %{ref: ref, pid: pid}} <- state.running, do: receive_barrier({:DOWN, ^ref, :process, ^pid, _reason})
  end

  defp apply_result(state, key) do
    {ref, _job} = Enum.find(state.tracker_tasks, fn {_ref, job} -> job.key == key end)
    receive_barrier({^ref, result})
    {:handled, next} = TrackerTasks.result(state, ref, result)
    next
  end

  defp apply_result(state) do
    [ref] = Map.keys(state.tracker_tasks)
    receive_barrier({^ref, result})
    {:handled, next} = TrackerTasks.result(state, ref, result)
    next
  end
end
