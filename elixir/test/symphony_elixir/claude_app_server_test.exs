defmodule SymphonyElixir.Claude.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.AppServer
  alias SymphonyElixir.Workflow

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      codex_command: "echo done"
    )

    :ok
  end

  test "implements CodingAgent behaviour" do
    behaviours =
      AppServer.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert SymphonyElixir.CodingAgent in behaviours
  end

  test "start_session rejects workspace root directory" do
    workspace_root = Config.workspace_root()
    assert {:error, {:invalid_workspace_cwd, :workspace_root, _}} = AppServer.start_session(workspace_root)
  end

  test "start_session rejects path outside workspace root" do
    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
             AppServer.start_session("/tmp/not-a-workspace")
  end

  test "stop_session handles already-closed port" do
    # Create and immediately close a port to get a dead port reference
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.find_executable("true"))},
        [:binary, :exit_status]
      )

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      1_000 -> :ok
    end

    assert :ok = AppServer.stop_session(%{port: port})
  end

  test "CodingAgent routes to Claude when agent_kind is claude" do
    assert SymphonyElixir.CodingAgent.adapter() == SymphonyElixir.Claude.AppServer
  end

  test "CodingAgent routes to Codex by default" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: nil)
    assert SymphonyElixir.CodingAgent.adapter() == SymphonyElixir.Codex.AppServer
  end
end
