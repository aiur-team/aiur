defmodule Aiur.Workspace.ProvisionerLifecycleTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Provisioner

  test "an existing checkout emits an honest point outcome instead of an interval" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "aiur-existing-workspace-#{System.unique_integer([:positive])}"
      )

    init_repo!(workspace)
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

  defp init_repo!(workspace) do
    File.mkdir_p!(workspace)
    {_output, 0} = System.cmd("git", ["init", "--quiet", workspace], stderr_to_stdout: true)
  end
end
