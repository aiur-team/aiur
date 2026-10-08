defmodule Aiur.Orchestrator.ResumeControlRegressionTest do
  # #2699 regressions against the live application Orchestrator:
  #
  # * `aiur resume 52` on an idle ticket held by an open blocking Decision
  #   crashed the Orchestrator with a FunctionClauseError. The restart threw
  #   away the agent registry, so a live worker ran on untracked.
  # * `aiur pause 52` then `aiur resume 52` printed "already running #52"
  #   while the worker stayed paused, because the CLI answered from a
  #   read-model row that still said `:running`.
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, DispatchBudgetStore, Issue}
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.{ControlLifecycle, Dispatcher, PauseResume}
  alias Aiur.TrackerIdentity

  import Aiur.SnapshotFenceSupport, only: [fence_snapshot_read_model: 0]

  defmodule SlowTrackerClient do
    def fetch_issue_states_by_ids(ids), do: await_reply(:fetch, ids)
    def update_issue_state(identifier, state), do: await_reply(:update, [identifier, state])
    def remove_label(identifier, label), do: await_reply(:remove, [identifier, label])

    defp await_reply(operation, args) do
      send(Application.fetch_env!(:aiur, :slow_control_tracker_owner), {:tracker_waiting, self(), operation, args})

      receive do
        {:tracker_reply, result} -> result
      after
        5_000 -> {:error, :test_tracker_timeout}
      end
    end
  end

  setup do
    pid = Process.whereis(Orchestrator)
    original_state = :sys.get_state(pid)

    # Control queries read the SnapshotStore read model first, keyed by the
    # shared registered name, so a projection an earlier module published would
    # hide the running entries these cases inject. A new generation fences
    # in-flight projections, and the Orchestrator adopts it (as in #2719).
    snapshot_generation = fence_snapshot_read_model()

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | snapshot_generation: snapshot_generation,
          running: %{},
          last_polled_issues: %{},
          claimed: MapSet.new(),
          blocked_ticket_ids: nil,
          control_lifecycle: %ControlLifecycle{},
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: nil,
          poll_check_in_progress: false,
          poll_frozen: true,
          candidate_snapshot_fresh?: true,
          snapshot_ready?: false,
          globally_paused: false,
          dispatch_recovery: %{state.dispatch_recovery | workspace_ownership: %{waits: %{}, ready: %{}}}
      }
    end)

    on_exit(fn ->
      if Process.alive?(pid) do
        snapshot_generation = fence_snapshot_read_model()
        :sys.replace_state(pid, fn _state -> %{original_state | snapshot_generation: snapshot_generation} end)
      end
    end)

    {:ok, orchestrator: pid}
  end

  defp use_memory_tracker!(issues) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 4)
    previous = Application.get_env(:aiur, :memory_tracker_issues)
    Application.put_env(:aiur, :memory_tracker_issues, issues)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:aiur, :memory_tracker_issues),
        else: Application.put_env(:aiur, :memory_tracker_issues, previous)
    end)
  end

  defp idle_issue(id) do
    %Issue{id: id, identifier: id, title: "Issue #{id}", state: "In Progress", labels: ["agent:in-progress"]}
  end

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
        tracker_identity: %TrackerIdentity{
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

  # Stands in for a live worker. It acknowledges a pause only when told to,
  # which lets a case hold the pause pending, and always acknowledges a resume.
  defp worker(issue_id, parent) do
    orchestrator = Process.whereis(Orchestrator)

    spawn_link(fn -> worker_loop(orchestrator, issue_id, parent) end)
  end

  defp worker_loop(orchestrator, issue_id, parent) do
    receive do
      {:pause_agent, request_id, generation} ->
        send(parent, {:worker_got, :pause, request_id})

        receive do
          :ack_pause -> send(orchestrator, {:worker_control_state, issue_id, :paused, %{request_id: request_id, generation: generation}})
          :hold_pause -> :ok
        end

        worker_loop(orchestrator, issue_id, parent)

      {:resume_agent, request_id, generation} ->
        send(parent, {:worker_got, :resume, request_id})
        send(orchestrator, {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: generation}})
        worker_loop(orchestrator, issue_id, parent)

      :stop ->
        :ok
    after
      10_000 -> :timeout
    end
  end

  defp with_resume_confirm_timeout(timeout_ms, fun) do
    Application.put_env(:aiur, :agent_control_cli_resume_confirm_timeout_ms, timeout_ms)
    fun.()
  after
    Application.delete_env(:aiur, :agent_control_cli_resume_confirm_timeout_ms)
  end

  defp use_slow_tracker! do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", max_concurrent_agents: 4, max_dispatches_per_ticket: 10)

    for {key, value} <- [github_client_module: SlowTrackerClient, slow_control_tracker_owner: self(), control_api_call_timeout_ms: 100] do
      previous = Application.get_env(:aiur, key)
      Application.put_env(:aiur, key, value)

      on_exit(fn ->
        if is_nil(previous), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, previous)
      end)
    end
  end

  defp assert_tracker_does_not_hold_control(task, orchestrator) do
    # Hold the real tracker call beyond the control budget, then exercise the
    # mailbox rather than accepting a cached status projection as responsiveness.
    assert Task.yield(task, 200) == nil
    assert is_map(:sys.get_state(orchestrator, 1_000))
    assert is_list(Orchestrator.status(Orchestrator, 1_000))
  end

  describe "slow tracker control commands" do
    test "reset-budget fetch and state restore outlive the control timeout and the CLI confirms a durable reset", %{orchestrator: pid} do
      use_slow_tracker!()
      issue = %{idle_issue("3033") | state: "error", labels: ["agent:error"]}
      :ok = DispatchBudgetStore.put_lifetime(issue.id, 10)

      :sys.replace_state(pid, fn state ->
        put_in(state.dispatch_recovery.codex_thrash_budget, %{issue.id => %{lifetime: 10, count: 0, tripped: :lifetime}})
      end)

      command = Task.async(fn -> capture_io(fn -> AgentControlCLI.reset_budget([issue.identifier]) end) end)
      receive_barrier({:tracker_waiting, caller, :fetch, ["3033"]})
      on_exit(fn -> send(caller, {:tracker_reply, {:error, :test_cleanup}}) end)
      assert_tracker_does_not_hold_control(command, pid)
      assert {:ok, 10} = DispatchBudgetStore.lifetime(issue.id)
      send(caller, {:tracker_reply, {:ok, [issue]}})

      receive_barrier({:tracker_waiting, ^caller, :update, ["3033", "todo"]})
      assert_tracker_does_not_hold_control(command, pid)
      assert {:ok, 0} = DispatchBudgetStore.lifetime(issue.id)
      bystander = spawn_link(fn -> Process.sleep(:infinity) end)
      :sys.replace_state(pid, fn state -> put_in(state.running["53"], working_entry("53", "53", bystander)) end)
      send(caller, {:tracker_reply, :ok})

      output = Task.await(command)
      assert output =~ "aiur: lifetime dispatch budget reset for #3033"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      assert :none = Dispatcher.dispatch_latch_status(:sys.get_state(pid), issue.id)
      assert %Issue{state: "todo"} = :sys.get_state(pid).last_polled_issues[issue.id]
      assert %{"53" => %{pid: ^bystander}} = :sys.get_state(pid).running
    end

    test "running resume waits for pause-label removal outside the orchestrator and reaches the worker", %{orchestrator: pid} do
      use_slow_tracker!()
      agent = worker("44", self())
      entry = working_entry("44", "44", agent)
      entry = %{entry | issue: %{entry.issue | paused: true, labels: ["agent:in-progress", "agent:paused"]}, control: %{entry.control | status: :paused}}
      :sys.replace_state(pid, fn state -> put_in(state.running["44"], entry) end)

      command = Task.async(fn -> with_resume_confirm_timeout(3_000, fn -> capture_io(fn -> AgentControlCLI.resume(["44"]) end) end) end)
      receive_barrier({:tracker_waiting, caller, :remove, ["44", "agent:paused"]})
      on_exit(fn -> send(caller, {:tracker_reply, {:error, :test_cleanup}}) end)
      assert_tracker_does_not_hold_control(command, pid)
      send(caller, {:tracker_reply, :ok})

      receive_barrier({:worker_got, :resume, _request})
      output = Task.await(command)
      assert output =~ "aiur: resumed #44"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      assert get_in(:sys.get_state(pid).running, ["44", :control, :status]) == :working
    end

    test "queued resume keeps fetch, remove, refetch off the mailbox and revalidates a new claim before dispatch", %{orchestrator: pid} do
      use_slow_tracker!()
      issue = %{idle_issue("3101") | paused: true, labels: ["agent:in-progress", "agent:paused"]}
      :sys.replace_state(pid, fn state -> put_in(state.last_polled_issues[issue.id], issue) end)

      command = Task.async(fn -> PauseResume.resume_agent(pid, issue.identifier) end)
      receive_barrier({:tracker_waiting, caller, :fetch, ["3101"]})
      on_exit(fn -> send(caller, {:tracker_reply, {:error, :test_cleanup}}) end)
      assert_tracker_does_not_hold_control(command, pid)
      send(caller, {:tracker_reply, {:ok, [issue]}})

      receive_barrier({:tracker_waiting, ^caller, :remove, ["3101", "agent:paused"]})
      assert_tracker_does_not_hold_control(command, pid)
      send(caller, {:tracker_reply, :ok})

      receive_barrier({:tracker_waiting, ^caller, :fetch, ["3101"]})
      assert_tracker_does_not_hold_control(command, pid)
      :sys.replace_state(pid, fn state -> %{state | claimed: MapSet.put(state.claimed, issue.id)} end)
      send(caller, {:tracker_reply, {:ok, [%{issue | paused: false, labels: ["agent:in-progress"]}]}})

      assert {:error, :already_claimed} = Task.await(command)
      assert :sys.get_state(pid).running == %{}
      assert MapSet.member?(:sys.get_state(pid).claimed, issue.id)
      assert {:ok, 0} = DispatchBudgetStore.lifetime(issue.id)
    end

    test "completed resume revalidation waits outside the mailbox and retains its policy refusal", %{orchestrator: pid} do
      use_slow_tracker!()
      entry = working_entry("44", "44", nil)
      entry = entry |> put_in([:control, :status], :completed) |> Map.put(:completed_provenance, true)
      :sys.replace_state(pid, fn state -> put_in(state.running["44"], entry) end)
      command = Task.async(fn -> PauseResume.resume_agent(pid, "44") end)
      receive_barrier({:tracker_waiting, caller, :fetch, ["44"]})
      on_exit(fn -> send(caller, {:tracker_reply, {:error, :test_cleanup}}) end)
      assert_tracker_does_not_hold_control(command, pid)
      send(caller, {:tracker_reply, {:ok, [%{entry.issue | state: "done", labels: ["agent:done"]}]}})

      assert {:error, {:redispatch_deferred, {:not_dispatchable, :terminal_state}}} = Task.await(command)
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
      assert_tracker_does_not_hold_control(command, pid)
      :sys.replace_state(pid, fn state -> %{state | globally_paused: true} end)
      send(caller, {:tracker_reply, {:ok, [issue]}})

      assert {:error, :globally_paused} = Task.await(command)
      refute_received {:tracker_waiting, _, :remove, _}
      assert :sys.get_state(pid).running == %{}
    end
  end

  describe "resume of an idle ticket held by an open blocking decision" do
    test "returns a named refusal and keeps the orchestrator and its registry", %{orchestrator: pid} do
      use_memory_tracker!([idle_issue("52")])
      bystander = spawn_link(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{"53" => working_entry("53", "53", bystander)},
            last_polled_issues: %{"52" => idle_issue("52")},
            blocked_ticket_ids: MapSet.new(["52"])
        }
      end)

      assert {:error, {:blocked_on_decision, %{decision_ids: ids, store: store}}} = PauseResume.resume_agent(pid, "52")
      assert is_list(ids)
      assert store in [:available, :unavailable]

      assert Process.whereis(Orchestrator) == pid
      assert %{"53" => %{pid: ^bystander}} = :sys.get_state(pid).running
    end

    test "the CLI prints a readable refusal that names the decision hold", %{orchestrator: pid} do
      use_memory_tracker!([idle_issue("52")])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{"52" => idle_issue("52")}, blocked_ticket_ids: :unavailable}
      end)

      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.resume(["52"]) end)
          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "failed to resume #52"
      assert stderr =~ "open blocking decision"
      refute stderr =~ "function_clause"
      assert Process.whereis(Orchestrator) == pid
    end
  end

  describe "a crash inside a control call" do
    test "replies with an error and keeps the orchestrator and its registry", %{orchestrator: pid} do
      bystander = spawn_link(fn -> Process.sleep(:infinity) end)

      # A running entry whose control field is not a map makes the resume path
      # raise inside the Orchestrator process.
      corrupt = "44" |> working_entry("44", self()) |> Map.put(:control, "corrupt")

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"44" => corrupt, "53" => working_entry("53", "53", bystander)}}
      end)

      :ok = Exchange.subscribe("ticket.44.agent.attention.control-call-crashed")

      log =
        capture_log(fn ->
          assert {:error, {:control_call_crashed, :resume, summary}} = PauseResume.resume_agent(pid, "44")
          assert summary =~ "no function clause matching"
          assert {:error, {:control_call_crashed, :pause, _summary}} = PauseResume.pause_agent(pid, "44")
        end)

      assert log =~ "kept its agent registry"
      # The rollback covers in-memory state only, so the operator is alerted.
      assert_receive {:event, %{topic: "ticket.44.agent.attention.control-call-crashed"}}, 2_000
      assert Process.whereis(Orchestrator) == pid
      assert %{"53" => %{pid: ^bystander}, "44" => _} = :sys.get_state(pid).running
    end
  end

  describe "pause then resume" do
    test "resume while the pause is still pending reaches the worker instead of reporting already running", %{orchestrator: pid} do
      agent = worker("44", self())

      :sys.replace_state(pid, fn state -> %{state | running: %{"44" => working_entry("44", "44", agent)}} end)

      pause_output = capture_io(fn -> AgentControlCLI.pause(["44"]) end)
      assert pause_output =~ "aiur: paused #44 (was: running)"
      assert_receive {:worker_got, :pause, _pause_request}, 1_000

      # The worker has not acknowledged the pause yet, so the row still reads
      # `:running`.
      assert [%{state: :running}] = Orchestrator.status(Orchestrator, 1_000)

      send(agent, :hold_pause)

      output = with_resume_confirm_timeout(3_000, fn -> capture_io(fn -> AgentControlCLI.resume(["44"]) end) end)

      refute output =~ "already running"
      assert_receive {:worker_got, :resume, _resume_request}, 1_000
      assert output =~ "aiur: resumed #44 (was: pausing)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "resume after an applied pause restarts the worker even when the row is stale", %{orchestrator: pid} do
      agent = worker("44", self())

      :sys.replace_state(pid, fn state -> %{state | running: %{"44" => working_entry("44", "44", agent)}} end)

      assert [%{state: :running} = stale_row] = Orchestrator.status(Orchestrator, 1_000)

      assert capture_io(fn -> AgentControlCLI.pause(["44"]) end) =~ "aiur: paused #44 (was: running)"
      assert_receive {:worker_got, :pause, _pause_request}, 1_000
      send(agent, :ack_pause)

      assert eventually(fn -> get_in(:sys.get_state(pid).running, ["44", :control, :status]) == :paused end)

      # The read model has not republished since the pause: it still shows the
      # pre-pause row. This is the state that printed "already running #52"
      # while the worker stayed stopped.
      Application.put_env(:aiur, :agent_control_cli_status_fun, fn -> [stale_row] end)
      on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_status_fun) end)

      output = with_resume_confirm_timeout(3_000, fn -> capture_io(fn -> AgentControlCLI.resume(["44"]) end) end)

      refute output =~ "already running"
      assert_receive {:worker_got, :resume, _resume_request}, 1_000
      assert output =~ "aiur: resumed #44"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      assert get_in(:sys.get_state(pid).running, ["44", :control, :status]) == :working
    end

    test "a live working worker is still reported as already running", %{orchestrator: pid} do
      agent = worker("44", self())
      :sys.replace_state(pid, fn state -> %{state | running: %{"44" => working_entry("44", "44", agent)}} end)

      output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

      assert output =~ "aiur: already running #44"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      refute_receive {:worker_got, :resume, _request}, 100
    end

    test "a working entry whose worker is gone is not reported as running", %{orchestrator: pid} do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 1000

      :sys.replace_state(pid, fn state -> %{state | running: %{"44" => working_entry("44", "44", dead)}} end)

      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
          refute output =~ "already running"
          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "failed to resume #44"
      assert stderr =~ "worker process is gone"
    end
  end

  describe "resume of a registered agent that is not working" do
    test "a sleeping agent is reported as sleeping, not resumed", %{orchestrator: pid} do
      agent = worker("44", self())
      entry = "44" |> working_entry("44", agent) |> put_in([:control, :status], :sleeping)
      :sys.replace_state(pid, fn state -> %{state | running: %{"44" => entry}} end)

      assert PauseResume.resume_agent(pid, "44") == {:ok, :sleeping}

      output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

      assert output =~ "aiur: already running #44 (sleeping"
      refute output =~ "resumed"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
      refute_receive {:worker_got, :resume, _request}, 100
      assert get_in(:sys.get_state(pid).running, ["44", :control, :status]) == :sleeping
    end

    test "an agent whose worker failed to start is refused by name", %{orchestrator: pid} do
      entry =
        "44"
        |> working_entry("44", self())
        |> put_in([:control, :status], :error)
        |> Map.put(:runtime_terminal_failure, %{kind: :startup_failed, reason: :port_exited, observed_at: nil})

      :sys.replace_state(pid, fn state -> %{state | running: %{"44" => entry}} end)

      assert PauseResume.resume_agent(pid, "44") == {:error, {:worker_startup_failed, :port_exited}}

      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
          refute output =~ "resumed"
          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "failed to resume #44"
      assert stderr =~ "worker failed to start (:port_exited)"
      assert get_in(:sys.get_state(pid).running, ["44", :control, :status]) == :error
    end

    test "reactivating a deactivated agent names its real prior state", %{orchestrator: pid} do
      entry = "44" |> working_entry("44", nil) |> put_in([:control, :status], :deactivated)
      :sys.replace_state(pid, fn state -> %{state | running: %{"44" => entry}} end)

      Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "44" -> {:ok, :reactivated} end)
      on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

      output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

      assert output =~ "aiur: reactivated #44 (was: deactivated)"
      refute output =~ "(was: running)"
    end

    test "restarting a completed agent names its real prior state", %{orchestrator: pid} do
      entry = "44" |> working_entry("44", nil) |> put_in([:control, :status], :completed)
      :sys.replace_state(pid, fn state -> %{state | running: %{"44" => entry}} end)

      Application.put_env(:aiur, :agent_control_cli_resume_fun, fn "44" -> {:ok, :started} end)
      on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_resume_fun) end)

      output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)

      assert output =~ "aiur: started #44 (was: completed)"
      refute output =~ "(was: running)"
    end
  end

  describe "resume of a staged running entry" do
    test "a working entry whose replacement worker has not started is not reported as running", %{orchestrator: pid} do
      :sys.replace_state(pid, fn state -> %{state | running: %{"44" => working_entry("44", "44", nil)}} end)

      assert PauseResume.resume_agent(pid, "44") == {:error, :worker_not_started}
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
