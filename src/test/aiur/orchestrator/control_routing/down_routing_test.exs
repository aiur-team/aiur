Code.require_file("../../../support/control_routing_fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.ControlRouting.DownRoutingTest do
  use Aiur.TestSupport

  import Aiur.TestSupport.ControlRoutingFixture

  alias Aiur.Orchestrator.PauseResume

  describe ":DOWN routing" do
    test "a stale monitor ref leaves all orchestrator state untouched" do
      issue_id = unique_id("down-stale")
      state = base_state(running: %{issue_id => running_entry(issue_id)})

      assert {:noreply, ^state} =
               Orchestrator.handle_info(
                 {:DOWN, make_ref(), :process, self(), :normal},
                 state
               )
    end

    test "a real completed child exiting normally parks its identity without a retry" do
      issue_id = unique_id("down-completed")
      {:ok, worker} = supervised_worker()
      monitor_ref = Process.monitor(worker)

      entry =
        running_entry(issue_id,
          pid: worker,
          ref: monitor_ref,
          worker_host: "worker-a",
          workspace_path: "/workspace/#{issue_id}",
          control: %{status: :completed, can_interrupt: true}
        )

      state =
        base_state(
          running: %{issue_id => entry},
          claimed: MapSet.new([issue_id]),
          retry_attempts: %{issue_id => %{attempt: 4}}
        )

      send(worker, :stop)
      assert_receive {:DOWN, ^monitor_ref, :process, ^worker, :normal}, 1_000

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :normal},
                 state
               )

      parked = Map.fetch!(next.running, issue_id)
      assert parked.pid == nil
      assert parked.ref == nil
      assert parked.control.status == :completed
      assert parked.session_id == entry.session_id
      assert parked.worker_host == "worker-a"
      assert parked.workspace_path == "/workspace/#{issue_id}"
      assert MapSet.member?(next.claimed, issue_id)
      assert MapSet.member?(next.completed, issue_id)
      refute Map.has_key?(next.retry_attempts, issue_id)

      assert {:noreply, ^next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :normal},
                 next
               )
    end

    test "a real pre-completion child exiting abnormally schedules a failure retry" do
      issue_id = unique_id("down-real-crash")
      {:ok, worker} = supervised_worker()
      monitor_ref = Process.monitor(worker)

      entry =
        running_entry(issue_id,
          pid: worker,
          ref: monitor_ref,
          retry_attempt: 1,
          control: %{
            status: :working,
            can_interrupt: true,
            safe_checkpoints: [:notification],
            application_confirmation: :confirmed,
            generation: 101,
            version: 0
          }
        )

      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      {{:ok, request_id}, accepted_state} = PauseResume.pause_agent_reply(state, issue_id)
      assert %{status: :accepted} = accepted_state.control_lifecycle.records[request_id]

      Process.exit(worker, :boom)
      assert_receive {:DOWN, ^monitor_ref, :process, ^worker, :boom}, 1_000

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :boom},
                 accepted_state
               )

      refute Map.has_key?(next.running, issue_id)
      assert %{attempt: 2, error: "agent exited: :boom"} = next.retry_attempts[issue_id]
      assert %{status: :expired, expiry: %{reason: :worker_unavailable}} = next.control_lifecycle.records[request_id]
      cancel_retry_timer(next.retry_attempts[issue_id])
    end

    test "normal exit completes and schedules continuation without teardown" do
      issue_id = unique_id("down-normal")
      {worker, workspace, marker} = live_worker_workspace(issue_id)
      monitor_ref = make_ref()
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)

      entry =
        running_entry(issue_id,
          pid: worker,
          ref: monitor_ref,
          started_at: started_at,
          retry_attempt: 7,
          worker_host: "worker-a",
          workspace_path: workspace
        )

      state =
        base_state(
          running: %{issue_id => entry},
          claimed: MapSet.new([issue_id]),
          retry_attempts: %{issue_id => %{attempt: 7}},
          agent_totals: %{
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            seconds_running: 3
          }
        )

      before_down = DateTime.utc_now()

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :normal},
                 state
               )

      after_down = DateTime.utc_now()
      refute Map.has_key?(next.running, issue_id)
      assert MapSet.member?(next.completed, issue_id)
      assert MapSet.member?(next.claimed, issue_id)

      earliest_total = 3 + DateTime.diff(before_down, started_at, :second)
      latest_total = 3 + DateTime.diff(after_down, started_at, :second)
      assert next.agent_totals.seconds_running in earliest_total..latest_total

      assert %{
               attempt: 1,
               identifier: ^issue_id,
               error: nil,
               retry_poll_failures: 0,
               worker_host: "worker-a",
               workspace_path: ^workspace,
               retry_token: retry_token,
               timer_ref: timer_ref
             } = next.retry_attempts[issue_id]

      assert is_reference(retry_token)
      assert is_reference(timer_ref)
      assert Process.alive?(worker)
      assert File.exists?(marker)

      cancel_retry_timer(next.retry_attempts[issue_id])
    end

    test "abnormal exit schedules the next failure attempt without teardown" do
      issue_id = unique_id("down-crash")
      {worker, workspace, marker} = live_worker_workspace(issue_id)
      monitor_ref = make_ref()
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)

      entry =
        running_entry(issue_id,
          pid: worker,
          ref: monitor_ref,
          started_at: started_at,
          retry_attempt: 2,
          worker_host: "worker-b",
          workspace_path: workspace
        )

      state =
        base_state(
          running: %{issue_id => entry},
          claimed: MapSet.new([issue_id]),
          completed: MapSet.new(["already-complete"]),
          agent_totals: %{
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            seconds_running: 2
          }
        )

      before_down = DateTime.utc_now()

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :boom},
                 state
               )

      after_down = DateTime.utc_now()
      refute Map.has_key?(next.running, issue_id)
      refute MapSet.member?(next.completed, issue_id)
      assert next.completed == MapSet.new(["already-complete"])
      assert MapSet.member?(next.claimed, issue_id)

      earliest_total = 2 + DateTime.diff(before_down, started_at, :second)
      latest_total = 2 + DateTime.diff(after_down, started_at, :second)
      assert next.agent_totals.seconds_running in earliest_total..latest_total

      assert %{
               attempt: 3,
               identifier: ^issue_id,
               error: "agent exited: :boom",
               retry_poll_failures: 0,
               worker_host: "worker-b",
               workspace_path: ^workspace,
               retry_token: retry_token,
               timer_ref: timer_ref
             } = next.retry_attempts[issue_id]

      assert is_reference(retry_token)
      assert is_reference(timer_ref)
      assert Process.alive?(worker)
      assert File.exists?(marker)

      cancel_retry_timer(next.retry_attempts[issue_id])
    end
  end
end
