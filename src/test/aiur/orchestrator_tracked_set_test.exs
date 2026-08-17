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
    {:ok, orchestrator_pid} = ensure_orchestrator_running()
    tracked_set_owner = Process.whereis(TrackedSet)

    on_exit(&ensure_orchestrator_running/0)

    # The live orchestrator's scheduled poll rebuilds the table from
    # `state.running` via `TrackedSet.refresh/1`. Between this test's
    # `TrackedSet.reset/1` fixture and `terminate_orchestrator/0`, a poll can
    # land and overwrite "681" with the (empty) running set — the #1647 flake.
    # Freeze the poll so the fixture survives to the persistence assert below;
    # the point under test is that a restart leaves the table intact, not that
    # a concurrent poll happens to stay out of the way.
    freeze_poll_cycle(orchestrator_pid)

    assert :ok = TrackedSet.reset(["681"])
    assert Orchestrator.issue_tracked?("681")
    refute Orchestrator.issue_tracked?("682")

    assert :ok = terminate_orchestrator()

    assert :ets.info(TrackedSet, :owner) == tracked_set_owner
    assert Orchestrator.issue_tracked?("681")
    refute Process.alive?(orchestrator_pid)

    assert {:ok, restarted_pid} = restart_orchestrator()
    assert is_pid(restarted_pid)
  end

  # Cancels the orchestrator's tick timer and fences the one-shot
  # `:run_poll_cycle` (a 20ms render delay that is not token-fenced), so no
  # scheduled poll can mutate the shared TrackedSet mid-test. Mirrors the
  # freeze used by `OrchestratorStatusTest`.
  defp freeze_poll_cycle(pid) do
    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: nil,
          poll_check_in_progress: false,
          poll_frozen: true
      }
    end)
  end

  defp terminate_orchestrator do
    ensure_aiur_supervisor_running()

    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) ->
        case Supervisor.terminate_child(Aiur.Supervisor, Orchestrator) do
          :ok -> :ok
          {:error, :not_found} -> stop_unlinked_orchestrator(pid)
        end

      nil ->
        :ok
    end
  end

  defp stop_unlinked_orchestrator(pid) do
    GenServer.stop(pid, :normal, 1_000)
  end

  defp ensure_orchestrator_running do
    ensure_aiur_supervisor_running()

    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> restart_orchestrator()
    end
  end

  defp restart_orchestrator do
    ensure_aiur_supervisor_running()

    case Supervisor.restart_child(Aiur.Supervisor, Orchestrator) do
      {:ok, pid} when is_pid(pid) ->
        {:ok, pid}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        {:ok, pid}

      {:error, reason} when reason in [:already_present, :running] ->
        case Process.whereis(Orchestrator) do
          pid when is_pid(pid) -> {:ok, pid}
          nil -> flunk("orchestrator restart raced and left no process: #{inspect(reason)}")
        end
    end
  end

  defp ensure_aiur_supervisor_running do
    case Process.whereis(Aiur.Supervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Application.ensure_all_started(:aiur) do
          {:ok, _apps} -> :ok
          {:error, {:already_started, _app}} -> :ok
        end
    end
  end
end
