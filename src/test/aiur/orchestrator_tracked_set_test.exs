defmodule Aiur.OrchestratorTrackedSetTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.TrackedSet
  alias Aiur.Orchestrator.TrackerIdentityStore

  test "tracked snapshot retains the validated issue identity for publishers" do
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "NODE-681", "number" => 681}, {"acme", "repo"}, {"acme", "repo"})
    issue = %Aiur.Issue{id: "issue-681", identifier: "681", tracker_identity: identity}
    state = %Aiur.Orchestrator.State{running: %{"issue-681" => %{identifier: "681", issue: issue}}}
    on_exit(fn -> TrackedSet.reset([]) end)

    assert state == TrackedSet.refresh(state)
    assert Orchestrator.issue_tracked?(681)
    assert TrackedSet.tracker_identity("681") == identity
    assert TrackedSet.tracker_identity("682") == nil
  end

  test "validated identity survives deactivation and is durably reloadable" do
    root = Aiur.TestSupport.tmp_root!("tracker-identities")
    path = Path.join(root, "identities.json")
    previous_path = Application.get_env(:aiur, :tracker_identity_store_path)
    Application.put_env(:aiur, :tracker_identity_store_path, path)

    on_exit(fn ->
      TrackedSet.reset([])
      if previous_path, do: Application.put_env(:aiur, :tracker_identity_store_path, previous_path), else: Application.delete_env(:aiur, :tracker_identity_store_path)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "NODE-7142", "number" => 7142}, {"acme", "repo"}, {"acme", "repo"})
    issue = %Aiur.Issue{id: "issue-7142", identifier: "7142", tracker_identity: identity}
    running = %Aiur.Orchestrator.State{running: %{"issue-7142" => %{identifier: "7142", issue: issue}}}

    assert running == TrackedSet.refresh(running)
    deactivated = %Aiur.Orchestrator.State{running: %{"issue-7142" => %{identifier: "7142", issue: issue, control: %{status: :deactivated}}}}
    assert deactivated == TrackedSet.refresh(deactivated)

    refute Orchestrator.issue_tracked?(7142)
    assert TrackedSet.tracker_identity(7142) == identity
    assert TrackerIdentityStore.load()["7142"] == identity

    previous_owner = Process.whereis(TrackedSet)
    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, TrackedSet)
    assert {:ok, restarted_owner} = Supervisor.restart_child(Aiur.Supervisor, TrackedSet)
    refute restarted_owner == previous_owner
    assert TrackedSet.tracker_identity(7142) == identity
    refute Orchestrator.issue_tracked?(7142)
  end

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
