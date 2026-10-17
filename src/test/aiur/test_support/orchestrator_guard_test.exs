defmodule Aiur.TestSupport.OrchestratorGuardTest do
  use Aiur.TestSupport

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

  test "the ExUnit wiring reports setup restarts and fails leaks from both case templates" do
    src_dir = Path.expand("../../..", __DIR__)
    mix = System.find_executable("mix") || flunk("mix executable not found")

    {output, status} =
      System.cmd(mix, ["test", "--seed", "0", "--include", "orchestrator_guard_probe", "test/fixtures/orchestrator_guard"],
        cd: src_dir,
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "Aiur.Orchestrator was down before Aiur.BTestSupportWiringNeighbourTest"
    assert output =~ "last finished test: Aiur.APlainCaseWiringProbeTest: test leaves orchestrator down"
    assert output =~ "last finished test: Aiur.DPlainCaseUnnamedProbeTest: test leaves the supervised orchestrator unnamed"
    assert output =~ "Aiur.ZTestSupportWiringProbeTest: test leaves orchestrator down left Aiur.Orchestrator down (restore: :ok)"
    assert output =~ ~r/YTestSupportStandInProbeTest: test leaves a stand-in holding the name left Aiur.Orchestrator held by a stand-in #PID<[\d.]+> \(restore: :ok\)/
    # Each plain leak is caught by the next sync setup, the last one by the after_suite check.
    assert output =~
             "plain ExUnit tests broke Aiur.Orchestrator: Aiur.APlainCaseWiringProbeTest: test leaves orchestrator down (down), " <>
               "Aiur.DPlainCaseUnnamedProbeTest: test leaves the supervised orchestrator unnamed (down), " <>
               "Aiur.ZZPlainCaseLastProbeTest: test leaves orchestrator down at suite end (down)\n"

    # Borrowing the name in setup and giving it back is not a leak.
    refute output =~ "AAUnregisterRestoreProbeTest"
    assert output =~ "13 tests, 2 failures"
  end
end
