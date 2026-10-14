defmodule Aiur.AgentControlCLIMergePolicyTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.MainWatch.Persistence

  test "status renders the default merge policy" do
    assert status_output() =~ "MERGE POLICY ci=wait local_tests=partial main_watch=off watcher=not_running\n"
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
    assert status_output() =~ "MERGE POLICY ci=wait local_tests=partial main_watch=on(dispatch_fixer) watcher=not_running main=unknown\n"
  end

  test "status shows a watcher still running after its config is disabled" do
    launch_watcher()
    assert status_output() =~ "main_watch=off watcher=running main=unknown\n"
  end

  test "status shows an enabled watcher that actually started" do
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nmerge_policy:\n  main_watch:\n    enabled: true\n")
    :ok = Aiur.WorkflowStore.force_reload()
    launch_watcher()
    assert status_output() =~ "main_watch=on(alert) watcher=running main=unknown\n"
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
    assert status_output() =~ "main_watch=off watcher=unavailable main=unavailable last_known=unknown\n"
  end

  defp launch_watcher(overrides \\ []) do
    unless Process.whereis(Aiur.TaskSupervisor), do: start_supervised!({Task.Supervisor, name: Aiur.TaskSupervisor})

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

  defp status_output do
    snapshot = %{statuses: [], global_pause: %{globally_paused: false, paused_at: nil, source: nil}}
    capture_io(fn -> Aiur.AgentControlCLI.status(fleet_view: {:ok, snapshot, %{status: :current, reason: nil, age_seconds: 0}}) end)
  end
end
