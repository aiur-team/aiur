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
    workspace_root = Aiur.TestSupport.tmp_root!("shutdown-root")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    WorkflowStore.force_reload()

    path = Aiur.TestSupport.tmp_root!("aiur-workspace-root")
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

  # Regression guard for #2548. `Aiur.Application.stop/1` runs `cleanup/1` after
  # the supervision tree is gone, so `Aiur.WorkflowStore` is down and a config
  # read falls back to parsing the workflow YAML — which makes YamlElixir call
  # `Application.start(:yamerl)`, an untimed `:application_controller` call
  # issued while that controller is already blocked terminating this very
  # application. It never returns and wedges the controller for the rest of the
  # VM; in CI that turned one toppled tree into a whole coverage partition of
  # 60s ExUnit timeouts and a run past the 20-minute bound.
  #
  # These two tests pin the contract that makes it impossible: with
  # `derive: false`, the shutdown path never re-derives config.
  describe "record_workspace_root/1 with derive: false" do
    test "reuses the parked root instead of re-deriving config" do
      # Park a sentinel while the store is up, then take the store down and
      # assert the sentinel — not a freshly derived root — is what gets written.
      parked = Aiur.TestSupport.tmp_root!("shutdown-parked-root")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: parked)
      WorkflowStore.force_reload()
      assert :ok = Shutdown.record_workspace_root()

      # Rewrite the config to a different root: a derive would pick this one up.
      derived = Aiur.TestSupport.tmp_root!("shutdown-derived-root")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: derived)
      refute derived == parked

      path = Aiur.TestSupport.tmp_root!("aiur-workspace-root")
      previous = System.get_env("AIUR_WORKSPACE_ROOT_FILE")
      System.put_env("AIUR_WORKSPACE_ROOT_FILE", path)

      try do
        without_workflow_store(fn ->
          assert :ok = Shutdown.record_workspace_root(derive: false)
        end)

        assert File.read!(path) == parked
      after
        restore_env("AIUR_WORKSPACE_ROOT_FILE", previous)
        File.rm(path)
      end
    end

    test "skips the handoff rather than deriving when nothing is parked" do
      :persistent_term.erase({Shutdown, :workspace_root})

      path = Aiur.TestSupport.tmp_root!("aiur-workspace-root")
      File.rm(path)
      previous = System.get_env("AIUR_WORKSPACE_ROOT_FILE")
      System.put_env("AIUR_WORKSPACE_ROOT_FILE", path)

      try do
        without_workflow_store(fn ->
          assert :ok = Shutdown.record_workspace_root(derive: false)
        end)

        refute File.exists?(path)
      after
        restore_env("AIUR_WORKSPACE_ROOT_FILE", previous)
        File.rm(path)
        # Leave the cache populated for whatever runs next in this VM.
        Aiur.TestSupport.ensure_workflow_store_running()
        Shutdown.record_workspace_root()
      end
    end
  end

  defp without_workflow_store(fun) do
    Supervisor.terminate_child(Aiur.Supervisor, WorkflowStore)
    refute is_pid(Process.whereis(WorkflowStore))
    fun.()
  after
    Aiur.TestSupport.ensure_workflow_store_running()
  end

  test "record_alert_ledger_path/0 writes the canonical ledger when requested" do
    path = Aiur.TestSupport.tmp_root!("aiur-alert-ledger")
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
