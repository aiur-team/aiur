defmodule Aiur.Experiments.StartupTest do
  use Aiur.TestSupport
  alias Aiur.Experiments.Auto

  test "configured disabled experiments omit the writer child" do
    write_workflow_file!(Workflow.workflow_file_path())
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nexperiments:\n  enabled: false\n")
    :ok = Aiur.WorkflowStore.force_reload()
    assert Aiur.Experiments.child(true) == nil
    assert Aiur.Experiments.children(true) == []
    assert Aiur.Experiments.window_children(true) == []
  end

  test "enabled experiments manage manual windows even with automatic creation disabled" do
    write_workflow_file!(Workflow.workflow_file_path())
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nexperiments:\n  auto:\n    enabled: false\n")
    :ok = Aiur.WorkflowStore.force_reload()
    assert Aiur.Experiments.child(true) == Aiur.Experiments.Store
    assert Aiur.Experiments.children(true) == [Aiur.Experiments.Store, Aiur.Experiments.Capture, Aiur.Experiments.Checkpointer]
    assert Aiur.Experiments.window_children(true) == [Aiur.Experiments.Auto.Notifier, Aiur.Experiments.Auto.WindowManager]
    assert Aiur.Experiments.window_children(false) == []
  end

  test "automatic status lists the configured sources without inventing detection evidence" do
    write_workflow_file!(Workflow.workflow_file_path())
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\nexperiments:\n  auto:\n    version_line: false\n")
    :ok = Aiur.WorkflowStore.force_reload()
    assert %{enabled: true, sources: [%{source: :repo_release, last_seen: nil}, %{source: :feature, last_seen: nil}]} = Auto.status()
  end
end
