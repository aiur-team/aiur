defmodule Aiur.TestSupport.OrchestratorGuardTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.CodeOwners
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

  test "verify_restored! catches CodeOwners state left changed by a test", context do
    previous = CodeOwners.snapshot()
    baseline = OrchestratorGuard.capture_shared_state().codeowners
    on_exit(fn -> :sys.replace_state(CodeOwners, &%{&1 | allowlist: MapSet.new(previous)}) end)
    :sys.replace_state(CodeOwners, &%{&1 | allowlist: MapSet.new(["leaked-owner"])})

    assert_raise RuntimeError, ~r/left shared test state changed .*Aiur.GitHub.CodeOwners changed/, fn ->
      expected = OrchestratorGuard.capture_shared_state()
      expected = %{expected | codeowners: baseline}
      OrchestratorGuard.verify_restored!(Map.put(context, :aiur_expected_shared_state, expected))
    end

    assert CodeOwners.snapshot() == baseline.allowlist
    assert CodeOwners.codeowners_snapshot() == baseline.codeowners
  end

  test "verify_restored! skips async tests", context do
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)

    assert :ok = OrchestratorGuard.verify_restored!(%{context | async: true})
    refute Process.whereis(Aiur.Orchestrator)
  end

  test "verify_restored! names and restores a missing ActiveTurns owner", context do
    assert is_pid(Process.whereis(Aiur.Opencode.ActiveTurns))
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Opencode.ActiveTurns)

    assert_raise RuntimeError, ~r/left Aiur\.Opencode\.ActiveTurns down/, fn ->
      OrchestratorGuard.verify_restored!(context)
    end

    assert is_pid(Process.whereis(Aiur.Opencode.ActiveTurns))
    assert Process.whereis(Aiur.Opencode.ActiveTurns) == :ets.info(Aiur.Opencode.ActiveTurns, :owner)
  end

  test "verify_restored! names and restores a leaked decision state directory", context do
    expected = OrchestratorGuard.capture_shared_state()
    original = Map.fetch!(expected.app_env, :decision_state_dir)
    Application.delete_env(:aiur, :decision_state_dir)

    assert_raise RuntimeError, ~r/left shared test state changed .*:aiur, :decision_state_dir changed/, fn ->
      OrchestratorGuard.verify_restored!(Map.put(context, :aiur_expected_shared_state, expected))
    end

    assert Application.fetch_env(:aiur, :decision_state_dir) == original
  end

  test "the next sync setup catches and restores a prior decision state leak", context do
    expected = OrchestratorGuard.capture_shared_state()
    Application.delete_env(:aiur, :decision_state_dir)

    assert_raise RuntimeError, ~r/started after last finished test .*restored shared state: .*:aiur, :decision_state_dir changed/, fn ->
      OrchestratorGuard.verify_shared_state_before_test!(context)
    end

    assert Application.fetch_env(:aiur, :decision_state_dir) == expected.app_env.decision_state_dir
  end

  test "a store restarted without its instance key is repaired after the key is restored", context do
    expected = OrchestratorGuard.capture_shared_state()
    original_dir = expected.app_env.decision_state_dir
    original_key = expected.instance_key

    on_exit(fn ->
      restore_app_env(:decision_state_dir, original_dir)
      restore_instance_key(original_key)

      if Aiur.DecisionStore.health() != :writable do
        if Process.whereis(Aiur.DecisionStore), do: Supervisor.terminate_child(Aiur.Supervisor, Aiur.DecisionStore)
        Supervisor.restart_child(Aiur.Supervisor, Aiur.DecisionStore)
      end
    end)

    Application.delete_env(:aiur, :decision_state_dir)
    System.delete_env("AIUR_INSTANCE_KEY")
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.DecisionStore)

    # Restore the path inputs before restart: init/1 resolves them when the
    # child starts, so restarting while they are absent leaves shared state
    # unavailable for every later case.
    restore_app_env(:decision_state_dir, original_dir)
    restore_instance_key(original_key)
    assert {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, Aiur.DecisionStore)

    assert Aiur.DecisionStore.health() == :writable
    # Confirm that restoring the key before restart prevents the unavailable
    # path state this test used to leak into its neighbours.
    refute Aiur.DecisionStore.health() == {:unavailable, {:path_unresolved, :missing_instance_key}}

    Application.delete_env(:aiur, :decision_state_dir)

    assert_raise RuntimeError, ~r/left shared test state changed \(restored\): .*:decision_state_dir changed/, fn ->
      OrchestratorGuard.verify_restored!(Map.put(context, :aiur_expected_shared_state, expected))
    end

    assert Aiur.DecisionStore.health() == :writable
    assert is_list(Aiur.DecisionStore.list())
  end

  test "verify_suite! fails when AIUR_INSTANCE_KEY is left changed" do
    original_key = System.get_env("AIUR_INSTANCE_KEY")
    original_decision_dir = Application.fetch_env(:aiur, :decision_state_dir)
    System.put_env("AIUR_INSTANCE_KEY", "leaked-instance-key")
    Application.delete_env(:aiur, :decision_state_dir)

    on_exit(fn ->
      if original_key, do: System.put_env("AIUR_INSTANCE_KEY", original_key), else: System.delete_env("AIUR_INSTANCE_KEY")

      case original_decision_dir do
        :error -> Application.delete_env(:aiur, :decision_state_dir)
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
      end
    end)

    assert_raise RuntimeError, ~r/test suite found shared state changed .*decision_state_dir changed.*AIUR_INSTANCE_KEY changed/, fn ->
      OrchestratorGuard.verify_suite!()
    end
  end

  test "the ExUnit wiring reports setup restarts and fails leaks from both case templates" do
    src_dir = Path.expand("../../..", __DIR__)
    mix = System.find_executable("mix") || flunk("mix executable not found")

    {output, status} =
      System.cmd(mix, ["test", "--seed", "0", "--include", "orchestrator_guard_probe", "test/fixtures/orchestrator_guard"],
        cd: src_dir,
        stderr_to_stdout: true,
        env: [{"AIUR_RUN_ORCHESTRATOR_GUARD_PROBES", "1"}]
      )

    assert status != 0
    assert output =~ "16 tests, 3 failures"
    assert output =~ "Aiur.Orchestrator was down before Aiur.BTestSupportWiringNeighbourTest"
    assert output =~ "last finished test: Aiur.APlainCaseWiringProbeTest: test leaves orchestrator down"
    assert output =~ "last finished test: Aiur.DPlainCaseUnnamedProbeTest: test leaves the supervised orchestrator unnamed"

    assert output =~ "Aiur.ZTestSupportWiringProbeTest: test leaves orchestrator down left Aiur.Orchestrator down (restore: :ok)"

    assert output =~
             "plain ExUnit tests broke Aiur.Orchestrator: Aiur.APlainCaseWiringProbeTest: test leaves orchestrator down (down), Aiur.DPlainCaseUnnamedProbeTest: test leaves the supervised orchestrator unnamed (down), Aiur.ZZPlainCaseLastProbeTest: test leaves orchestrator down at suite end (down)"

    assert output =~
             "plain ExUnit tests left shared runtime children down: Aiur.FPlainCasePubSubLeakProbeTest: test leaves the PubSub registry table down (Aiur.PubSub unregistered)"

    assert output =~ ~r/YTestSupportStandInProbeTest: test leaves a stand-in holding the name left Aiur.Orchestrator held by a stand-in #PID<[\d.]+> \(restore: :ok\)/
    # Borrowing the name in setup and giving it back is not a leak.
    refute output =~ "AAUnregisterRestoreProbeTest"
  end

  defp restore_app_env(key, :error), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:aiur, key, value)

  defp restore_instance_key(nil), do: System.delete_env("AIUR_INSTANCE_KEY")
  defp restore_instance_key(value), do: System.put_env("AIUR_INSTANCE_KEY", value)
end
