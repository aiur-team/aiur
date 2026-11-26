defmodule Aiur.Orchestrator.ResumeControlSlowTrackerRegressionTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, DispatchBudgetStore, Issue}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Dispatcher, PauseResume}
  import Aiur.SnapshotFenceSupport, only: [fence_snapshot_read_model: 0]
  import Aiur.TrackerTaskDrainSupport, only: [drain_tracker_tasks: 3, drain_tracker_tasks: 4]
  @probe_timeout_ms 15_000

  defmodule SlowTrackerClient do
    def fetch_issue_states_by_ids(ids), do: await_reply(:fetch, ids)
    def update_issue_state(identifier, state), do: await_reply(:update, [identifier, state])
    def remove_label(identifier, label), do: await_reply(:remove, [identifier, label])

    defp await_reply(operation, args) do
      send(
        Application.fetch_env!(:aiur, :slow_control_tracker_owner),
        {:tracker_waiting, self(), operation, args}
      )

      receive do
        {:tracker_reply, result} -> result
      after
        30_000 -> {:error, :test_tracker_timeout}
      end
    end
  end

  setup %{test: test_name} do
    pid = Process.whereis(Orchestrator)
    original_state = :sys.get_state(pid, @probe_timeout_ms)

    # Control queries read the SnapshotStore read model first, keyed by the
    # shared registered name, so a projection an earlier module published would
    # hide the running entries these cases inject. A new generation fences
    # in-flight projections, and the Orchestrator adopts it (as in #2719).
    snapshot_generation = fence_snapshot_read_model()

    # Poll reads run in tracker tasks. A poll an earlier case started can still
    # be held by that case's slow tracker double; its late result would apply in
    # the owner during this case and stall the control budget. Freeze
    # polling and cancel in-flight tracker work before each case.
    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | poll_frozen: true,
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: nil
      }
    end)

    drain_tracker_tasks(pid, 15_000, to_string(test_name), original_state.tracker_tasks)

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | snapshot_generation: snapshot_generation,
          running: %{},
          last_polled_issues: %{},
          retry_attempts: %{},
          claimed: MapSet.new(),
          blocked_ticket_ids: nil,
          control_lifecycle: %Aiur.Orchestrator.ControlLifecycle{},
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: nil,
          poll_check_in_progress: false,
          poll_frozen: true,
          candidate_snapshot_fresh?: true,
          snapshot_ready?: false,
          globally_paused: false,
          dispatch_recovery: %{
            state.dispatch_recovery
            | workspace_ownership: %{waits: %{}, ready: %{}}
          }
      }
    end)

    on_exit(fn ->
      if Process.alive?(pid) do
        snapshot_generation = fence_snapshot_read_model()
        drain_tracker_tasks(pid, 15_000, to_string(test_name))

        :sys.replace_state(pid, fn _state ->
          %{original_state | snapshot_generation: snapshot_generation, tracker_tasks: %{}}
        end)
      end
    end)

    {:ok, orchestrator: pid}
  end

  @control_budget_ms 5_000
  @tracker_hold_ms @control_budget_ms + 1_000

  defp use_slow_tracker! do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      max_concurrent_agents: 4,
      max_dispatches_per_ticket: 10
    )

    for {key, value} <- [
          github_client_module: SlowTrackerClient,
          slow_control_tracker_owner: self(),
          control_api_call_timeout_ms: @control_budget_ms
        ] do
      previous = Application.get_env(:aiur, key)
      Application.put_env(:aiur, key, value)

      on_exit(fn -> restore_application_env(key, previous) end)
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, previous), do: Application.put_env(:aiur, key, previous)

  defp assert_tracker_does_not_hold_control(task, orchestrator) do
    assert Task.yield(task, @tracker_hold_ms) == nil
    assert is_map(:sys.get_state(orchestrator, @probe_timeout_ms))
    assert is_list(Orchestrator.status(Orchestrator, @probe_timeout_ms))
  end

  defp idle_issue(id),
    do: %Issue{
      id: id,
      identifier: id,
      title: "Issue #{id}",
      state: "In Progress",
      labels: ["agent:in-progress"]
    }

  defp working_entry(issue_id, identifier, pid) do
    %{
      pid: pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        state: "In Progress",
        title: "Issue #{identifier}",
        tracker_identity: %Aiur.TrackerIdentity{
          version: 1,
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: "I_kwDO#{issue_id}",
          identifier: identifier,
          reason: nil
        }
      },
      control: %{
        can_interrupt: true,
        safe_checkpoints: [:notification],
        status: :working,
        generation: 1,
        version: 1,
        application_confirmation: :confirmed
      },
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp worker(issue_id, parent) do
    orchestrator = Process.whereis(Orchestrator)

    spawn_link(fn ->
      receive do
        {:pause_agent, request_id, generation} ->
          send(parent, {:worker_got, :pause, request_id})

          receive do
            :ack_pause ->
              send(
                orchestrator,
                {:worker_control_state, issue_id, :paused, %{request_id: request_id, generation: generation}}
              )

            :hold_pause ->
              :ok
          end

          worker_loop(orchestrator, issue_id, parent)

        {:resume_agent, request_id, generation} ->
          send(parent, {:worker_got, :resume, request_id})

          send(
            orchestrator,
            {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: generation}}
          )

          worker_loop(orchestrator, issue_id, parent)

        :stop ->
          :ok
      after
        10_000 -> :timeout
      end
    end)
  end

  defp worker_loop(_orchestrator, issue_id, parent), do: worker(issue_id, parent)

  defp with_resume_confirm_timeout(timeout_ms, fun) do
    Application.put_env(:aiur, :agent_control_cli_resume_confirm_timeout_ms, timeout_ms)
    fun.()
  after
    Application.delete_env(:aiur, :agent_control_cli_resume_confirm_timeout_ms)
  end

  describe "slow tracker control commands" do
    test "reset-budget fetch and state restore outlive the control timeout and the CLI confirms a durable reset",
         %{orchestrator: pid} do
      use_slow_tracker!()
      issue = %{idle_issue("3033") | state: "error", labels: ["agent:error"]}
      :ok = DispatchBudgetStore.put_lifetime(issue.id, 10)

      :sys.replace_state(pid, fn state ->
        put_in(state.dispatch_recovery.codex_thrash_budget, %{
          issue.id => %{lifetime: 10, count: 0, tripped: :lifetime}
        })
      end)

      command =
        Task.async(fn ->
          capture_io(fn -> AgentControlCLI.reset_budget([issue.identifier]) end)
        end)

      receive_barrier({:tracker_waiting, caller, :fetch, ["3033"]})
      on_exit(fn -> send(caller, {:tracker_reply, {:error, :test_cleanup}}) end)
      assert caller == command.pid
      assert_tracker_does_not_hold_control(command, pid)
      assert {:ok, 10} = DispatchBudgetStore.lifetime(issue.id)
      send(caller, {:tracker_reply, {:ok, [issue]}})

      receive_barrier({:tracker_waiting, ^caller, :update, ["3033", "todo"]})
      assert_tracker_does_not_hold_control(command, pid)
      assert {:ok, 0} = DispatchBudgetStore.lifetime(issue.id)
      bystander = spawn_link(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(pid, fn state ->
        put_in(state.running["53"], working_entry("53", "53", bystander))
      end)

      send(caller, {:tracker_reply, :ok})

      output = Task.await(command)
      assert output =~ "aiur: lifetime dispatch budget reset for #3033"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      assert :none = Dispatcher.dispatch_latch_status(:sys.get_state(pid), issue.id)
      assert %Issue{state: "todo"} = :sys.get_state(pid).last_polled_issues[issue.id]
      assert %{"53" => %{pid: ^bystander}} = :sys.get_state(pid).running
    end

    test "running resume waits for pause-label removal outside the orchestrator and reaches the worker",
         %{orchestrator: pid} do
      use_slow_tracker!()
      agent = worker("44", self())
      entry = working_entry("44", "44", agent)

      entry = %{
        entry
        | issue: %{entry.issue | paused: true, labels: ["agent:in-progress", "agent:paused"]},
          control: %{entry.control | status: :paused}
      }

      :sys.replace_state(pid, fn state -> put_in(state.running["44"], entry) end)

      command =
        Task.async(fn ->
          with_resume_confirm_timeout(3_000, fn ->
            capture_io(fn -> AgentControlCLI.resume(["44"]) end)
          end)
        end)

      receive_barrier({:tracker_waiting, caller, :remove, ["44", "agent:paused"]})
      on_exit(fn -> send(caller, {:tracker_reply, {:error, :test_cleanup}}) end)
      assert caller == command.pid
      assert_tracker_does_not_hold_control(command, pid)
      send(caller, {:tracker_reply, :ok})

      receive_barrier({:worker_got, :resume, _request})
      output = Task.await(command)
      assert output =~ "aiur: resumed #44"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      assert get_in(:sys.get_state(pid).running, ["44", :control, :status]) == :working
    end

    test "queued resume keeps fetch, remove, refetch off the mailbox and revalidates a new claim before dispatch",
         %{orchestrator: pid} do
      use_slow_tracker!()
      issue = %{idle_issue("3101") | paused: true, labels: ["agent:in-progress", "agent:paused"]}
      :sys.replace_state(pid, fn state -> put_in(state.last_polled_issues[issue.id], issue) end)

      command = Task.async(fn -> PauseResume.resume_agent(pid, issue.identifier) end)
      receive_barrier({:tracker_waiting, caller, :fetch, ["3101"]})
      on_exit(fn -> send(caller, {:tracker_reply, {:error, :test_cleanup}}) end)
      assert caller == command.pid
      assert_tracker_does_not_hold_control(command, pid)
      send(caller, {:tracker_reply, {:ok, [issue]}})

      receive_barrier({:tracker_waiting, ^caller, :remove, ["3101", "agent:paused"]})
      assert_tracker_does_not_hold_control(command, pid)
      send(caller, {:tracker_reply, :ok})

      receive_barrier({:tracker_waiting, ^caller, :fetch, ["3101"]})
      assert_tracker_does_not_hold_control(command, pid)

      :sys.replace_state(pid, fn state ->
        %{state | claimed: MapSet.put(state.claimed, issue.id)}
      end)

      send(
        caller,
        {:tracker_reply, {:ok, [%{issue | paused: false, labels: ["agent:in-progress"]}]}}
      )

      assert {:error, :already_claimed} = Task.await(command)
      assert :sys.get_state(pid).running == %{}
      assert MapSet.member?(:sys.get_state(pid).claimed, issue.id)
      assert {:ok, 0} = DispatchBudgetStore.lifetime(issue.id)
    end

    test "completed resume revalidation waits outside the mailbox and retains its policy refusal",
         %{orchestrator: pid} do
      use_slow_tracker!()
      entry = working_entry("44", "44", nil)

      entry =
        entry |> put_in([:control, :status], :completed) |> Map.put(:completed_provenance, true)

      :sys.replace_state(pid, fn state -> put_in(state.running["44"], entry) end)
      command = Task.async(fn -> PauseResume.resume_agent(pid, "44") end)
      receive_barrier({:tracker_waiting, caller, :fetch, ["44"]})
      on_exit(fn -> send(caller, {:tracker_reply, {:error, :test_cleanup}}) end)
      assert caller == command.pid
      assert_tracker_does_not_hold_control(command, pid)

      send(
        caller,
        {:tracker_reply, {:ok, [%{entry.issue | state: "done", labels: ["agent:done"]}]}}
      )

      assert {:error, {:redispatch_deferred, {:not_dispatchable, :terminal_state}}} =
               Task.await(command)

      assert :sys.get_state(pid).running["44"].issue.state == "done"
      assert :sys.get_state(pid).running["44"].control.status == :completed
      assert {:ok, 0} = DispatchBudgetStore.lifetime("44")
    end

    test "queued resume rechecks a global hold after tracker I/O", %{orchestrator: pid} do
      use_slow_tracker!()
      issue = idle_issue("3101")
      :sys.replace_state(pid, fn state -> put_in(state.last_polled_issues[issue.id], issue) end)
      command = Task.async(fn -> PauseResume.resume_agent(pid, issue.identifier) end)
      receive_barrier({:tracker_waiting, caller, :fetch, ["3101"]})
      on_exit(fn -> send(caller, {:tracker_reply, {:error, :test_cleanup}}) end)
      assert caller == command.pid
      assert_tracker_does_not_hold_control(command, pid)
      :sys.replace_state(pid, fn state -> %{state | globally_paused: true} end)
      send(caller, {:tracker_reply, {:ok, [issue]}})

      assert {:error, :globally_paused} = Task.await(command)
      refute_received {:tracker_waiting, _, :remove, _}
      assert :sys.get_state(pid).running == %{}
    end
  end
end
