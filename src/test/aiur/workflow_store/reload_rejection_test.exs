defmodule Aiur.WorkflowStore.ReloadRejectionTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AlertFeed, AlertLedger}
  alias Aiur.WorkflowStore.ReloadRejection

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-config-reload-rejection")
    previous_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join([root, "log", "aiur.log"]))

    on_exit(fn ->
      if previous_log_file, do: Application.put_env(:aiur, :log_file, previous_log_file), else: Application.delete_env(:aiur, :log_file)
      File.rm_rf!(root)
    end)

    :ok
  end

  # #3961: the operator wrote `claude:sonnet:medium` into the live config. The
  # store published it, `Config.settings!/0` raised inside the orchestrator,
  # and the daemon went down. The store must reject it before publication.
  test "an invalid routing effort keeps the last good routing in effect until the file is fixed" do
    ensure_workflow_store_running()
    path = Workflow.workflow_file_path()
    staging = Path.join(Path.dirname(path), "staged-config.yaml")

    write_workflow_file!(path, agent_routing: %{3 => "claude:sonnet"})
    assert Config.settings!().agent.routing == %{3 => "claude:sonnet"}

    write_workflow_file!(staging, agent_routing: %{3 => "claude:sonnet:medium"})
    write_workflow_file_atomic!(path, File.read!(staging))

    log =
      capture_log(fn ->
        assert {:error, {:invalid_workflow_config, message}} = WorkflowStore.force_reload()
        assert message =~ ~s(invalid effort "medium" for backend "claude")
        assert message =~ "takes no effort segment"
      end)

    assert log =~ "keeping last known good configuration"

    # The consumer that crashed the daemon still reads the old, valid routing.
    assert Config.settings!().agent.routing == %{3 => "claude:sonnet"}
    assert %{path: ^path, message: shown} = ReloadRejection.current()
    assert capture_io(&ReloadRejection.print_status/0) =~ "CONFIG RELOAD REJECTED path=#{path}"
    assert shown =~ ~s(invalid effort "medium")
    assert alert?("system.config.reload_rejected", true)

    write_workflow_file!(path, agent_routing: %{3 => "claude:opus"})

    assert Config.settings!().agent.routing == %{3 => "claude:opus"}
    assert ReloadRejection.current() == nil
    assert capture_io(&ReloadRejection.print_status/0) == ""
    assert alert?("system.config.reload_rejected.resolved", false)
  end

  test "a successful reload with no active rejection emits nothing" do
    ensure_workflow_store_running()
    write_workflow_file!(Workflow.workflow_file_path(), agent_routing: %{3 => "claude:haiku"})

    assert ReloadRejection.current() == nil
    refute alert?("system.config.reload_rejected.resolved", false)
  end

  defp alert?(topic, needs_attention) do
    [ledger_paths: [AlertLedger.path()]]
    |> AlertFeed.list()
    |> Enum.any?(&(&1["topic"] == topic and &1["needs_attention"] == needs_attention))
  end
end
