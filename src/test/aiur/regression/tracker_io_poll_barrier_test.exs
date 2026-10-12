Code.require_file("../../support/tracker_io_poll_barrier.exs", __DIR__)

defmodule Aiur.Regression.TrackerIoPollBarrierTest do
  use Aiur.TestSupport

  import Aiur.TrackerIoPollBarrier, only: [await_poll_finished: 1, await_poll_finished: 2]

  alias Aiur.Orchestrator

  # #3904: the barrier used to splice itself into the in-flight poll task, so
  # installing it while no such task existed crashed the orchestrator's state
  # replacement with `{:badmatch, nil}`.
  test "a barrier installed before the poll starts still observes its completion" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")
    server = start_supervised!({Orchestrator, initial_poll?: false})
    assert :sys.get_state(server).poll_cycles_completed == 0

    # The delay only orders the poll after the install; either order completes.
    Process.send_after(server, :run_poll_cycle, 50)

    assert await_poll_finished(server).poll_cycles_completed == 1
  end

  test "a poll that never completes fails naming the wait and the server's state" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")
    server = start_supervised!({Orchestrator, initial_poll?: false})

    error = assert_raise ExUnit.AssertionError, fn -> await_poll_finished(server, 50) end
    assert error.message =~ "waited 50 ms for #{inspect(server)} to complete a poll cycle"
    # Boot starts a :startup_workspace_cleanup tracker task that may still be
    # listed at 50 ms on a loaded host, so the task list is not asserted.
    assert error.message =~ "saw poll_cycles_completed=0, tracker tasks ["
  end
end
