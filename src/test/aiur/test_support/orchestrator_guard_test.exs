defmodule Aiur.TestSupport.OrchestratorGuardTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.TestSupport.OrchestratorGuard

  setup do
    on_exit(fn -> assert :ok = Aiur.TestSupport.ensure_orchestrator_running() end)
  end

  test "verify_restored! fails a sync test that leaves the orchestrator down and restores it", context do
    assert :ok = OrchestratorGuard.verify_restored!(context)
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)

    assert_raise RuntimeError, ~r/OrchestratorGuardTest: test verify_restored! fails .* left Aiur.Orchestrator down/, fn ->
      OrchestratorGuard.verify_restored!(context)
    end

    assert is_pid(Process.whereis(Aiur.Orchestrator))
  end

  test "verify_restored! skips async tests", context do
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)

    assert :ok = OrchestratorGuard.verify_restored!(%{context | async: true})
    refute Process.whereis(Aiur.Orchestrator)
  end

  test "ensure_running names the last finished test when it has to restart the orchestrator", context do
    GenServer.cast(OrchestratorGuard, {:test_finished, %ExUnit.Test{module: LeakyTest, name: :"test leaks"}})
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)

    output = capture_io(:stderr, fn -> assert :ok = OrchestratorGuard.ensure_running(context) end)

    assert output =~ "Aiur.Orchestrator was down before Aiur.TestSupport.OrchestratorGuardTest: test ensure_running"
    assert output =~ "last finished test: LeakyTest: test leaks"
    assert is_pid(Process.whereis(Aiur.Orchestrator))
  end
end
