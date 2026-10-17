Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliFixtureTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.Lifecycle

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  test "fixture restoration fences queued ticks and poll cycles between cases (#3007)", %{orchestrator: pid} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    original_state = %{orchestrator_state!(pid) | poll_frozen: false}
    :sys.suspend(pid)

    try do
      state = :sys.replace_state(pid, &Lifecycle.schedule_tick(&1, 60_000))
      timer = state.tick_timer_ref
      send(pid, {:tick, state.tick_token})
      send(pid, :run_poll_cycle)

      restore_orchestrator_state(pid, original_state)
      assert Process.read_timer(timer) == false
      :sys.resume(pid)

      # Suspension widens the window across restoration; this system call
      # is a mailbox barrier after both queued messages, not a timing guess.
      restored = orchestrator_state!(pid)
      assert restored.poll_cycles_completed == original_state.poll_cycles_completed
      assert restored.poll_check_in_progress == false
      assert restored.next_poll_due_at_ms == nil
      assert restored.running == original_state.running
    after
      :sys.resume(pid)
    end
  end

  test "fixture state timeout captures the blocked function and mailbox (#3007)", %{orchestrator: pid} do
    parent = self()
    barrier = make_ref()

    blocker =
      Task.async(fn ->
        :sys.replace_state(pid, fn state ->
          send(parent, {:fixture_blocked, barrier})

          receive do
            ^barrier -> state
          end
        end)
      end)

    receive_barrier({:fixture_blocked, ^barrier})
    send(pid, {:fixture_mailbox_evidence, barrier})

    try do
      error = assert_raise ExUnit.AssertionError, fn -> orchestrator_state!(pid, 1) end
      assert error.message =~ "current_function: {Aiur.OrchestratorStatusCliFixtureTest,"
      assert error.message =~ "fixture state timeout captures the blocked function and mailbox"
      assert error.message =~ "current_stacktrace:"
      assert error.message =~ "fixture_mailbox_evidence"
      assert error.message =~ "message_queue_len:"
    after
      send(pid, barrier)
      Task.await(blocker)
    end
  end
end
