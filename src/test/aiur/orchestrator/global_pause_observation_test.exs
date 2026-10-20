defmodule Aiur.Orchestrator.GlobalPauseObservationTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport, only: [wait_for_snapshot: 3, wait_for_published_snapshot: 3, running_entry: 4]

  alias Aiur.{Issue, Orchestrator, Workflow}
  alias Aiur.Orchestrator.GlobalPause
  alias Aiur.Workspace.Ownership

  test "global pause refreshes real poll cycles and records worker completion" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["in-progress"], poll_interval_seconds: 1)
    Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "4236", identifier: "MEMORY-4236", title: "Paused poll", state: "in-progress"}])
    previous_store = Application.get_env(:aiur, :global_pause_store_path)
    Application.put_env(:aiur, :global_pause_store_path, Aiur.TestSupport.tmp_root!("gp-live-poll") <> ".json")

    on_exit(fn ->
      Aiur.OrchestratorStatusSupport.restore_application_env(:global_pause_store_path, previous_store)
      Application.delete_env(:aiur, :memory_tracker_issues)
    end)

    name = Module.concat(__MODULE__, :LivePausedPollOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    issue_id = "4236"
    identifier = "MEMORY-#{issue_id}"
    worker = spawn(fn -> poll_worker(pid, issue_id) end)
    worker_ref = Process.monitor(worker)
    parent = self()

    owner =
      spawn(fn ->
        send(
          parent,
          {:lease, Ownership.claim(identifier, Ownership.Registry, holder: %{issue_id: issue_id, update_recipient: pid, update_recipient_name: name, worker_host: nil})}
        )

        Process.sleep(:infinity)
      end)

    assert_receive {:lease, {:ok, lease}}, 2_000
    assert {:ok, %{phase: :active}} = Ownership.activate(lease)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      Ownership.release(lease)
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      entry =
        running_entry(issue_id, identifier, :working, worker)
        |> Map.put(:ref, worker_ref)
        |> put_in([:issue, Access.key(:tracker_identity)], nil)

      %{
        state
        | running: %{issue_id => entry},
          claimed: MapSet.new([issue_id]),
          tracker_observations: %{issue_id => DateTime.utc_now()},
          candidate_snapshot_fresh?: true,
          snapshot_ready?: true,
          poll_interval_ms: 1_000,
          poll_cycles_completed: 1,
          last_polled_issues: %{}
      }
    end)

    before = :sys.get_state(pid).poll_cycles_completed
    assert {:ok, %{globally_paused: true}} = GlobalPause.set_global_pause(name, true, "test")

    assert %{polling: %{checking?: false}} =
             wait_for_snapshot(
               pid,
               fn snapshot ->
                 snapshot.polling.checking? == false and :sys.get_state(pid).poll_cycles_completed > before and
                   get_in(:sys.get_state(pid).running, [issue_id, :control, :status]) == :working
               end,
               2_000
             )

    assert {:current, %{running: running, observations: %{fleet: %{age_ms: fleet_age}}}, _freshness} =
             wait_for_published_snapshot(name, fn _snapshot -> true end, 2_000)

    assert fleet_age < 2_000
    assert Enum.any?(running, &(&1.issue_id == issue_id))
    send(worker, :finish)

    wait_for_snapshot(pid, fn _snapshot -> get_in(:sys.get_state(pid).running, [issue_id, :control, :status]) == :completed end, 2_000)
    assert get_in(:sys.get_state(pid).running, [issue_id, :control, :status]) == :completed
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2_000

    assert {:current, %{running: running}, _} =
             wait_for_published_snapshot(name, fn snapshot -> Enum.any?(snapshot.running, &(&1.issue_id == issue_id and &1.work_state == :completed)) end, 2_000)

    assert Enum.any?(running, &(&1.issue_id == issue_id and &1.work_state == :completed))
  end

  defp poll_worker(orchestrator, issue_id) do
    receive do
      {:pause_agent, request_id, generation} ->
        send(orchestrator, {:worker_control_state, issue_id, :paused, %{reason: :global_pause, request_id: request_id, generation: generation}})
        poll_worker(orchestrator, issue_id)

      :finish ->
        send(orchestrator, {:worker_control_state, issue_id, :completed})
    end
  end
end
