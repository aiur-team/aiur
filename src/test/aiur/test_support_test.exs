defmodule Aiur.TestSupportTest do
  use Aiur.TestSupport

  test "receive_barrier selectively receives and exports bindings without a clock" do
    send(self(), :unrelated)
    send(self(), {:ready, 42})

    receive_barrier({:ready, value})

    assert value == 42
    assert_received :unrelated
  end

  test "write_workflow_file! waits for the active config reload to finish" do
    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)
    workspace_root = Aiur.TestSupport.tmp_root!("synced-workflow")

    :sys.suspend(store)
    :erlang.trace(store, true, [:receive])

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
    end)

    writer =
      Task.async(fn ->
        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      end)

    assert_receive {:trace, ^store, :receive, {:"$gen_call", _from, :force_reload}}, 1_000

    # The legacy helper swallowed the GenServer.call exit after five seconds
    # and returned while the store was still suspended with its old cache.
    assert Task.yield(writer, 5_100) == nil

    :sys.resume(store)

    assert :ok = Task.await(writer, 1_000)
    assert Config.workspace_root() == workspace_root
  end

  test "write_workflow_file_async! warns when the active config reload times out" do
    ensure_workflow_store_running()
    store = Process.whereis(WorkflowStore)
    workspace_root = Aiur.TestSupport.tmp_root!("async-workflow")

    Application.put_env(:aiur, :workflow_store_call_timeout_ms, 25)
    :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      Application.delete_env(:aiur, :workflow_store_call_timeout_ms)
    end)

    log =
      capture_log(fn ->
        assert :ok = write_workflow_file_async!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      end)

    assert log =~ "Best-effort workflow reload failed"
    assert log =~ "WorkflowStore may serve stale test config"

    :sys.resume(store)
  end

  test "ensure_runtime_children_running restores a stopped branch ref store" do
    store = Process.whereis(Aiur.Events.BranchRefStore)
    assert is_pid(store)

    on_exit(fn -> Aiur.TestSupport.ensure_branch_ref_store_running() end)

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Events.BranchRefStore)
    refute Process.whereis(Aiur.Events.BranchRefStore)

    assert :ok = Aiur.TestSupport.ensure_runtime_children_running()
    assert is_pid(Process.whereis(Aiur.Events.BranchRefStore))
  end
end
