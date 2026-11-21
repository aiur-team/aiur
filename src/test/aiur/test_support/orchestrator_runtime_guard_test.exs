defmodule Aiur.TestSupport.OrchestratorRuntimeGuardTest do
  use ExUnit.Case, async: true

  alias Aiur.TestSupport.OrchestratorRuntimeGuard

  test "restarts ActiveTurns when its owner is missing, even without report errors" do
    test_pid = self()

    callbacks = %{
      orchestrator_leak: fn -> nil end,
      restore_orchestrator: fn _leak -> :ok end,
      restore_and_report_pubsub: fn _missing, _context -> [] end,
      active_turns_owner_missing: fn -> true end,
      restore_and_report_active_turns: fn true, _context -> [] end,
      verify_shared_state_restored: fn _context -> [] end,
      decision_store_leaks: fn -> [] end,
      recover_decision_store: fn _leaks -> :ok end,
      test_name: fn _context -> "guard test" end,
      recovery_errors: fn _recovery -> [] end,
      restart_active_turns: fn -> send(test_pid, :active_turns_restarted) end
    }

    assert :ok = OrchestratorRuntimeGuard.verify_restored!(%{}, callbacks)
    assert_receive :active_turns_restarted, 1_000
  end
end
