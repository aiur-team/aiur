defmodule Aiur.Workspace.ProvisionerLifecycleTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Provisioner

  test "an existing workspace emits an honest point outcome instead of an interval" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "aiur-existing-workspace-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    test_pid = self()

    recorder = fn kind, attributes, opts ->
      send(test_pid, {:recorded, kind, attributes, opts})
      :ok
    end

    assert {:ok, ^workspace, false} =
             Provisioner.ensure_workspace(workspace, nil, nil, "aiur/930", %{
               ticket: "930",
               attempt_id: "attempt-1",
               recorder: recorder
             })

    assert_receive {:recorded, :lifecycle, attributes, []}
    assert attributes.event == "prewarm"
    assert attributes.boundary == "point"
    assert attributes.prewarm_outcome == "existing"
    assert attributes.outcome == "skipped"
  end
end
