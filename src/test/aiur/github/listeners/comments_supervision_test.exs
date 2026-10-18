defmodule Aiur.GitHub.Listeners.CommentsSupervisionTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Listeners
  alias Aiur.GitHub.Listeners.Comments

  test "a listener crash restarts the orchestrator through the root supervisor" do
    previous_orchestrator = Process.whereis(Aiur.Orchestrator)
    previous_supervisor = Process.whereis(Listeners)
    orchestrator_ref = Process.monitor(previous_orchestrator)
    supervisor_ref = Process.monitor(previous_supervisor)
    Process.exit(Process.whereis(Comments), :kill)
    receive_barrier({:DOWN, ^supervisor_ref, :process, ^previous_supervisor, _reason})
    receive_barrier({:DOWN, ^orchestrator_ref, :process, ^previous_orchestrator, _reason})
    # The root finishes its rest_for_one restart before answering the barrier.
    Supervisor.which_children(Aiur.Supervisor)
    assert is_pid(Process.whereis(Comments))
    assert is_pid(Process.whereis(Aiur.Orchestrator))
    assert Process.whereis(Aiur.Orchestrator) != previous_orchestrator
    assert Process.whereis(Listeners) != previous_supervisor
    assert :ok = Listeners.reset()
  end
end
