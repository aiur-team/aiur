defmodule Aiur.ShutdownTest do
  use Aiur.TestSupport, async: false

  alias Aiur.{AlertLedger, Shutdown}

  test "cleanup/1 is a no-op on an empty registry" do
    assert Shutdown.cleanup() == :ok
  end

  test "cleanup/1 is idempotent (second call still returns :ok)" do
    assert Shutdown.cleanup(100) == :ok
    assert Shutdown.cleanup(100) == :ok
  end

  test "cleanup/1 swallows raises so the SIGTERM path can finish" do
    # Force a crash by passing a non-integer; cleanup should log + return :ok.
    assert Shutdown.cleanup(-1) == :ok
  end

  test "record_workspace_root/0 writes the configured root when requested" do
    workspace_root = Path.join(System.tmp_dir!(), "shutdown-root-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    WorkflowStore.force_reload()

    path = Path.join(System.tmp_dir!(), "aiur-workspace-root-#{System.unique_integer([:positive])}")
    previous = System.get_env("AIUR_WORKSPACE_ROOT_FILE")
    System.put_env("AIUR_WORKSPACE_ROOT_FILE", path)

    try do
      assert :ok = Shutdown.record_workspace_root()
      assert File.read!(path) == workspace_root
    after
      restore_env("AIUR_WORKSPACE_ROOT_FILE", previous)
      File.rm(path)
    end
  end

  test "record_workspace_root/0 no-ops without a root file env var" do
    previous = System.get_env("AIUR_WORKSPACE_ROOT_FILE")
    System.delete_env("AIUR_WORKSPACE_ROOT_FILE")

    try do
      assert :ok = Shutdown.record_workspace_root()
    after
      restore_env("AIUR_WORKSPACE_ROOT_FILE", previous)
    end
  end

  test "record_workspace_root/0 swallows write failures" do
    previous = System.get_env("AIUR_WORKSPACE_ROOT_FILE")
    System.put_env("AIUR_WORKSPACE_ROOT_FILE", "/")

    try do
      assert capture_log(fn ->
               assert :ok = Shutdown.record_workspace_root()
             end) =~ "record_workspace_root"
    after
      restore_env("AIUR_WORKSPACE_ROOT_FILE", previous)
    end
  end

  test "record_alert_ledger_path/0 writes the canonical ledger when requested" do
    path = Path.join(System.tmp_dir!(), "aiur-alert-ledger-#{System.unique_integer([:positive])}")
    previous = System.get_env("AIUR_ALERT_LEDGER_PATH_FILE")
    System.put_env("AIUR_ALERT_LEDGER_PATH_FILE", path)

    try do
      assert :ok = Shutdown.record_alert_ledger_path()
      assert File.read!(path) == AlertLedger.path()
    after
      restore_env("AIUR_ALERT_LEDGER_PATH_FILE", previous)
      File.rm(path)
    end
  end
end
