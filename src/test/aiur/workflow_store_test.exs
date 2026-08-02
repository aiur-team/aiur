defmodule Aiur.WorkflowStoreTest do
  use Aiur.TestSupport

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
end
