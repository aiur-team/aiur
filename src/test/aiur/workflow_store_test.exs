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

  # Regression for #1684: the store is a cache over one small config file, so a
  # stalled store must degrade to reading that file, never kill its caller. When
  # `:timeout` fell through the catch, `Config.settings!/0` — reached from the
  # `aiur status` render path — killed the RPC evaluator, and the operator saw a
  # non-zero exit with an empty buffer.
  #
  # Since #1731 a stalled store is stronger than "does not kill the caller": the
  # read path never touches the store's mailbox, so it serves the cached value
  # (with its real generation) and does not wait at all. The fallback proven
  # here still exists — see `WorkflowStoreReadPathTest`, which kills the store
  # outright — but a merely-suspended store is no longer even a slow path.
  test "a stalled store falls back to the config file instead of killing the caller" do
    ensure_workflow_store_running()

    pid = Process.whereis(WorkflowStore)
    Application.put_env(:aiur, :workflow_store_call_timeout_ms, 25)
    :sys.suspend(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: :sys.resume(pid)
      Application.delete_env(:aiur, :workflow_store_call_timeout_ms)
    end)

    assert {:ok, %{config: config}} = WorkflowStore.current()
    assert is_map(config)

    assert {:ok, %{config: %{}}, generation} = WorkflowStore.current_with_generation()
    assert generation == :unknown or is_integer(generation)

    # The whole point: a saturated store must not take the read path down with it.
    assert %Aiur.Config.Schema{} = Config.settings!()
  end
end
