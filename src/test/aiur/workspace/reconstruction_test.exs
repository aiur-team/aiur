defmodule Aiur.Workspace.ReconstructionTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentEventLog, Workspace.Reconstruction}

  setup do
    root = Path.join(System.tmp_dir!(), "workspace-reconstruction-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "ticket")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace}
  end

  test "preserves prior and concurrent alert events when a staged reconstruction succeeds", %{
    root: root,
    workspace: workspace
  } do
    assert :ok = AgentEventLog.write(workspace, nil, %{event: "alert", last_message: "before reconstruction"})

    assert :ok =
             Reconstruction.run(workspace, fn stage ->
               assert :ok = AgentEventLog.write(workspace, nil, %{event: "alert", last_message: "during reconstruction"})
               File.write!(Path.join(stage, "README.md"), "rebuilt\n")
               :ok
             end)

    assert File.read!(Path.join(workspace, "README.md")) == "rebuilt\n"
    log = File.read!(Path.join([workspace, "logs", "agent.ndjson"]))
    assert log =~ "before reconstruction"
    assert log =~ "during reconstruction"
    assert File.ls!(root) == ["ticket"]
  end

  test "leaves the live logs in place when staged reconstruction fails", %{root: root, workspace: workspace} do
    assert :ok = AgentEventLog.write(workspace, nil, %{event: "alert", last_message: "before failed reconstruction"})

    assert {:error, :clone_failed} =
             Reconstruction.run(workspace, fn _stage ->
               assert :ok = AgentEventLog.write(workspace, nil, %{event: "alert", last_message: "during failed reconstruction"})
               {:error, :clone_failed}
             end)

    log = File.read!(Path.join([workspace, "logs", "agent.ndjson"]))
    assert log =~ "before failed reconstruction"
    assert log =~ "during failed reconstruction"
    assert File.ls!(root) == ["ticket"]
  end
end
