defmodule Aiur.AgentControlCLIMergePolicyTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO

  test "status renders the default merge policy" do
    assert status_output() =~ "MERGE POLICY ci=wait local_tests=partial main_watch=off\n"
  end

  test "status renders the configured pending CI policy and main watcher mode" do
    path = Aiur.Workflow.workflow_file_path()

    write_workflow_file_atomic!(
      path,
      File.read!(path) <>
        """

        merge_policy:
          ci: pending_ok
          local_tests: partial
          main_watch:
            enabled: true
            on_red: dispatch_fixer
        """
    )

    :ok = Aiur.WorkflowStore.force_reload()
    assert status_output() =~ "MERGE POLICY ci=pending_ok local_tests=partial full_ci=[main-fix] main_watch=on(dispatch_fixer)\n"
  end

  defp status_output do
    snapshot = %{statuses: [], global_pause: %{globally_paused: false, paused_at: nil, source: nil}}
    capture_io(fn -> Aiur.AgentControlCLI.status(fleet_view: {:ok, snapshot, %{status: :current, reason: nil, age_seconds: 0}}) end)
  end
end
