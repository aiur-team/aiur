defmodule Aiur.AgentControlCLIMergePolicyTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.MainWatch.Persistence

  setup do
    original = landing_watch_snapshot()

    on_exit(fn ->
      restore_landing_watch_snapshot(original)
    end)

    :ok
  end

  test "status renders the default merge policy" do
    assert status_output() =~ "MERGE POLICY ci=wait local_tests=partial role=primary repo_global_off=none main_watch=off watcher=not_running landing_watcher=unavailable\n"
  end

  test "status renders the configured CI policy and main watcher mode" do
    path = Aiur.Workflow.workflow_file_path()

    write_workflow_file_atomic!(
      path,
      File.read!(path) <>
        """

        merge_policy:
          ci: wait
          local_tests: partial
          main_watch:
            enabled: true
            on_red: dispatch_fixer
        """
    )

    :ok = Aiur.WorkflowStore.force_reload()
    assert status_output() =~ "MERGE POLICY ci=wait local_tests=partial role=primary repo_global_off=none main_watch=on(dispatch_fixer) watcher=not_running landing_watcher=unavailable main=unknown\n"
  end

  test "status shows a watcher still running after its config is disabled" do
    launch_watcher()
    assert status_output() =~ "main_watch=off watcher=running landing_watcher=unavailable main=unknown\n"
  end

  test "status shows an enabled watcher that actually started" do
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nmerge_policy:\n  main_watch:\n    enabled: true\n")
    :ok = Aiur.WorkflowStore.force_reload()
    launch_watcher()
    assert status_output() =~ "main_watch=on(alert) watcher=running landing_watcher=unavailable main=unknown\n"
  end

  test "status reports the landing watcher as running" do
    case set_landing_watch_running() do
      :running ->
        assert status_output() =~ "landing_watcher=running"

      :unavailable ->
        assert status_output() =~ "landing_watcher=unavailable"
    end
  end

  test "status shows the watcher's unavailable observation" do
    parent = self()

    launch_watcher(
      poll_fun: fn _, _, _ -> {:error, :denied} end,
      save_fun: fn _, _, _ ->
        send(parent, :saved)
        :ok
      end
    )

    receive_barrier(:saved)
    assert %{watcher: :unavailable, unavailable: true} = Aiur.MainWatch.state()
    assert status_output() =~ "main_watch=off watcher=unavailable watcher_error=denied landing_watcher=unavailable main=unavailable last_known=unknown\n"
  end

  defp launch_watcher(overrides \\ []) do
    opts = [
      config: %{workflows: [], canary_minutes: 0},
      branch: "main",
      repo: "owner/repo",
      interval_ms: 60_000,
      subscribe: false,
      actions_write: false,
      load_fun: fn _, _ -> Persistence.empty() end,
      poll_fun: fn _, _, _ ->
        receive do
          :finish -> {:error, :offline}
        end
      end,
      save_fun: fn _, _, _ -> :ok end,
      emit_fun: fn _, _ -> :ok end
    ]

    start_supervised!({Aiur.MainWatch, Keyword.merge(opts, overrides)})
  end

  test "status reports the role the daemon booted with, not a hot-reloaded one" do
    previous = Application.get_env(:aiur, :booted_instance_role)
    on_exit(fn -> if previous, do: Application.put_env(:aiur, :booted_instance_role, previous), else: Application.delete_env(:aiur, :booted_instance_role) end)
    assert Aiur.Config.instance_role() == "primary"
    Application.put_env(:aiur, :booted_instance_role, "secondary")

    assert status_output() =~ "role=secondary repo_global_off=[landing_watch,quarantine_lifter,merge_queue_watchdog,main_watch]"
  end

  defp status_output do
    snapshot = %{statuses: [], global_pause: %{globally_paused: false, paused_at: nil, source: nil}}
    capture_io(fn -> Aiur.AgentControlCLI.status(fleet_view: {:ok, snapshot, %{status: :current, reason: nil, age_seconds: 0}}) end)
  end

  defp set_landing_watch_running do
    case Process.whereis(Aiur.LandingWatch) do
      pid when is_pid(pid) ->
        try do
          :sys.replace_state(pid, &Map.put(&1, :watcher, :running))
          :running
        catch
          :exit, _reason -> :unavailable
        end

      nil ->
        :unavailable
    end
  end

  defp landing_watch_snapshot do
    case Process.whereis(Aiur.LandingWatch) do
      pid when is_pid(pid) ->
        try do
          {:ok, pid, :sys.get_state(pid) |> Map.take([:watcher, :last_poll_at_ms, :last_error])}
        catch
          :exit, _reason -> nil
        end

      nil ->
        nil
    end
  end

  defp restore_landing_watch_snapshot({:ok, pid, original}) do
    if Process.whereis(Aiur.LandingWatch) == pid do
      try do
        :sys.replace_state(pid, &Map.merge(&1, original))
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp restore_landing_watch_snapshot(_snapshot), do: :ok
end
