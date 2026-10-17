defmodule Aiur.Core.OrchestratorWorkerRetryTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.Dispatcher

  import Aiur.CoreTestSupport

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_down_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, before_down_ms, 500, 1_100)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_down_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, before_down_ms, 39_500, 40_500)
  end

  test "genuine provider-start failure beyond max_retry_attempts reaches the error state" do
    # Drive the give-up path through the in-memory tracker so the state move is
    # observable (#708): on genuine retry exhaustion the orchestrator must push
    # the ticket into the operator-visible `error` state instead of silently
    # leaving it in `rework` with no live agent.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())

    issue_id = "issue-exhausted"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ExhaustedRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-EX",
      # Coming back from attempt 3 means the next failure would be attempt 4,
      # which is > the default max_retry_attempts (3).
      retry_attempt: 3,
      issue: %Issue{id: issue_id, identifier: "MT-EX", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    log =
      capture_log(fn ->
        send(pid, {:DOWN, ref, :process, self(), {:turn_start_failed, :provider_rejected}})

        await_orchestrator_state(pid, fn state ->
          Enum.all?(state.tracker_tasks, fn {_ref, job} -> job.key != {:retry_exhausted, issue_id} end)
        end)
      end)

    state = :sys.get_state(pid)

    refute Map.has_key?(state.retry_attempts, issue_id),
           "expected the orchestrator to give up after exceeding max_retry_attempts"

    refute MapSet.member?(state.claimed, issue_id),
           "give-up must release the claim so a label-driven re-dispatch (#699) can pick the ticket up without a daemon restart"

    assert log =~ "after 3 failed attempt(s)"
    assert log =~ "issue_id=#{issue_id}"
    assert log =~ "reason=retry_exhausted"
    assert log =~ "caller=Aiur.Orchestrator.move_exhausted_issue_to_error_state"
    assert log =~ "ticket.MT-EX.agent.retry_exhausted"
    assert log =~ "ticket.MT-EX.agent.attention.error-retry_exhausted"
    assert log =~ "automatic retry is no longer scheduled"

    assert_receive {:memory_tracker_state_update, "MT-EX", "error"}, 1000
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      stop_test_orchestrator(pid)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_down_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, before_down_ms, 9_000, 10_500)
  end

  test "slot-starved retry preserves failure attempt and remains queued" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 1,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Cancelled"]
    )

    issue_id = "issue-slot-starved"
    retry_token = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :SlotStarvedRetryOrchestrator)
    issue = %Issue{id: issue_id, identifier: "MT-SLOT", title: "Retry me", state: "In Progress"}

    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    initial_state = :sys.get_state(pid)

    busy_worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn ->
      stop_test_orchestrator(pid)

      busy_worker_ref = Process.monitor(busy_worker_pid)
      send(busy_worker_pid, :done)

      assert_receive {:DOWN, ^busy_worker_ref, :process, ^busy_worker_pid, reason}, 1000
      assert reason in [:normal, :noproc]
    end)

    other_running_entry = %{
      pid: busy_worker_pid,
      ref: make_ref(),
      identifier: "MT-BUSY",
      issue: %Issue{id: "issue-busy", identifier: "MT-BUSY", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{"issue-busy" => other_running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 1,
          retry_token: retry_token,
          timer_ref: nil,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: "MT-SLOT",
          error: "agent exited: :response_timeout"
        }
      })
    end)

    before_retry_ms = System.monotonic_time(:millisecond)
    send(pid, {:retry_issue, issue_id, retry_token})
    state = :sys.get_state(pid)
    observed_at_ms = System.monotonic_time(:millisecond)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-SLOT",
             error: "no available orchestrator slots"
           } = state.retry_attempts[issue_id]

    assert is_reference(state.retry_attempts[issue_id].retry_token)
    assert_due_in_range(due_at_ms, before_retry_ms, 1_000, observed_at_ms - before_retry_ms + 1_000)

    busy_state = %{state | running: %{"issue-busy" => other_running_entry}}
    freed_state = %{state | running: %{}}
    refute Dispatcher.retry_dispatch_ready?(issue, busy_state, nil)
    assert Dispatcher.retry_dispatch_ready?(issue, freed_state, nil)
  end

  defp assert_due_in_range(due_at_ms, scheduled_after_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert due_at_ms >= scheduled_after_ms + min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end
end
