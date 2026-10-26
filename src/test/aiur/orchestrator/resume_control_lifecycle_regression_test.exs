defmodule Aiur.Orchestrator.ResumeControlLifecycleRegressionTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.{AgentControlCLI, Issue}
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.TrackerIdentity
  import Aiur.SnapshotFenceSupport, only: [fence_snapshot_read_model: 0]
  import Aiur.TrackerTaskDrainSupport, only: [drain_tracker_tasks: 3, drain_tracker_tasks: 4]

  setup %{test: test_name} do
    pid = Process.whereis(Orchestrator)
    original_state = :sys.get_state(pid, 15_000)
    snapshot_generation = fence_snapshot_read_model()

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
        generation = fence_snapshot_read_model()
        drain_tracker_tasks(pid, 15_000, to_string(test_name))

        :sys.replace_state(pid, fn _ ->
          %{original_state | snapshot_generation: generation, tracker_tasks: %{}}
        end)
      end
    end)

    {:ok, orchestrator: pid}
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

  test "resume while the pause is still pending reaches the worker", %{orchestrator: pid} do
    agent = worker("44", self())

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"44" => working_entry("44", "44", agent)}}
    end)

    assert capture_io(fn -> AgentControlCLI.pause(["44"]) end) =~
             "aiur: paused #44 (was: running)"

    assert_receive {:worker_got, :pause, _}, 1_000
    assert [%{state: :running}] = Orchestrator.status(Orchestrator, 1_000)
    send(agent, :hold_pause)

    output =
      with_resume_confirm_timeout(3_000, fn ->
        capture_io(fn -> AgentControlCLI.resume(["44"]) end)
      end)

    refute output =~ "already running"
    assert_receive {:worker_got, :resume, _}, 1_000
    assert output =~ "aiur: resumed #44 (was: pausing)"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "resume after an applied pause restarts the worker even when the row is stale", %{
    orchestrator: pid
  } do
    agent = worker("44", self())

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"44" => working_entry("44", "44", agent)}}
    end)

    assert [%{state: :running} = stale_row] = Orchestrator.status(Orchestrator, 1_000)

    assert capture_io(fn -> AgentControlCLI.pause(["44"]) end) =~
             "aiur: paused #44 (was: running)"

    assert_receive {:worker_got, :pause, _}, 1_000
    send(agent, :ack_pause)

    assert eventually(fn ->
             get_in(:sys.get_state(pid).running, ["44", :control, :status]) == :paused
           end)

    Application.put_env(:aiur, :agent_control_cli_status_fun, fn -> [stale_row] end)
    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_status_fun) end)

    output =
      with_resume_confirm_timeout(3_000, fn ->
        capture_io(fn -> AgentControlCLI.resume(["44"]) end)
      end)

    refute output =~ "already running"
    assert_receive {:worker_got, :resume, _}, 1_000
    assert output =~ "aiur: resumed #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert get_in(:sys.get_state(pid).running, ["44", :control, :status]) == :working
  end

  test "a live worker is reported as already running", %{orchestrator: pid} do
    agent = worker("44", self())

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"44" => working_entry("44", "44", agent)}}
    end)

    output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
    assert output =~ "aiur: already running #44"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    refute_receive {:worker_got, :resume, _}, 100
  end

  test "a gone worker is not reported as running", %{orchestrator: pid} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1000

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"44" => working_entry("44", "44", dead)}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
        refute output =~ "already running"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "failed to resume #44"
    assert stderr =~ "worker process is gone"
  end

  test "a sleeping agent is not resumed", %{orchestrator: pid} do
    agent = worker("44", self())
    entry = "44" |> working_entry("44", agent) |> put_in([:control, :status], :sleeping)
    :sys.replace_state(pid, fn state -> %{state | running: %{"44" => entry}} end)
    assert PauseResume.resume_agent(pid, "44") == {:ok, :sleeping}
    output = capture_io(fn -> AgentControlCLI.resume(["44"]) end)
    assert output =~ "aiur: already running #44 (sleeping"
    refute output =~ "resumed"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    refute_receive {:worker_got, :resume, _}, 100
    assert get_in(:sys.get_state(pid).running, ["44", :control, :status]) == :sleeping
  end

  test "a failed worker start is refused by name", %{orchestrator: pid} do
    entry =
      "44"
      |> working_entry("44", self())
      |> put_in([:control, :status], :error)
      |> Map.put(:runtime_terminal_failure, %{
        kind: :startup_failed,
        reason: :port_exited,
        observed_at: nil
      })

    :sys.replace_state(pid, fn state -> %{state | running: %{"44" => entry}} end)

    assert PauseResume.resume_agent(pid, "44") ==
             {:error, {:worker_startup_failed, :port_exited}}

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

  test "reactivation names its real prior state", %{orchestrator: pid} do
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

  test "a staged worker is not reported as running", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"44" => working_entry("44", "44", nil)}}
    end)

    assert PauseResume.resume_agent(pid, "44") == {:error, :worker_not_started}
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
