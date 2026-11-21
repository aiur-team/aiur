defmodule Aiur.TestSupport.OrchestratorRuntimeGuard do
  @moduledoc false

  alias Aiur.TestSupport.RuntimeChildren

  def verify_restored!(context, callbacks) do
    RuntimeChildren.supervisor_accepting_calls?(Process.whereis(Aiur.Supervisor), 1_000)

    {orchestrator_leak, orchestrator_restore} = restore_orchestrator(callbacks)
    pubsub_errors = callbacks.restore_and_report_pubsub.(is_nil(Process.whereis(Aiur.PubSub)), context)
    active_turns_errors = callbacks.restore_and_report_active_turns.(active_turns_owner_missing?(), context)
    shared_leaks = callbacks.verify_shared_state_restored.(context)
    store_leaks = callbacks.decision_store_leaks.()
    store_recovery = callbacks.recover_decision_store.(store_leaks)

    errors =
      orchestrator_errors(orchestrator_leak, orchestrator_restore, context, callbacks) ++
        pubsub_errors ++ active_turns_errors ++ shared_state_errors(shared_leaks, store_leaks, store_recovery, context, callbacks)

    if active_turns_errors != [], do: callbacks.restart_active_turns.()
    raise_errors(errors)
  end

  defp restore_orchestrator(callbacks) do
    leak = callbacks.orchestrator_leak.()
    {leak, if(leak, do: callbacks.restore_orchestrator.(leak))}
  end

  defp active_turns_owner_missing? do
    is_nil(Process.whereis(Aiur.Opencode.ActiveTurns)) and is_pid(Process.whereis(Aiur.Supervisor)) and
      is_pid(Process.whereis(Aiur.PubSub))
  end

  defp orchestrator_errors(nil, _restore, _context, _callbacks), do: []

  defp orchestrator_errors(leak, restore, context, callbacks) do
    [
      "#{callbacks.test_name.(context)} left Aiur.Orchestrator #{leak} (restore: #{inspect(restore)}). Restore it in on_exit with Aiur.TestSupport.ensure_orchestrator_running/0 or await_supervised_restart/3."
    ]
  end

  defp shared_state_errors([], [], :ok, _context, _callbacks), do: []

  defp shared_state_errors(shared_leaks, store_leaks, recovery, context, callbacks) do
    recovery_errors = callbacks.recovery_errors.(recovery)
    restored = if recovery_errors == [], do: "restored", else: "restore failed"

    [
      "#{callbacks.test_name.(context)} left shared test state changed (#{restored}): #{Enum.join(shared_leaks ++ store_leaks ++ recovery_errors, "; ")}"
    ]
  end

  defp raise_errors([]), do: :ok
  defp raise_errors(errors), do: raise(Enum.join(errors, "\n"))
end
