defmodule Aiur.OrchestratorControlRoutingTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.State

  describe "control-status writes" do
    test "worker pause confirmation preserves capabilities and freezes the runtime clock" do
      issue_id = unique_id("control-pause")
      started_at = DateTime.add(DateTime.utc_now(), -30, :second)

      entry =
        running_entry(issue_id,
          started_at: started_at,
          control: %{
            status: :working,
            can_interrupt: true,
            safe_checkpoints: [:notification]
          }
        )

      state = base_state(running: %{issue_id => entry})

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{kind: :usage_limit_exhausted}},
                 state
               )

      paused = Map.fetch!(next.running, issue_id)

      assert paused.control == %{
               status: :paused,
               can_interrupt: true,
               safe_checkpoints: [:notification]
             }

      assert paused.paused_reason == :usage_limit_exhausted
      assert %DateTime{} = paused.paused_at
      assert paused.started_at == started_at
    end

    test "duplicate transition and unknown worker confirmation are exact no-ops" do
      issue_id = unique_id("control-idempotent")
      paused_at = DateTime.add(DateTime.utc_now(), -10, :second)

      entry =
        running_entry(issue_id,
          control: %{status: :paused, can_interrupt: true},
          paused_at: paused_at,
          paused_reason: :operator_pause
        )

      state = base_state(running: %{issue_id => entry})

      assert state ==
               Orchestrator.transition_control_status(
                 state,
                 entry,
                 :paused,
                 "duplicate.confirmation"
               )

      assert {:noreply, ^state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{kind: :usage_limit_exhausted}},
                 state
               )

      assert {:noreply, ^state} =
               Orchestrator.handle_info(
                 {:worker_control_state, "missing-#{issue_id}", :paused, %{kind: :usage_limit_exhausted}},
                 state
               )

      assert state.running[issue_id].paused_at == paused_at
    end

    test "working confirmation thaws the pause clock and preserves unrelated entry data" do
      issue_id = unique_id("control-working")
      started_at = DateTime.add(DateTime.utc_now(), -60, :second)
      paused_at = DateTime.add(DateTime.utc_now(), -5, :second)

      entry =
        running_entry(issue_id,
          control: %{status: :paused, can_interrupt: true},
          started_at: started_at,
          paused_at: paused_at,
          routing_marker: :preserved
        )

      state = base_state(running: %{issue_id => entry})
      before_resume = DateTime.utc_now()

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working},
                 state
               )

      after_resume = DateTime.utc_now()
      working = Map.fetch!(next.running, issue_id)
      shift_seconds = DateTime.diff(working.started_at, started_at, :second)
      earliest_shift = DateTime.diff(before_resume, paused_at, :second)
      latest_shift = DateTime.diff(after_resume, paused_at, :second)

      assert working.control.status == :working
      assert working.control.can_interrupt
      assert working.routing_marker == :preserved
      assert is_nil(working.paused_at)
      assert shift_seconds in earliest_shift..latest_shift
    end
  end

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
          control: %{status: :working, can_interrupt: true}
        )

      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      Process.exit(worker, :boom)
      assert_receive {:DOWN, ^monitor_ref, :process, ^worker, :boom}, 1_000

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :boom},
                 state
               )

      refute Map.has_key?(next.running, issue_id)
      assert %{attempt: 2, error: "agent exited: :boom"} = next.retry_attempts[issue_id]
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

  defp base_state(attrs) do
    struct!(
      State,
      Keyword.merge(
        [
          running: %{},
          claimed: MapSet.new(),
          completed: MapSet.new(),
          retry_attempts: %{},
          max_concurrent_agents: 6,
          agent_totals: nil,
          codex_totals: %{
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            seconds_running: 0
          }
        ],
        attrs
      )
    )
  end

  defp running_entry(issue_id, attrs \\ []) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue_id,
      issue: %Issue{
        id: issue_id,
        identifier: issue_id,
        state: "in-progress",
        title: "Characterize control routing"
      },
      control: %{
        status: :working,
        can_interrupt: true,
        safe_checkpoints: [:notification]
      },
      session_id: "thread-#{issue_id}",
      started_at: DateTime.utc_now()
    }
    |> Map.merge(Map.new(attrs))
  end

  defp live_worker_workspace(issue_id) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "aiur_control_routing_#{issue_id}_#{System.unique_integer([:positive])}"
      )

    marker = Path.join(workspace, "must-survive")
    File.mkdir_p!(workspace)
    File.write!(marker, "present")
    worker = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      File.rm_rf(workspace)
    end)

    {worker, workspace, marker}
  end

  defp supervised_worker do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp cancel_retry_timer(%{timer_ref: timer_ref, retry_token: retry_token}) do
    Process.cancel_timer(timer_ref)

    receive do
      {:retry_issue, _issue_id, ^retry_token} -> :ok
    after
      0 -> :ok
    end
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
