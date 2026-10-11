defmodule Aiur.Experiments.StartupTest do
  use Aiur.TestSupport

  test "configured disabled experiments omit the writer child" do
    write_workflow_file!(Workflow.workflow_file_path())
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nexperiments:\n  enabled: false\n")
    :ok = Aiur.WorkflowStore.force_reload()
    assert Aiur.Experiments.child(true) == nil
  end

  test "enabled experiments supply the component writer child" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Aiur.Experiments.child(true) == Aiur.Experiments.Store
  end
end
