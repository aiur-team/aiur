defmodule Aiur.Orchestrator.Status.CompletedReworkTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport
  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.Orchestrator.HumanReview
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.SnapshotFenceSupport

  test "tracker rework after completed CI wait honors effective capacity" do
    issue = completed_rework_issue("tracker-effective-cap")
    configure_completed_revalidation!([issue], max_concurrent_agents: 3)
    {state, parked_entry, worker, item_ids} = tracker_completed_retention_fixture(issue)

    other =
      "other-effective-cap"
      |> running_entry("MT-OTHER-EFFECTIVE-CAP", :working)
      |> Map.put(:issue, completed_rework_issue("other-effective-cap"))

    state = %{
      state
      | effective_concurrent_agents: 1,
        running: Map.put(state.running, "other-effective-cap", other)
    }

    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  test "tracker rework after completed CI wait honors the state cap" do
    issue = completed_rework_issue("state-cap")

    configure_completed_revalidation!([issue],
      max_concurrent_agents: 3,
      max_concurrent_agents_by_state: %{"rework" => 1}
    )

    {state, parked_entry, worker, item_ids} = tracker_completed_retention_fixture(issue)

    other =
      "other-state-cap"
      |> running_entry("MT-OTHER-STATE-CAP", :working)
      |> Map.put(:issue, completed_rework_issue("other-state-cap"))

    state = %{state | running: Map.put(state.running, "other-state-cap", other)}
    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  test "tracker rework after completed CI wait preserves the worker host gate" do
    issue = completed_rework_issue("host-cap")

    configure_completed_revalidation!([issue],
      max_concurrent_agents: 3,
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    {state, parked_entry, worker, item_ids} =
      tracker_completed_retention_fixture(issue, "worker-a")

    other =
      "other-host-cap"
      |> running_entry("MT-OTHER-HOST-CAP", :working, self(), "worker-a")
      |> Map.put(:issue, completed_rework_issue("other-host-cap"))

    state = %{state | running: Map.put(state.running, "other-host-cap", other)}
    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  test "tracker rework after completed CI wait honors the thrash gate" do
    issue = completed_rework_issue("thrash")
    configure_completed_revalidation!([issue], max_concurrent_agents: 3)
    {state, parked_entry, worker, item_ids} = tracker_completed_retention_fixture(issue)

    thrash_budget = %{
      issue.id => %{
        window_start_ms: System.monotonic_time(:millisecond),
        count: 100
      }
    }

    state = put_in(state.dispatch_recovery.codex_thrash_budget, thrash_budget)

    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  @tag :tmp_dir
  test "tracker rework after completed CI wait honors all-limited model admission", %{tmp_dir: tmp_dir} do
    issue = %{completed_rework_issue("all-limited") | selected_backend: nil}
    workflow_path = Aiur.TestSupport.prepare_workflow_file_path!(tmp_dir)
    Workflow.set_workflow_file_path(workflow_path)

    configure_completed_revalidation!([issue],
      max_concurrent_agents: 3,
      agent_routing: %{"4" => "claude"}
    )

    workflow = File.read!(workflow_path)

    workflow =
      String.replace(
        workflow,
        "  turn_timeout_ms:",
        "  switch_model_on_ratelimit: [claude]\n  turn_timeout_ms:"
      )

    File.write!(workflow_path, workflow)
    WorkflowStore.force_reload()

    File.write!(
      Path.join(Path.dirname(workflow_path), "model-usage.json"),
      Jason.encode!(%{
        "backends" => %{
          "claude" => %{
            "limited" => true,
            "reset_at" => "2999-01-01T00:00:00Z"
          }
        }
      })
    )

    {state, parked_entry, worker, item_ids} = tracker_completed_retention_fixture(issue)
    next = Reconciler.maybe_reactivate_or_refresh(state, issue)

    assert_tracker_completed_preflight_retained(next, parked_entry, worker, item_ids)
  end

  test "tracker rework after completed human review uses hardened replacement" do
    active_issue = completed_rework_issue("human-review-provenance")
    review_issue = %{active_issue | state: "human-review"}
    configure_completed_revalidation!([active_issue], max_concurrent_agents: 3)
    previous_verifier = Application.get_env(:aiur, :human_review_ready_verifier)
    Application.put_env(:aiur, :human_review_ready_verifier, fn _issue_id -> :ok end)

    on_exit(fn ->
      restore_application_env(:human_review_ready_verifier, previous_verifier)
    end)

    {state, _entry, worker, item_ids} = completed_retention_fixture(review_issue)
    parked = HumanReview.maybe_deactivate_human_review_issue(state, review_issue)
    parked_entry = Map.fetch!(parked.running, active_issue.id)

    refute Process.alive?(worker)
    assert parked_entry.control.status == :deactivated
    assert parked_entry.completed_provenance
    assert parked_entry.completion_totals_recorded

    next = Reconciler.maybe_reactivate_or_refresh(parked, active_issue)
    replacement = Map.fetch!(next.running, active_issue.id)

    assert replacement.control.status == :working
    assert is_pid(replacement.pid) and Process.alive?(replacement.pid)
    assert is_reference(replacement.ref)
    assert replacement.worker_host == parked_entry.worker_host
    assert next.queue_store.pending_ids_by_target[active_issue.identifier] == item_ids
  end

  test "tracker poll unpause replaces a dead runner and reports startup through the CLI" do
    active_issue = completed_rework_issue("paused-provenance")
    paused_issue = %{active_issue | paused: true}
    configure_completed_revalidation!([active_issue], max_concurrent_agents: 3)
    {state, _entry, worker, item_ids} = completed_retention_fixture(active_issue)

    paused = PauseResume.pause_issue_for_label_override(state, paused_issue)
    paused_entry = Map.fetch!(paused.running, active_issue.id)

    refute Process.alive?(worker)
    assert paused_entry.control.status == :paused
    assert paused_entry.paused_reason == :label_override
    assert paused_entry.completed_provenance
    assert paused_entry.completion_totals_recorded
    assert paused_entry.pid == nil
    assert paused_entry.ref == nil
    refute_received {:pause_agent, _request_id}

    assert PauseResume.pause_issue_for_label_override(paused, paused_issue) == paused

    orchestrator_pid = Process.whereis(Aiur.Orchestrator)
    original_state = :sys.get_state(orchestrator_pid)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid) do
        generation = SnapshotFenceSupport.fence_snapshot_read_model()
        :sys.replace_state(orchestrator_pid, fn _state -> %{original_state | snapshot_generation: generation} end)
      end
    end)

    next = Reconciler.refresh_running_issue_states(paused)
    replacement = Map.fetch!(next.running, active_issue.id)

    assert replacement.control.status == :working
    assert is_pid(replacement.pid) and Process.alive?(replacement.pid)
    assert is_reference(replacement.ref)
    assert replacement.session_id == nil
    assert next.queue_store.pending_ids_by_target[active_issue.identifier] == item_ids

    # The CLI reads the shared SnapshotStore read model first; fence out any
    # projection an earlier case published so it reads the state injected here.
    generation = SnapshotFenceSupport.fence_snapshot_read_model()
    :sys.replace_state(orchestrator_pid, fn _state -> %{next | snapshot_generation: generation} end)

    assert capture_io(fn -> AgentControlCLI.status() end) =~
             "#{active_issue.identifier} starting #{active_issue.title}"
  end

  test "Executor messages rearm multiple completed runners without returned workers holding slots" do
    orchestrator_name = Module.concat(__MODULE__, :CompletedBatchOperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    freeze_poll_cycle(pid)
    parent = self()

    completed =
      for number <- 1..3, into: %{} do
        issue_id = "issue-completed-#{number}"
        identifier = "MT-COMPLETED-#{number}"
        {:ok, worker} = supervised_operator_message_probe(parent)
        ref = Process.monitor(worker)

        issue = %Issue{
          id: issue_id,
          identifier: identifier,
          state: "rework",
          title: "Completed batch #{number}"
        }

        entry =
          issue_id
          |> running_entry(identifier, :completed, worker)
          |> Map.put(:ref, ref)
          |> Map.put(:issue, issue)

        {issue_id, {identifier, worker, ref, entry}}
      end

    issues = Enum.map(completed, fn {_issue_id, {_identifier, _worker, _ref, entry}} -> entry.issue end)
    release_file = configure_completed_revalidation!(issues)

    on_exit(fn ->
      File.touch(release_file)
      if Process.alive?(pid), do: Process.exit(pid, :normal)

      Enum.each(completed, fn {_issue_id, {_identifier, worker, _ref, _entry}} ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)
      end)
    end)

    :sys.replace_state(pid, fn state ->
      entries =
        Map.new(completed, fn {issue_id, {_identifier, _worker, _ref, entry}} ->
          {issue_id, entry}
        end)

      %{
        state
        | session_max_concurrent_agents: 3,
          effective_concurrent_agents: 1,
          running: entries,
          claimed: MapSet.new(Map.keys(entries))
      }
    end)

    assert %{active: 0, max: 3} = Orchestrator.max_concurrent_agents(orchestrator_name)

    item_ids =
      for {issue_id, {identifier, _worker, _ref, _entry}} <- completed, into: %{} do
        assert {:ok, item_id} =
                 GenServer.call(
                   orchestrator_name,
                   {:send_operator_message, identifier, %{kind: :text, body: "rework #{issue_id}"}},
                   30_000
                 )

        {issue_id, item_id}
      end

    # Revalidation runs in an async tracker task (#3998): the replaced worker's
    # exit is the rearm, and it precedes the state the orchestrator then commits.
    receive_barrier({:DOWN, rearmed_ref, :process, _worker, _reason})
    assert rearmed_ref in Enum.map(completed, fn {_issue_id, {_identifier, _worker, ref, _entry}} -> ref end)

    state = :sys.get_state(pid)
    statuses = Enum.frequencies_by(state.running, fn {_issue_id, entry} -> entry.control.status end)

    assert statuses == %{working: 1, completed: 2}
    refute Map.keys(state.retry_attempts) |> Enum.any?(&Map.has_key?(completed, &1))

    Enum.each(completed, fn {issue_id, {_identifier, worker, old_ref, old_entry}} ->
      expected_body = "rework #{issue_id}"
      assert %{body: %{text: ^expected_body}} = state.queue_store.items[item_ids[issue_id]]

      entry = Map.fetch!(state.running, issue_id)

      if entry.control.status == :working do
        refute Process.alive?(worker)
        assert is_pid(entry.pid) and Process.alive?(entry.pid)
        assert is_reference(entry.ref)
        assert entry.ref != old_ref
      else
        assert entry.pid == worker
        assert entry.ref == old_ref
        assert entry.session_id == old_entry.session_id
        assert entry.worker_host == old_entry.worker_host
        assert MapSet.member?(state.claimed, issue_id)
      end
    end)
  end

  test "freezing the poll cycle fences a stale :run_poll_cycle so no live poll runs" do
    orchestrator_name = Module.concat(__MODULE__, :FrozenPollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    freeze_poll_cycle(pid)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    # The initial tick schedules a one-shot `:run_poll_cycle` (~20ms render
    # delay) that is not token-fenced; the freeze must make it (and any
    # explicit re-send) a no-op. A live poll always schedules a fresh tick via
    # `Lifecycle.schedule_tick/2`, so `tick_timer_ref` staying nil proves no
    # poll ran (and the load envelope was not re-armed).
    send(pid, :run_poll_cycle)
    Process.sleep(50)

    state = :sys.get_state(pid)
    assert state.tick_timer_ref == nil
    assert state.poll_frozen == true
  end
end
