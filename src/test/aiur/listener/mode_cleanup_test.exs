defmodule Aiur.Listener.ModeCleanupTest do
  use Aiur.TestSupport

  alias Aiur.Listener.ModeStore
  alias Aiur.Orchestrator.WorkspaceCleanup

  setup do
    root = Aiur.TestSupport.tmp_root!("listener-mode-cleanup")
    Aiur.TestSupport.put_runtime_state_dir!(Path.join(root, "runtime"))
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.join(root, "workspaces"))
    Aiur.TestScopeGuard.put_ticket_scope!("98761")
    previous_docker = Application.get_env(:aiur, :docker_cleanup_command)
    Application.put_env(:aiur, :docker_cleanup_command, fn _, _, _ -> {"", 0} end)

    on_exit(fn ->
      if previous_docker, do: Application.put_env(:aiur, :docker_cleanup_command, previous_docker), else: Application.delete_env(:aiur, :docker_cleanup_command)
      Aiur.TestCleanup.rm_rf!(root, unset: [:runtime_state_dir])
    end)

    :ok
  end

  test "terminal cleanup removes listener mode for an allowed identifier" do
    assert {:ok, _record} = ModeStore.put("98761", :async, 0, %{actor: :human})
    path = ModeStore.path_for("98761")
    assert :ok = WorkspaceCleanup.cleanup_terminal_issue_artifacts("98761")
    refute File.exists?(path)
    assert ModeStore.get("98761").actor == :default
    assert_receive {:workspace_cleanup_finished, "98761", :ok}, 5_000
  end

  test "unresolvable runtime state returns defaults and errors without interrupting cleanup" do
    previous_key = System.get_env("AIUR_INSTANCE_KEY")
    previous_dir = Application.get_env(:aiur, :runtime_state_dir)
    System.delete_env("AIUR_INSTANCE_KEY")
    Application.delete_env(:aiur, :runtime_state_dir)

    try do
      assert Aiur.Config.Paths.runtime_state_dir() == {:error, :missing_instance_key}
      assert ModeStore.get("98761") == %{requested: :sync, version: 0, actor: :default, updated_at: nil}
      assert ModeStore.put("98761", :async, 0, %{actor: :human}) == {:error, {:runtime_state_dir_unavailable, :missing_instance_key}}
      assert ModeStore.clear("98761") == {:error, {:runtime_state_dir_unavailable, :missing_instance_key}}
      assert :ok = WorkspaceCleanup.clear_listen_mode("98761")
    after
      if previous_key, do: System.put_env("AIUR_INSTANCE_KEY", previous_key), else: System.delete_env("AIUR_INSTANCE_KEY")
      Application.put_env(:aiur, :runtime_state_dir, previous_dir)
    end
  end

  test "startup terminal sweep clears persisted listener modes" do
    previous = Application.get_env(:aiur, :memory_tracker_issues)
    Application.put_env(:aiur, :memory_tracker_issues, [%Aiur.Issue{id: "98761", identifier: "98761", state: "Done"}])

    try do
      assert {:ok, _record} = ModeStore.put("98761", :steer, 0, %{actor: :system})
      path = ModeStore.path_for("98761")
      WorkspaceCleanup.run_terminal_workspace_cleanup(%Aiur.Orchestrator.State{})
      refute File.exists?(path)
      assert_receive {:workspace_cleanup_finished, "98761", :ok}, 5_000
    after
      if previous, do: Application.put_env(:aiur, :memory_tracker_issues, previous), else: Application.delete_env(:aiur, :memory_tracker_issues)
    end
  end

  test "cleanup guard preserves listener modes outside the test ticket scope" do
    assert {:ok, record} = ModeStore.put("98762", :async, 0, %{actor: :human})
    assert :ok = WorkspaceCleanup.clear_listen_mode("98762")
    assert ModeStore.get("98762") == record
    assert :ok = WorkspaceCleanup.clear_listen_mode(nil)
  end
end
