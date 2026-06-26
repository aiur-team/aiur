defmodule Aiur.OrchestratorTrackedSetTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.TrackedSet

  test "tracked set table is owned outside the orchestrator process" do
    tracked_set_owner = Process.whereis(TrackedSet)
    orchestrator_pid = Process.whereis(Orchestrator)

    assert is_pid(tracked_set_owner)
    assert is_pid(orchestrator_pid)
    refute tracked_set_owner == orchestrator_pid
    assert :ets.info(TrackedSet, :owner) == tracked_set_owner
  end

  test "tracked set table survives orchestrator restart" do
    tracked_set_owner = Process.whereis(TrackedSet)
    orchestrator_pid = Process.whereis(Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(Orchestrator)) do
        case Supervisor.restart_child(Aiur.Supervisor, Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    assert :ok = TrackedSet.reset(["681"])
    assert Orchestrator.issue_tracked?("681")
    refute Orchestrator.issue_tracked?("682")

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Orchestrator)

    assert :ets.info(TrackedSet, :owner) == tracked_set_owner
    assert Orchestrator.issue_tracked?("681")
    refute Process.alive?(orchestrator_pid)

    assert {:ok, restarted_pid} = Supervisor.restart_child(Aiur.Supervisor, Orchestrator)
    assert is_pid(restarted_pid)
  end
end
