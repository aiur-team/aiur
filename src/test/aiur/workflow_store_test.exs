defmodule Aiur.WorkflowStoreTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  # Regression for #1214: a transient reload error must not advance the change
  # stamp. When it did, the store believed the failed content was already
  # current, skipped the next good reload, and kept serving the previous
  # config — `Config.workspace_root/0` then returned a prior test's value and
  # `CodingAgent.start_session` rejected the cwd with `:outside_workspace_root`.
  test "transient reload error does not mask the next good reload" do
    ensure_workflow_store_running()

    path = Workflow.workflow_file_path()
    dir = Path.dirname(path)
    root_after_recovery = Path.join(dir, "workspaces-after-recovery")

    staging = Path.join(dir, "v2.aiurconfig")
    write_workflow_file!(staging, workspace_root: root_after_recovery)

    # `prewarm.base_build_file` is read by `Workflow.load/1` but is not part
    # of the change stamp — exactly the shape of a transient load error the
    # stamp cannot see, so a poisoned stamp would never heal on its own.
    File.write!(path, File.read!(staging) <> "\nprewarm:\n  base_build_file: prewarm\n")

    assert {:error, {:missing_prewarm_file, _prewarm_path, :enoent}} = WorkflowStore.force_reload()

    File.write!(Path.join(dir, "prewarm"), "true\n")

    assert :ok = WorkflowStore.force_reload()
    assert Config.workspace_root() == root_after_recovery

    File.write!(Path.join(dir, "prewarm"), "echo rebuilt\n")

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{prewarm: %{base_build: "echo rebuilt"}}} = Config.settings()
  end

  test "invalid safety settings on reload keep the last known good workflow" do
    ensure_workflow_store_running()

    path = Workflow.workflow_file_path()

    write_workflow_file_synced!(path,
      tracker_kind: "memory",
      tracker_base_branch: "main",
      max_concurrent_agents: 3
    )

    original_identity_override =
      Application.get_env(:aiur, :allow_runtime_tracker_identity_changes)

    Application.put_env(:aiur, :allow_runtime_tracker_identity_changes, false)

    on_exit(fn ->
      Application.put_env(
        :aiur,
        :allow_runtime_tracker_identity_changes,
        original_identity_override
      )
    end)

    generation = :sys.get_state(WorkflowStore).generation
    assert Config.base_branch() == "main"

    invalid_path = Path.join(Path.dirname(path), "invalid-base.aiurconfig")

    write_workflow_file!(invalid_path,
      tracker_kind: "memory",
      tracker_base_branch: nil
    )

    log =
      capture_log(fn ->
        File.cp!(invalid_path, path)
        assert {:error, :missing_base_branch} = WorkflowStore.force_reload()
      end)

    assert log =~ "Failed to reload workflow path=#{path}"
    assert log =~ "tracker.base_branch is required"
    assert Config.base_branch() == "main"
    assert :sys.get_state(WorkflowStore).generation == generation

    retarget_path = Path.join(Path.dirname(path), "retarget.aiurconfig")

    write_workflow_file!(retarget_path,
      tracker_kind: "memory",
      tracker_base_branch: "develop"
    )

    log =
      capture_log(fn ->
        File.cp!(retarget_path, path)

        assert {:error, {:restart_required_configuration_change, _, _}} =
                 WorkflowStore.force_reload()
      end)

    assert log =~ "require a daemon restart"
    assert log =~ ~s(base_branch: "main")
    assert log =~ ~s(base_branch: "develop")
    assert Config.base_branch() == "main"
    assert :sys.get_state(WorkflowStore).generation == generation

    repair_path = Path.join(Path.dirname(path), "repair.aiurconfig")

    write_workflow_file!(repair_path,
      tracker_kind: "memory",
      tracker_base_branch: "main",
      max_concurrent_agents: 7
    )

    File.cp!(repair_path, path)
    assert :ok = WorkflowStore.force_reload()
    assert Config.max_concurrent_agents() == 7
    assert :sys.get_state(WorkflowStore).generation == generation + 1
  end
end
